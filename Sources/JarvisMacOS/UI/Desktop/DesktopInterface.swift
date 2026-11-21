import AppKit
import AVFoundation
import Combine
import SwiftUI

struct DesktopCommandResult {
    let command: String
    let outcome: String
    let message: String
    let steps: [String]
    let milliseconds: Int

    var values: [String: Any] {
        ["command": command, "outcome": outcome, "message": message, "steps": steps, "ms": milliseconds]
    }
}

struct DesktopInterface: NSViewRepresentable {
    let appState: AppState
    let presentSheet: (DesktopDetail) -> Void

    func makeCoordinator() -> DesktopSession { DesktopSession(app: appState, presentSheet: presentSheet) }
    func makeNSView(context: Context) -> DesktopWebView { context.coordinator.makeView() }
    func updateNSView(_ view: DesktopWebView, context: Context) {}
}

enum DesktopDetail: Identifiable {
    case settings(String)
    case setup(NoirSetupKind)
    var id: String {
        switch self {
        case .settings(let group): return group
        case .setup(let kind): return kind.rawValue
        }
    }
}

@MainActor
final class DesktopSession {
    private let app: AppState
    private let presentSheet: (DesktopDetail) -> Void
    private let appearance = AppAppearance.shared
    private let dictation = DictationController.shared
    private let search = FileSearchController.shared
    private let fileLocations = FileSearchLocationStore.shared
    private let projects = ProjectLocationStore.shared
    private let model = IntentModelSetup.shared
    private let login = LaunchAtLoginController()
    private let sound = SystemSoundModel()
    private var subscriptions: Set<AnyCancellable> = []
    private var ready = false
    private var visible = false
    private var lastState: Data?
    private var sessionResults: [DesktopCommandResult] = []
    private weak var view: DesktopWebView?

    init(app: AppState, presentSheet: @escaping (DesktopDetail) -> Void) {
        self.app = app
        self.presentSheet = presentSheet
    }

    func makeView() -> DesktopWebView {
        let web = DesktopWebView(document: "index")
        view = web
        web.handle = { [weak self] action, arguments in
            guard let self else { throw DesktopUIError("The window has closed.") }
            return try await self.receive(action, arguments)
        }
        web.onLoad = { [weak self] in self?.pageLoaded() }
        web.onVisibility = { [weak self] visible in
            guard let self else { return }
            self.visible = visible
            self.view?.deliver("visibility", visible)
            if visible {
                self.login.refresh()
                self.pushState(force: true)
                Task { await self.sound.refresh() }
            }
        }
        observeState()
        search.presentResultsInDesktop = { [weak self] in
            guard let self, self.ready, NSApp.isActive, self.view?.window?.isKeyWindow == true else { return false }
            self.view?.deliver("openSearch", self.search.desktopDraft)
            return true
        }
        FloatPanel.presentInDesktop = { [weak self] values in
            guard let self, self.ready, NSApp.isActive, self.view?.window?.isKeyWindow == true else { return false }
            self.view?.deliver("answer", values)
            return true
        }
        return web
    }

    private func observeState() {
        Publishers.MergeMany([
            app.objectWillChange, dictation.objectWillChange, fileLocations.objectWillChange,
            projects.objectWillChange, model.objectWillChange, login.objectWillChange, sound.objectWillChange,
            CommandTestHarness.shared.objectWillChange
        ])
        .throttle(for: .milliseconds(100), scheduler: DispatchQueue.main, latest: true)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.pushState() }
        .store(in: &subscriptions)

