import AppKit
import Foundation

extension AppState {
    func matchedAutomation(for command: String) -> (automation: VoiceAutomation, isOffVariant: Bool)? {
        let keywords = automations.map { CoreAutomationKeywords(keyword: $0.keyword, offKeyword: $0.offKeyword) }
        guard let match = coreMatchAutomation(text: command, keywords: keywords), Int(match.index) < automations.count else { return nil }
        return (automations[Int(match.index)], match.isOffVariant)
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
        var previousSucceeded = true
        for action in automation.actions {
            guard !Task.isCancelled else { return false }
            if action.requiresPreviousSuccess && !previousSucceeded {
                appendLog("[Automation] Skipped dependent step after a failed or skipped step.")
                PipelineTrace.current?.event("routine_step_skipped", fields: ["step_id": action.id.uuidString])
                allSucceeded = false; previousSucceeded = false
                continue
            }
            previousSucceeded = false
            if let error = action.validationMessage {
                appendLog("[Automation][ERROR] \(error)")
                allSucceeded = false
                continue
            }
            let plan: [PlannedAction]
            if action.type == .command {
                guard case .allowed = SafetyGuard.validate(rawCommand: action.value) else {
                    appendLog("[Automation][ERROR] Command blocked by safety policy.")
                    allSucceeded = false
                    continue
                }
                // Use the shared planner directly; saved routine keywords must not recurse.
                plan = await actionPlanner.plan(from: action.value, requestID: PipelineTrace.current?.id ?? UUID())
            } else {
                plan = plannedAction(for: action).map { [$0] } ?? []
            }
            guard !Task.isCancelled else { return false }
            if !plan.isEmpty {
                let results = await actionExecutor.execute(
                    plan: plan,
                    onStepStart: { [weak self] plannedAction in
                        guard !Task.isCancelled else { return }
                        self?.appendLog("[Automation] ▶ \(plannedAction.description)")
                    },
                    onStepComplete: { [weak self] result in
                        guard !Task.isCancelled else { return }
                        self?.appendLog("[Automation] \(result.success ? "✓" : "✗") \(result.message)")
                    }
                )
                previousSucceeded = results.count == plan.count && results.allSatisfy(\.success)
                allSucceeded = allSucceeded && previousSucceeded
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
        coreCompileRoutineAction(typeName: action.type.rawValue, value: action.value).flatMap(RustPipeline.map)
    }

    func invalidateActiveCommand() {
        activeCommandRunToken = nil
        currentCommand = ""
        assistantState = micActive ? .listening : .idle
    }

    func runCommand(_ command: String, testTrace: CommandTestTrace? = nil) async {
        guard !Task.isCancelled, !command.isEmpty else { return }
        let token = UUID()
        activeCommandRunToken = token
        defer {
            if activeCommandRunToken == token { invalidateActiveCommand() }
        }
        let trace = PipelineTrace.current ?? PipelineTrace(id: testTrace?.requestID ?? UUID(), source: "command")
        await PipelineTrace.$current.withValue(trace) {
            await runCommandBody(command, runToken: token, testTrace: testTrace)
        }
    }

    func runCommandBody(_ command: String, runToken: UUID, testTrace: CommandTestTrace? = nil) async {
        if testTrace == nil { trackRecentCommand(command) }
        var outcome = CommandOutcome.failure
        let requestID = testTrace?.requestID ?? PipelineTrace.current?.id ?? UUID()
        lastCommandForReview = command
        lastCommandTraceID = requestID
        defer {
            if Task.isCancelled || activeCommandRunToken != runToken { outcome = .cancelled }
            testTrace?.outcome = outcome.rawValue
            testTrace?.record("finished", outcome.rawValue)
            PipelineTrace.current?.event("command_finished", fields: ["outcome": outcome.rawValue])
            if testTrace == nil { statsRecorder.recordCommand(success: outcome == .success) }
            intentLog.append([
                "event": testTrace == nil ? "execute_command" : "test_execute_command",
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
            testTrace?.record("safety", reason)
            appendLog("⛔ Safety blocked: \(reason)")
            if testTrace == nil {
                dbManager.saveEvent(eventType: "safety_blocked", transcript: command,
                                    matched: false, metadata: ["reason": reason])
            }
            return
        case .installPreview(let cmd, let source):
            testTrace?.record("safety", "Install preview only: \(cmd). \(source)")
            appendLog("🔒 Install preview (not executed): '\(cmd)'. \(source)")
            if testTrace == nil {
                dbManager.saveEvent(eventType: "install_preview", transcript: command,
                                    matched: false, metadata: ["command": cmd, "source": source])
            }
            return
        case .allowed:
            break
        }

        // A document name/content phrase can contain a routine keyword.
        // Explicit native search/settings/result commands keep their meaning.
        if LocalSearchParser.route(command) == nil, SpotifyShuffleParser.parse(command) == nil,
           SystemVolumeParser.route(command) == nil, WorkspaceCommandParser.plan(command) == nil,
           let match = matchedAutomation(for: command) {
            testTrace?.record("routine", match.automation.keyword)
            let success = await executeAutomation(match.automation, isOffVariant: match.isOffVariant)
            outcome = success ? .success : .failure
            return
        }
        if tryHandleQuickInfoCommand(command) {
            testTrace?.record("local_info", ResponseEngine.shared.lastResponse)
            outcome = .success
            return
        }

        assistantState = .processing
        currentCommand = command
        lastRecognizedSpeech = command
        appendLog("[Plan] Planning: '\(command)'")
        let plan = await actionPlanner.plan(from: command, requestID: requestID)
        PipelineTrace.current?.event("plan_ready", fields: ["steps": String(plan.count)])
        testTrace?.plan = plan.map(\.description)
        testTrace?.record("planned", "\(plan.count) actions")
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
                testTrace?.steps.append(CommandTestStep(action: result.action.description, success: result.success, message: result.message, verification: result.verification.rawValue))
                self.appendLog("  \(result.success ? "✓" : "✗") \(result.message)")
                intentLog.append([
                    "event": testTrace == nil ? "execute_step" : "test_execute_step", "request_id": requestID.uuidString,
                    "text": command, "action": result.action.description,
                    "success": result.success, "message": result.message,
                    "verification": result.verification.rawValue,
                ])
                ResponseEngine.shared.respond(action: result.action, result: result, speak: speakResponses)
                if plan.count == 1, result.success, case .systemInfo = result.action {
                    self.showFloatingResult(result.message, icon: "info.circle.fill")
                }
            }
        )
        guard !Task.isCancelled, activeCommandRunToken == runToken else { return }
        outcome = CommandOutcome.evaluate(results, expectedCount: plan.count, cancelled: false)
        if testTrace == nil {
            dbManager.saveEvent(eventType: "multi_action_executed", transcript: command,
                                matched: outcome == .success,
                                executionResult: results.map(\.message).joined(separator: " | "),
                                metadata: ["outcome": outcome.rawValue])
        }
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
