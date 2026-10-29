import AppKit
import Foundation

extension AppState {
    func matchedAutomation(for command: String) -> (automation: VoiceAutomation, isOffVariant: Bool)? {
        // Migration cut-over: Rust core owns the matching decision.
        if JarvisFlags.useRustPipeline {
            let keywords = automations.map {
                CoreAutomationKeywords(keyword: $0.keyword, offKeyword: $0.offKeyword)
            }
            if let match = coreMatchAutomation(text: command, keywords: keywords),
               Int(match.index) < automations.count {
                return (automations[Int(match.index)], match.isOffVariant)
            }
            return nil
        }

        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }

        for automation in automations {
            let keyword = automation.keyword.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyword.isEmpty else { continue }

            let offKeyword = automation.offKeyword?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "\(keyword) off"

            if !offKeyword.isEmpty, lower.contains(offKeyword) {
                return (automation, true)
            }

            if lower.contains(keyword) {
                return (automation, false)
            }
        }

        return nil
    }

    func executeAutomation(_ automation: VoiceAutomation, isOffVariant: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        if isOffVariant {
            ResponseEngine.shared.respond(to: "Automation \(automation.keyword) turned off", speak: voiceResponseEnabled)
            return true
        }
        appendLog("[Automation] Executing \(automation.actions.count) actions for '\(automation.keyword)'")
        assistantState = .executing
        var allSucceeded = !automation.actions.isEmpty
        for action in automation.actions {
            guard !Task.isCancelled else { return false }
            if action.type == .timer || action.type == .stopwatch {
                appendLog("[Automation][ERROR] \(action.type.rawValue) is not implemented.")
                allSucceeded = false
            } else if action.type == .openFile {
                let result = openFilePath(action.value)
                allSucceeded = allSucceeded && result
                appendLog(result ? "[Automation] Opened file: \(action.value)" : "[Automation][ERROR] Failed opening file: \(action.value)")
            } else if let planned = plannedAction(for: action) {
                let results = await actionExecutor.execute(
                    plan: [planned],
                    onStepStart: { [weak self] plannedAction in
                        guard !Task.isCancelled else { return }
                        self?.appendLog("[Automation] ▶ \(plannedAction.description)")
                    },
                    onStepComplete: { [weak self] result in
                        guard !Task.isCancelled else { return }
                        self?.appendLog("[Automation] \(result.success ? "✓" : "✗") \(result.message)")
                    }
                )
                allSucceeded = allSucceeded && results.count == 1 && results.allSatisfy(\.success)
            } else {
                appendLog("[Automation][ERROR] Skipped \(action.type.rawValue) — no value configured")
                allSucceeded = false
            }
        }
        guard !Task.isCancelled else { return false }
        ResponseEngine.shared.respond(
            to: allSucceeded ? "Automation \(automation.keyword) executed" : "Automation \(automation.keyword) had failed steps",
            speak: voiceResponseEnabled)
        return allSucceeded
    }

    func plannedAction(for action: AutomationAction) -> PlannedAction? {
        let value = action.value.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action.type {
        case .openApp:
            guard !value.isEmpty else { return nil }
            return .openApp(value)
        case .closeApp:
            guard !value.isEmpty else { return nil }
            return .closeApp(value)
        case .playSong:
            guard !value.isEmpty else { return nil }
            return .mediaControl(.playSong(value))
        case .playPlaylist:
            guard !value.isEmpty else { return nil }
            return .mediaControl(.playPlaylist(value))
        case .playLiked:
            return .mediaControl(.playLikedSongs)
        case .pause:
            return .mediaControl(.pause)
        case .next:
            return .mediaControl(.nextTrack)
        case .previous:
            return .mediaControl(.previousTrack)
        case .openFolder:
            guard !value.isEmpty else { return nil }
            return .openFolder(value)
        case .timer, .stopwatch, .openFile:
            return nil
        }
    }

    func openFilePath(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }

        let expanded = (path as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [expanded]

        do {
            try process.run()
            guard process.waitUntilExit(timeout: 10) else {
                appendLog("[Automation][ERROR] Open file timed out: \(path)")
                return false
            }
            return process.terminationStatus == 0
        } catch {
            appendLog("[Automation][ERROR] Open file failed: \(error.localizedDescription)")
            return false
        }
    }


    func invalidateActiveCommand() {
        activeCommandRunToken = nil
        currentCommand = ""
        assistantState = micActive ? .listening : .idle
    }

    func runCommand(_ command: String) async {
        guard !Task.isCancelled, !command.isEmpty else { return }
        let token = UUID()
        activeCommandRunToken = token
        defer {
            if activeCommandRunToken == token { invalidateActiveCommand() }
        }
        await runCommandBody(command, runToken: token)
    }

    func runCommandBody(_ command: String, runToken: UUID) async {
        trackRecentCommand(command)
        var outcome = CommandOutcome.failure
        let requestID = UUID()
        defer {
            if Task.isCancelled || activeCommandRunToken != runToken { outcome = .cancelled }
            statsRecorder.recordCommand(success: outcome == .success)
            intentLog.append([
                "event": "execute_command",
                "request_id": requestID.uuidString,
                "text": command,
                "success": outcome == .success,
                "outcome": outcome.rawValue,
            ])
        }

        let lower = command.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["stop", "cancel", "abort", "cancel that", "stop that"].contains(lower) {
            ResponseEngine.shared.stopSpeaking()
            outcome = .success
            return
        }

        switch SafetyGuard.validate(rawCommand: command) {
        case .blocked(let reason):
            appendLog("⛔ Safety blocked: \(reason)")
            dbManager.saveEvent(eventType: "safety_blocked", transcript: command,
                                matched: false, metadata: ["reason": reason])
            return
        case .installPreview(let cmd, let source):
            appendLog("🔒 Install preview (not executed): '\(cmd)'. \(source)")
            dbManager.saveEvent(eventType: "install_preview", transcript: command,
                                matched: false, metadata: ["command": cmd, "source": source])
            return
        case .allowed:
            break
        }

        // A document name/content phrase can contain a routine keyword.
        // Explicit native search/settings/result commands keep their meaning.
        if LocalSearchParser.route(command) == nil, SpotifyShuffleParser.parse(command) == nil,
           SystemVolumeParser.route(command) == nil,
           let match = matchedAutomation(for: command) {
            let success = await executeAutomation(match.automation, isOffVariant: match.isOffVariant)
            outcome = success ? .success : .failure
            return
        }
        if tryHandleQuickInfoCommand(command) {
            outcome = .success
            return
        }

        assistantState = .processing
        currentCommand = command
        lastRecognizedSpeech = command
        appendLog("[Plan] Planning: '\(command)'")
        let plan = await actionPlanner.plan(from: command, requestID: requestID)
        guard !Task.isCancelled, activeCommandRunToken == runToken else { return }
        appendLog("[Plan] \(plan.count) step(s): \(plan.map(\.description).joined(separator: ", "))")
        assistantState = .executing
        let speakResponses = voiceResponseEnabled
        let results = await actionExecutor.execute(
            plan: plan,
            onStepStart: { [weak self] action in
                guard let self, self.activeCommandRunToken == runToken, !Task.isCancelled else { return }
                self.appendLog("  ▶ \(action.description)")
            },
            onStepComplete: { [weak self] result in
                guard let self, self.activeCommandRunToken == runToken, !Task.isCancelled else { return }
                self.appendLog("  \(result.success ? "✓" : "✗") \(result.message)")
                intentLog.append([
                    "event": "execute_step", "request_id": requestID.uuidString,
                    "text": command, "action": result.action.description,
                    "success": result.success, "message": result.message,
                ])
                ResponseEngine.shared.respond(action: result.action, result: result, speak: speakResponses)
                if plan.count == 1, result.success, case .systemInfo = result.action {
                    self.showFloatingResult(result.message, icon: "info.circle.fill")
                }
            }
        )
        guard !Task.isCancelled, activeCommandRunToken == runToken else { return }
        outcome = CommandOutcome.evaluate(results, expectedCount: plan.count, cancelled: false)
        dbManager.saveEvent(eventType: "multi_action_executed", transcript: command,
                            matched: outcome == .success,
                            executionResult: results.map(\.message).joined(separator: " | "),
                            metadata: ["outcome": outcome.rawValue])
    }

    func showFloatingResult(_ text: String, icon: String) {
        guard presentsUI else { return }
        FloatPanel.show(text: text, icon: icon)
    }

    // MARK: - Quick informational command handler
    @discardableResult
    func tryHandleQuickInfoCommand(_ command: String) -> Bool {
        // Strip wake word and normalize
        var lower = command.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("jarvis ") {
            lower = String(lower.dropFirst("jarvis ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Remove trailing punctuation
        lower = lower.trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))

        // Detection lives in QuickInfoMatcher (single table shared with the
        // planner routers). Multi-clause inputs fall through so the
        // conjunction splitter keeps every clause. This stays a presentation
        // fast-path: instant answer + floating panel + TTS.
        guard !QuickInfoMatcher.looksCompound(lower),
              let kind = QuickInfoMatcher.match(lower) else { return false }

        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()

        switch kind {
        case .time:
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let timeStr = formatter.string(from: now)
            appendLog("[QuickInfo] Detected time query → \(timeStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            ResponseEngine.shared.respond(to: timeStr, speak: voiceResponseEnabled)
            showFloatingResult(timeStr, icon: "clock.fill")
            return true

        case .date:
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            let dateStr = formatter.string(from: now)
            appendLog("[QuickInfo] Detected date query → \(dateStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            ResponseEngine.shared.respond(to: dateStr, speak: voiceResponseEnabled)
            showFloatingResult(dateStr, icon: "calendar")
            return true

        case .day:
            let dayNames = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
            let weekday = calendar.component(.weekday, from: now)
            let dayStr = dayNames[weekday - 1]
            appendLog("[QuickInfo] Detected day query → \(dayStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            ResponseEngine.shared.respond(to: dayStr, speak: voiceResponseEnabled)
            showFloatingResult(dayStr, icon: "calendar")
            return true

        case .month:
            let months = ["January","February","March","April","May","June",
                          "July","August","September","October","November","December"]
            let monthIdx = calendar.component(.month, from: now)
            let monthStr = months[monthIdx - 1]
            appendLog("[QuickInfo] Detected month query → \(monthStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            ResponseEngine.shared.respond(to: monthStr, speak: voiceResponseEnabled)
            showFloatingResult(monthStr, icon: "calendar.badge.clock")
            return true

        case .year:
            let year = calendar.component(.year, from: now)
            let yearStr = String(year)
            appendLog("[QuickInfo] Detected year query → \(yearStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            ResponseEngine.shared.respond(to: yearStr, speak: voiceResponseEnabled)
            showFloatingResult(yearStr, icon: "calendar.badge.clock")
            return true
        }
    }

}