        app.popupManager.$isVisible
            .filter { $0 }.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.view?.deliver("toast", self.app.popupManager.message)
            }.store(in: &subscriptions)

        app.$audioLevelNormalized
            .throttle(for: .milliseconds(70), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] level in
                guard let self, self.ready, self.visible else { return }
                self.view?.deliver("meter", level)
            }.store(in: &subscriptions)
        app.$activeSection.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] section in
                guard let self, self.ready else { return }
                self.view?.deliver("navigate", self.navigation(section))
            }.store(in: &subscriptions)
        app.$expandedSettingsGroup.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] group in
                guard let self, self.ready, self.app.activeSection == .system, let group else { return }
                let groups: [GeneralSettingsGroup: String] = [.projects: "files", .services: "services", .display: "display", .advanced: "safeguards"]
                if let key = groups[group] { self.view?.deliver("settingsGroup", key) }
            }.store(in: &subscriptions)
        app.commandResults.sink { [weak self] result in self?.recordResult(result) }
            .store(in: &subscriptions)
        search.objectWillChange.debounce(for: .milliseconds(30), scheduler: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, self.ready else { return }
                if self.search.hasContext { self.view?.deliver("search", self.search.desktopSearchValues) }
                else { self.view?.deliver("closeSearch") }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.login.refresh()
                self.pushState(force: true)
                Task { await self.sound.refresh() }
            }.store(in: &subscriptions)
    }

    private func pageLoaded() {
        guard ready else { return }
        view?.deliver("appearance", appearance.desktopValues)
        view?.deliver("visibility", visible)
        pushState(force: true)
    }

    private func recordResult(_ result: DesktopCommandResult) {
        sessionResults.append(result)
        if sessionResults.count > 50 { sessionResults.removeFirst(sessionResults.count - 50) }
        if ready { view?.deliver("result", result.values) }
        if ready, visible { view?.deliver("activityChanged") }
        Task { await sound.refresh() }
    }

    private func pushState(force: Bool = false) {
        guard ready, visible || force else { return }
        let data = snapshot()
        guard let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]),
              force || lastState != encoded else { return }
        lastState = encoded
        view?.deliver("state", data)
    }

    private func navigation(_ section: RailSection) -> [String: String] {
        switch section {
        case .system: return ["section": "settings", "tab": "general"]
        case .setup: return ["section": "settings", "tab": "setup"]
        case .about: return ["section": "settings", "tab": "about"]
        case .insights: return ["section": "activity"]
        case .voice: return ["section": "voice", "tab": app.voiceSettingsTab.rawValue.lowercased()]
        default: return ["section": section.rawValue]
        }
    }

    private func snapshot() -> [String: Any] {
        let preferences: [String: Any] = [
            "verifyAction": app.actionPillRequiresVerify, "verifyLive": app.voiceModeRequiresVerify,
            "spoken": app.voiceResponseEnabled, "rust": app.useRustPipeline, "login": login.isEnabled,
            "format": dictation.aiFormattingEnabled, "paste": dictation.insertAtCursorEnabled,
            "original": dictation.copyOriginalEnabled, "recordLimit": dictation.recordingLimitMinutes,
            "resultDuration": dictation.cardDismissSeconds, "eventLog": app.eventLoggingEnabled,
            "dictationLog": app.dictationDevLogEnabled, "timeout": app.sessionTimeoutSeconds,
            "engine": UserDefaults.standard.string(forKey: "jarvis.liveSpeech.engine") ?? "apple",
            "locale": UserDefaults.standard.string(forKey: "jarvis.liveSpeech.locale") ?? "en-IN"
        ]
        let voice: [String: Any] = [
            "ready": app.voiceProfileReady, "count": app.backendEnrollmentSampleCount,
            "phase": app.enrollmentPreparing ? "preparing" : app.enrollmentActive ? "active" : app.enrollmentPaused ? "paused" : "idle",
            "index": app.enrollmentIndex, "phrase": app.currentEnrollmentPhrase,
            "phrases": app.enrollmentPhrases.count, "matches": app.enrollmentCurrentPhraseMatchCount,
            "repetitions": app.enrollmentRequiredMatchesPerPhrase, "awaiting": app.enrollmentAwaitingNextPhrase,
            "notice": app.voiceProfileError ?? app.enrollmentMessage, "resetting": app.voiceProfileResetting,
            "threshold": app.voiceVerifyThreshold
        ]
        let live = app.isLiveListening && !app.enrollmentActive
        let title: String
        let subtitle: String
        if live && !app.voiceModeEnabled {
            title = "Listening"
            subtitle = app.canUseVoiceMode ? "Enable hands-free mode in Assistant preferences."
                : "Enroll your voice to use verified hands-free commands."
        } else {
            title = app.assistantState == .idle ? "Ready for a command" : app.assistantState.rawValue
            subtitle = live ? "Say “Jarvis” followed by a command." : "Run a command, find a file, or dictate at your cursor."
        }
        let assistant: [String: Any] = [
            "live": live, "mic": app.micActive,
            "title": title,
            "subtitle": app.microphoneError ?? subtitle,
            "footer": app.enrollmentActive ? "Voice enrollment · microphone on"
                : live ? "Live listening · microphone on"
                : app.micActive ? "Microphone on" : "Standby · microphone off"
        ]
        let modelValues: [String: Any] = [
            "installed": model.installedVersion ?? "", "latest": model.latestVersion ?? "",
            "message": [model.message, model.runtimeWarning].compactMap { $0 }.joined(separator: " · "),
            "busy": model.isBusy, "downloading": model.isDownloading,
            "update": model.updateAvailable, "progress": Int(model.progress * 100)
        ]
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted()
        let speechReady = dictation.modelPhase == .Ready || dictation.modelPhase == .Inference
        let setup: [String: Any] = [
            "microphone": microphone ? "Ready" : "Set up",
            "accessibility": accessibility ? "Ready" : "Set up",
            "whisper": speechReady ? "Installed" : "Set up",
            "helper": app.backendStatus,
            "postgres": app.postgresStatusText,
            "spotify": app.spotifyNativeAvailable ? "Available" : "Optional",
            "ollama": app.ollamaReachable && app.ollamaModelInstalled ? "Ready" : "Set up",
            "essentials": [microphone, accessibility, speechReady].filter { $0 }.count
        ]
        let build = DiagnosticBuild.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let buildValues = ["buildVersion": version, "buildRevision": build.revision,
                           "buildBinary": String(build.executableUUID.prefix(8)), "buildArchitecture": "arm64"]
        let level: Any = sound.snapshot?.level.map { Int(($0 * 100).rounded()) as Any } ?? NSNull()
        let volume: [String: Any] = ["level": level, "writable": sound.snapshot?.canSetVolume == true]
        return [
            "nav": navigation(app.activeSection), "preferences": preferences, "voice": voice, "assistant": assistant,
            "model": modelValues, "setup": setup, "build": buildValues, "volume": volume,
            "testRunning": CommandTestHarness.shared.isRunning,
            "dictation": ["formatted": dictation.lastPolished.isEmpty ? dictation.lastOriginal : dictation.lastPolished,
                          "original": dictation.copyOriginalEnabled ? dictation.lastOriginal : ""],
            "recent": app.recentCommands, "logCount": app.logs.count, "history": Array(app.logs.suffix(35).reversed()),
            "folders": folders(), "routines": app.automations.map(routineValues), "actionTypes": actionTypes()
        ]
    }

    private func folders() -> [[String: Any]] {
        let standardFolders = ["Downloads", "Desktop", "Documents"].map { (name: $0, path: $0, custom: false) }
        let customFolders = projects.locations.map { (name: $0.name, path: $0.url().path, custom: true) }
            + fileLocations.locations.map { (name: $0.name, path: $0.path, custom: true) }
        var seen = Set<String>()
        return (customFolders + standardFolders).filter { seen.insert($0.path).inserted }
            .map { ["name": $0.name, "path": $0.path, "custom": $0.custom] }
    }

    private func actionTypes() -> [[String: Any]] {
        AutomationActionType.allCases.map {
            ["type": $0.rawValue, "title": $0.displayName, "placeholder": $0.placeholder,
             "requiresValue": $0.requiresValue, "selectable": AutomationActionType.selectableCases.contains($0)]
        }
    }

    private func routineValues(_ routine: VoiceAutomation) -> [String: Any] {
        [
            "id": routine.id.uuidString, "trigger": routine.keyword, "offPhrase": routine.offKeyword ?? "",
            "enabled": routine.isDisabled != true,
            "actions": routine.actions.map { ["id": $0.id.uuidString, "type": $0.type.rawValue,
                                             "target": $0.value, "requires": $0.requiresPreviousSuccess] }
        ]
    }

    private func receive(_ action: String, _ args: [String: Any]) async throws -> Any? {
        let key = args["key"] as? String ?? ""
        let value = args["value"]
        switch action {
        case "ready":
            ready = true
            Task { await model.refreshInstallation(); await sound.refresh() }
            return ["appearance": appearance.desktopValues, "state": snapshot(), "results": sessionResults.map(\.values),
                    "search": FileSearchController.desktopSearchControls]
        case "navigate":
            let section = args["section"] as? String ?? ""
            switch section {
            case "settings":
                switch args["tab"] as? String {
                case "setup": app.activeSection = .setup
                case "about": app.activeSection = .about
                default: app.activeSection = .system
                }
            case "voice":
                app.voiceSettingsTab = VoiceSettingsTab(rawValue: (args["tab"] as? String ?? "").capitalized) ?? .recognition
                app.activeSection = .voice
            case "activity": app.activeSection = .insights
            default:
                if let selected = RailSection(rawValue: section) { app.activeSection = selected }
            }
        case "command":
            guard let input = args["text"] as? String, input.utf8.count <= 4096,
                  CommandValidator.validate(input) != nil || DisplaySafety.isRecoveryRequest(input) else {
                throw DesktopUIError("Enter a supported command of up to 4,096 bytes.")
            }
            app.commandInput = input
            app.executeTypedCommand()
        case "newSession":
            sessionResults.removeAll()
            app.resetDesktopSession()
        case "live":
            guard !app.enrollmentActive, !app.enrollmentPreparing else { return nil }
            if args["enabled"] as? Bool == true {
                app.noteManualMicStart()
                await app.startMicrophone()
                if app.isLiveListening, app.canUseVoiceMode, !app.voiceModeEnabled { app.toggleVoiceMode() }
            } else {
                app.stopMicrophone()
            }
        case "record":
            PillShortcutCoordinator.shared.press(args["mode"] as? String == "command" ? .action : .dictate)
        case "copy":
            guard let text = args["text"] as? String, !text.isEmpty, text.utf8.count <= 1_000_000 else { return false }
            let copied = copy(text)
            if copied { app.statsRecorder.recordCopy(chars: text.count) }
            return copied
        case "openLogs": NSWorkspace.shared.open(CrashDiagnostics.shared.directory)
        case "copyDiagnostics":
            if copy(CrashDiagnostics.shared.summary) { view?.deliver("toast", "Copied diagnostics summary.") }
        case "volume":
            if let level = args["level"] as? Int {
                await sound.apply(.setLevel(min(100, max(0, level))), to: sound.snapshot?.output)
                if let result = sound.lastResult, !result.success { view?.deliver("toast", result.message) }
            }
        case "setting": setPreference(key, value)
        case "appearance":
            setAppearance(key, value)
            return appearance.desktopValues
        case "resetAppearance":
            appearance.reset()
            return appearance.desktopValues
        case "enrollment":
            switch args["operation"] as? String {
            case "start":
                if app.enrollmentPaused { app.resumeEnrollment() }
                else { app.startEnrollment() }
            case "pause": app.stopEnrollment()
            case "retrain", "clear":
                let clear = args["operation"] as? String == "clear"
                if await confirm(clear ? "Clear your voice profile?" : "Retrain your voice profile?",
                                 message: "This removes existing voice samples.", action: clear ? "Clear profile" : "Retrain profile") {
                    if clear { app.resetVoiceProfile() }
                    else { app.retrainVoiceProfile() }
                }
            default: break
            }
        case "nextPhrase": app.advanceEnrollmentPhrase()
        case "searchState", "search", "closeSearch", "cancelSearch", "selectFile", "fileAction":
            return try await search.handleDesktopSearch(action, args)
        case "saveRoutine", "deleteRoutine", "toggleRoutine", "runRoutine":
            try await changeRoutine(action, args)
        case "checkModel": model.checkForUpdates()
        case "installModel": model.installLatest()
        case "cancelModel": model.cancel()
        case "chooseFolder":
            if args["kind"] as? String == "project" { projects.choose(isRoot: true) }
            else { fileLocations.chooseFolder() }
        case "settingsDetails":
            if let group = args["group"] as? String { presentSheet(.settings(group)) }
        case "setupDetails":
            let topic = args["topic"] as? String ?? ""
            if let kind = NoirSetupKind(rawValue: topic == "helper" ? "backend" : topic) { presentSheet(.setup(kind)) }
        case "activity": return await activity(args["range"] as? String ?? "week")
        case "openRunner": await CommandTestHarness.shared.start(app: app)
        case "stopRunner": CommandTestHarness.shared.stop()
        case "testIntent":
            guard let input = args["text"] as? String, !input.isEmpty, input.utf8.count <= 4096 else {
                throw DesktopUIError("Enter a command of up to 4,096 bytes.")
            }
            return try await testIntent(input)
        default: throw DesktopUIError("Unknown Jarvis action.")
        }
        pushState()
        return nil
    }

    private func setPreference(_ key: String, _ value: Any?) {
        if let enabled = value as? Bool {
            switch key {
            case "verifyAction": app.actionPillRequiresVerify = enabled
            case "verifyLive": app.voiceModeRequiresVerify = enabled
            case "spoken": app.voiceResponseEnabled = enabled
            case "rust": app.useRustPipeline = enabled
            case "login":
                login.setEnabled(enabled)
                if let error = login.errorText { view?.deliver("toast", error) }
                if login.requiresApproval { login.openLoginItemsSettings() }
            case "format": dictation.aiFormattingEnabled = enabled
            case "paste": dictation.insertAtCursorEnabled = enabled
            case "original": dictation.copyOriginalEnabled = enabled
            case "eventLog": app.eventLoggingEnabled = enabled
            case "dictationLog": app.dictationDevLogEnabled = enabled
            default: break
            }
        }
        guard let text = value as? String else { return }
        switch key {
        case "engine":
            if ["apple", "whisper"].contains(text) { UserDefaults.standard.set(text, forKey: "jarvis.liveSpeech.engine") }
        case "locale":
            if !text.isEmpty && text.count <= 32 { UserDefaults.standard.set(text, forKey: "jarvis.liveSpeech.locale") }
        case "recordLimit": if let n = Int(text) { dictation.recordingLimitMinutes = min(60, max(1, n)) }
        case "resultDuration": if let n = Int(text) { dictation.cardDismissSeconds = min(10, max(1, n)) }
        case "timeout": if let n = Int(text) { app.sessionTimeoutSeconds = min(10, max(1, n)) }
        default: break
        }
    }

    private func setAppearance(_ key: String, _ value: Any?) {
        if key == "motion", let enabled = value as? Bool { appearance.animateOrb = enabled }
        guard let text = value as? String else { return }
        switch key {
        case "accent": if let accent = AccentTheme(rawValue: text) { appearance.accent = accent }
        case "orb": if let orb = AssistantOrbStyle(rawValue: text) { appearance.orbStyle = orb }
        case "glass": if let percent = Double(text) { appearance.glassOpacity = percent / 100 }
        case "contrast": if let percent = Double(text) { appearance.borderContrast = percent / 100 }
        case "scale":
            let sizes: [String: InterfaceTextSize] = ["0.86": .extraSmall, "0.93": .small, "1": .standard, "1.08": .large, "1.16": .extraLarge]
            if let size = sizes[text] { appearance.textSize = size }
        default: break
        }
    }

    private func copy(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    private func confirm(_ title: String, message: String, action: String) async -> Bool {
        guard let window = view?.window else { return false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return await alert.beginSheetModal(for: window) == .alertSecondButtonReturn
    }

    private func changeRoutine(_ operation: String, _ args: [String: Any]) async throws {
        let idText = args["id"] as? String ?? ""
        let id = UUID(uuidString: idText)
        let existing = app.automations.first(where: { $0.id == id })
        if operation == "saveRoutine" {
            guard idText.isEmpty || existing != nil,
                  let trigger = args["trigger"] as? String, !trigger.isEmpty, trigger.count <= 256,
                  let off = args["off"] as? String, off.count <= 256,
                  let rows = args["actions"] as? [[String: Any]], (1...100).contains(rows.count) else {
                throw DesktopUIError("Enter a trigger phrase and at least one action.")
            }
            guard !app.automations.contains(where: { $0.id != id && $0.keyword.caseInsensitiveCompare(trigger) == .orderedSame }) else {
                throw DesktopUIError("A routine already uses that trigger phrase.")
            }
            let actions = try rows.enumerated().map { index, row in
                guard let type = AutomationActionType(rawValue: row["type"] as? String ?? ""),
                      let text = row["target"] as? String, text.utf8.count <= 4096 else {
                    throw DesktopUIError("Choose a supported action and target.")
                }
                let step = AutomationAction(id: UUID(uuidString: row["id"] as? String ?? "") ?? UUID(),
                    type: type, value: text, requiresPreviousSuccess: index > 0 && row["requires"] as? Bool == true)
                if let error = step.validationMessage { throw DesktopUIError(error) }
                return step
            }
            var updated = app.automations
            if let index = updated.firstIndex(where: { $0.id == id }) {
                updated[index].keyword = trigger
                updated[index].offKeyword = off.isEmpty ? nil : off
                updated[index].actions = actions
            } else {
                updated.append(VoiceAutomation(keyword: trigger, offKeyword: off.isEmpty ? nil : off, actions: actions))
            }
            try app.replaceAutomations(updated)
        } else if let existing {
            switch operation {
            case "runRoutine":
                if existing.isDisabled != true { app.enqueueTypedCommand(existing.keyword, routine: existing) }
            case "toggleRoutine":
                var updated = app.automations
                if let index = updated.firstIndex(where: { $0.id == id }) {
                    updated[index].isDisabled = args["enabled"] as? Bool == true ? nil : true
                    try app.replaceAutomations(updated)
                }
            case "deleteRoutine":
                if await confirm("Delete this routine?", message: existing.keyword, action: "Delete routine") {
                    try app.replaceAutomations(app.automations.filter { $0.id != existing.id })
                }
            default: break
            }
        }
    }

    private func testIntent(_ command: String) async throws -> [String: Any] {
        let harness = CommandTestHarness.shared
        // Reuse the in-process test path. The browser runner remains available
        // separately in Advanced and starts its server only on request.
        return try await harness.evaluateIntent(command: command, app: app)
    }

    private func activity(_ range: String) async -> [String: Any] {
        let provider = StatsProvider(dbManager: app.dbManager)
        let selected = StatsRange(rawValue: range.capitalized) ?? .week
        let buckets = await provider.buckets(for: selected)
        let summary = StatsSummary.sum(buckets)
        let commands = summary.commandsRun + summary.commandsFailed
        let values = [
            "kpiTime": duration(summary.talkSecs), "kpiSessions": summary.sessions.formatted(),
            "kpiCommands": commands.formatted(), "kpiSuccess": commands == 0 ? "—" : "\(Int(summary.successPct.rounded()))%",
            "statWords": (summary.chars / 5).formatted(), "statCopies": summary.copies.formatted(),
            "statFailed": summary.commandsFailed.formatted(), "statPromptTokens": summary.tokensPrompt.formatted(),
            "statCompletionTokens": summary.tokensCompletion.formatted(), "statSaved": duration(summary.timeSavedSecs)
        ]
        let bars: [[String: Any]] = chartBuckets(buckets, range: selected)
        return ["values": values, "bars": bars]
    }

    private func chartBuckets(_ days: [DayBucket], range: StatsRange) -> [[String: Any]] {
        let groups = Dictionary(grouping: days, by: { range == .year || range == .lifetime ? String($0.day.prefix(7)) : $0.day })
        let keys = Array(groups.keys.sorted().suffix(7))
        let sums = keys.map { StatsSummary.sum(groups[$0] ?? []) }
        let peak = max(1, sums.map(\.talkSecs).max() ?? 1)
        return zip(keys, sums).map { label, summary in
            ["date": label.count == 10 ? String(label.suffix(5)) : label,
             "pct": summary.talkSecs / peak * 100, "speak": duration(summary.talkSecs),
             "sess": summary.sessions, "words": summary.chars / 5]
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }
}
