import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let enrollmentCompletedDefaultsKey = "jarvis.enrollment.completed"
    private static let backendSampleCountDefaultsKey = "jarvis.voice.backendSampleCount"

    enum AssistantState: String {
        case idle = "Idle"
        case listening = "Listening for wake word"
        case recording = "Recording command"
        case processing = "Processing"
        case executing = "Executing"
    }

    enum VoiceSessionState: String {
        case idle = "Idle"
        case active = "Session Active"
    }

    @Published var assistantState: AssistantState = .idle
    @Published var voiceSessionState: VoiceSessionState = .idle
    @Published var sessionExpiresAt: Date? = nil
    let sessionTimeout: TimeInterval = 10.0
    private var sessionTimer: Timer? = nil

    private static let sessionExitPhrases: [String] = [
        "stop listening",
        "go to sleep",
        "that's all",
        "goodbye jarvis"
    ]
    @Published var micActive = false
    @Published var audioLevelDB: Float = -160.0
    @Published var audioLevelNormalized: Double = 0.0
    @Published var lastRecognizedSpeech = ""
    @Published var currentCommand = ""
    @Published var logs: [String] = []
    @Published var commandInput = ""
    @Published var voiceModeEnabled = false
    @Published var voiceVerificationStatus = "Unknown Voice ❌"
    @Published var lastVoiceSimilarity = 0.0
    @Published var backendEnrollmentSampleCount = 0
    @Published var automations: [VoiceAutomation] = []
    @Published var backendStatus: String = "Not started"
    @Published var backendStartupError: String?
    /// When true, Jarvis speaks its responses aloud via AVSpeechSynthesizer.
    @Published var voiceResponseEnabled: Bool = false
    /// Current display brightness level (0-100) for UI display and controls.
    @Published var currentBrightness: Int = 50
    /// Combined brightness level (0-100: Software Dimming + DDC Backlight + Contrast).
    @Published var combinedBrightness: Int = 50

    let popupManager = PopupManager()

    @Published var enrollmentPhrases: [String] = [
        // Layer 1 — original phrases
        "Jarvis open Chrome",
        "Jarvis open Finder",
        "Jarvis close VS Code",
        "Jarvis open folder Downloads",
        "Jarvis create file notes dot txt",
        "Jarvis explain recursion",
        "Jarvis what is binary search",
        // Layer 2 — additional phrases for improved accuracy
        "Jarvis play music",
        "Jarvis search Google for Swift UI",
        "Jarvis open YouTube",
        "Jarvis what time is it",
        "Jarvis close Chrome",
        "Jarvis open Documents",
        "Jarvis next song"
    ]
    @Published var enrollmentIndex = 0
    @Published var enrollmentActive = false
    @Published var enrollmentCompleted = false
    @Published var enrollmentMatchedCount = 0
    @Published var enrollmentAttemptCount = 0
    @Published var enrollmentCurrentPhraseMatchCount = 0
    @Published var enrollmentRequiredMatchesPerPhrase = 3
    @Published var latestEnrollmentScore: Double = 0.0
    /// Current enrollment layer: 1 = first 7 phrases, 2 = last 7 phrases
    @Published var enrollmentLayer: Int = 1

    static let layer1PhraseCount = 7
    static let layer2PhraseCount = 7

    private let micManager: MicManager
    private let logger: Logger
    private let dbManager: DBManager
    private let parser = CommandParser()
    private let executor = CommandExecutor()
    private let actionExecutor = ActionExecutor()
    private let automationStore = AutomationStore()
    private let commandNormalizer = CommandNormalizer(model: "qwen2.5-coder:1.5b-base")
    private let voiceAuthClient = VoiceAuthClient()
    private let actionPlanner = ActionPlanner()
    private let backendServiceManager = BackendServiceManager()
    private let displayController = DisplayController()
    private let combinedBrightnessController = CombinedBrightnessController()
    let commandQueue = CommandQueueManager()

    private var previousVoiceDetected = false
    private var lastVoiceTimestamp = Date.distantPast
    private var smoothedAudioLevelDB: Float = -160.0
    private var recordingStartedAt = Date.distantPast
    private var lastFinalTranscriptAt = Date.distantPast
    /// Last text spoken aloud by TTS — used to suppress echo capture.
    private var lastSpokenResponseText: String = ""
    private var lastSpokenResponseAt: Date = .distantPast
    private let ttsEchoSuppressWindow: TimeInterval = 3.0
    /// True while TTS is actively speaking — mic command processing is blocked during this period.
    private var isTTSSpeaking: Bool = false
    /// Tracks whether the current final transcript was already handled by the batch path.
    private var lastBatchHandledTranscript: String = ""
    private static let maxBatchSize = 3
    private var pendingWakeWordDetected = false
    private var pendingWakeWordDetectedAt = Date.distantPast
    private var isStoppingMicrophone = false
    private var lastEnrollmentAcceptedAt = Date.distantPast
    private var lastEnrollmentAcceptedTranscript = ""
    private var lastEnrollmentAttemptAt = Date.distantPast

    private let voiceStartThresholdDB: Float = -42.0
    private let voiceContinueThresholdDB: Float = -50.0
    private let minimumRecordingDuration: TimeInterval = 0.8
    private let requiredSilenceDuration: TimeInterval = 0.6
    private let smoothingFactor: Float = 0.35
    /// Longest unbroken voiced run before the utterance is force-segmented
    /// (see handleAudioLevel). Must sit well inside Rust chunk_seconds=6 so
    /// each segment transcribes mid-speech instead of only at long pauses.
    private static let maxContinuousSpeechSeconds: TimeInterval = 4.0
    private let enrollmentAcceptCooldown: TimeInterval = 1.4
    private let enrollmentAttemptThrottle: TimeInterval = 0.30
    private let voiceVerificationThreshold = 0.70
    private static let verifyAudioSeconds = 3.5
    private static let enrollAudioSeconds = 3.5
    /// Resemblyzer embeds via preprocess_wav at 16 kHz. Exporting at the
    /// same rate removes a resample-variance source between enroll-time
    /// and verify-time embeddings and keeps clips comparable sample-for-sample.
    private static let voiceSampleRate = 16_000.0

    var voiceEnrollmentSampleTarget: Int {
        enrollmentPhrases.count * enrollmentRequiredMatchesPerPhrase
    }

    var voiceProfileReady: Bool {
        enrollmentCompleted && backendEnrollmentSampleCount >= voiceEnrollmentSampleTarget
    }

    var eventLogText: String {
        logs.joined(separator: "\n")
    }

    var currentEnrollmentPhrase: String {
        guard enrollmentPhrases.indices.contains(enrollmentIndex) else { return "Completed" }
        return enrollmentPhrases[enrollmentIndex]
    }

    init(
        micManager: MicManager = MicManager(),
        logger: Logger = Logger(),
        dbManager: DBManager = DBManager()
    ) {
        self.micManager = micManager
        self.logger = logger
        self.dbManager = dbManager
        commandQueue.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        actionExecutor.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        displayController.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        combinedBrightnessController.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        // Wire Whisper command transcripts (VAD-segmented utterances from the
        // Rust STT core) into the existing transcript pipeline.
        STTRouter.shared.onCommandTranscript = { [weak self] text in
            Task { @MainActor in
                self?.appendLog("[Speech][Whisper] FINAL: '\(text)'")
                self?.handleTranscript(text, isFinal: true)
            }
        }
        // Live partials (per-chunk stitch, ~6 s cadence) drive the main
        // window "LIVE TRANSCRIPT" card while the user is still talking.
        STTRouter.shared.onCommandPartial = { [weak self] text in
            Task { @MainActor in
                self?.handleTranscript(text, isFinal: false)
            }
        }
        STTRouter.shared.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        // Wire TTS echo suppression: track every text we speak so the mic
        // ignores transcripts that mirror our own output.
        // Also set isTTSSpeaking flag to block all command processing during speech.
        ResponseEngine.shared.onSpeak = { [weak self] spokenText in
            Task { @MainActor in
                self?.lastSpokenResponseText = spokenText
                self?.lastSpokenResponseAt   = Date()
                self?.isTTSSpeaking = true
            }
        }
        ResponseEngine.shared.onSpeakEnd = { [weak self] in
            Task { @MainActor in
                self?.isTTSSpeaking = false
            }
        }

        self.automations = automationStore.load()
        refreshBrightness()

        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkSessionExpiration()
            }
        }
    }

    // MARK: - Display Brightness UI Controls

    func refreshBrightness() {
        if let val = displayController.getCurrentBrightness() {
            currentBrightness = val
        }
    }

    func increaseBrightnessUI() {
        let msg = displayController.execute(.increaseBrightness(by: 10))
        appendLog("[UI] \(msg)")
        refreshBrightness()
    }

    func decreaseBrightnessUI() {
        let msg = displayController.execute(.decreaseBrightness(by: 10))
        appendLog("[UI] \(msg)")
        refreshBrightness()
    }

    func setBrightnessUI(_ percent: Int) {
        let msg = displayController.execute(.setBrightness(percent))
        appendLog("[UI] \(msg)")
        refreshBrightness()
    }

    // MARK: - Combined Brightness Test Controls (GUI Only)

    func increaseCombinedBrightnessUI() {
        let msg = combinedBrightnessController.increase(by: 10)
        appendLog("[UI Combined] \(msg)")
        combinedBrightness = combinedBrightnessController.currentCombinedLevel
    }

    func decreaseCombinedBrightnessUI() {
        let msg = combinedBrightnessController.decrease(by: 10)
        appendLog("[UI Combined] \(msg)")
        combinedBrightness = combinedBrightnessController.currentCombinedLevel
    }

    func setCombinedBrightnessUI(_ percent: Int) {
        let msg = combinedBrightnessController.setCombinedBrightness(percent)
        appendLog("[UI Combined] \(msg)")
        combinedBrightness = combinedBrightnessController.currentCombinedLevel
    }

    // MARK: - Voice Session State Management (Requirement 1 - 6, 8)

    func checkSessionExpiration() {
        guard voiceSessionState == .active, let expiresAt = sessionExpiresAt else { return }
        if Date() > expiresAt {
            transitionToSessionState(.idle, reason: "session expired after timeout (\(Int(sessionTimeout))s)")
        }
    }

    func transitionToSessionState(_ newState: VoiceSessionState, reason: String) {
        let oldState = voiceSessionState
        guard oldState != newState else { return }
        voiceSessionState = newState
        if newState == .idle {
            sessionExpiresAt = nil
        }
        appendLog("[VoiceSession] State transition: \(oldState.rawValue) → \(newState.rawValue) (\(reason))")
    }

    func extendSessionTimeout(forCommand command: String) {
        let newExpiry = Date().addingTimeInterval(sessionTimeout)
        sessionExpiresAt = newExpiry
        let timeStr = newExpiry.formatted(date: .omitted, time: .standard)
        if voiceSessionState != .active {
            transitionToSessionState(.active, reason: "verified speaker command: '\(command)'")
        } else {
            appendLog("[VoiceSession] Session extended (+10s) by command: '\(command)'. Expires at \(timeStr)")
        }
    }

    // MARK: - Fix #1: Hard Reset Voice Pipeline
    /// Wipes ALL cross-transcript state so no stale command can bleed into
    /// a new voice recognition session. Called before every session restart.
    private func resetVoicePipelineState() {
        lastBatchHandledTranscript   = ""
        pendingWakeWordDetected      = false
        pendingWakeWordDetectedAt    = .distantPast
        lastFinalTranscriptAt        = .distantPast
        appendLog("[Voice] Pipeline state hard-reset.")
    }

    func bootstrap() async {
        await startBundledBackendIfNeeded()

        dbManager.setup()
        if dbManager.isConfigured {
            appendLog("PostgreSQL logging is enabled.")
        } else {
            appendLog("PostgreSQL logging disabled (optional). To enable: export PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=jarvis_db PGUSER=jarvis_user — missing: \(DBManager.missingEnvKeys.joined(separator: ","))")
        }

        restoreEnrollmentState()
        await syncVoiceProfileStatusFromBackend()
        await startMicrophone()
    }

    func shutdown() {
        stopMicrophone()
        backendServiceManager.stopIfNeeded { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }
    }

    private func startBundledBackendIfNeeded() async {
        backendStatus = "Starting backend..."

        let result = await backendServiceManager.startIfNeeded { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }

        if result.success {
            backendStartupError = nil
            backendStatus = "Backend running"
            appendLog("[Backend] \(result.message)")
        } else {
            backendStartupError = result.message
            backendStatus = "Backend failed"
            appendLog("[Backend][ERROR] \(result.message)")
            popupManager.show(message: "Backend start failed. Some features may be unavailable.", icon: "exclamationmark.triangle.fill", duration: 4)
        }
    }

    func startMicrophone() async {
        do {
            isStoppingMicrophone = false

            // Hard reset mic session state before reinitializing.
            // Speech recognition is fully offline (Whisper STT core) —
            // no Speech permission needed, mic permission only.
            resetVoicePipelineState()
            WhisperCommandListener.shared.reset()
            micManager.stopListening()

            try await micManager.startListeningWithPermission(
                onLevelUpdate: { [weak self] level in
                    Task { @MainActor in
                        self?.handleAudioLevel(level)
                    }
                },
                onAudioBuffer: nil
            )

            micActive = true
            assistantState = .listening
            appendLog("Microphone + Whisper recognizer started.")
        } catch {
            micActive = false
            assistantState = .idle
            appendLog("Microphone start failed: \(error.localizedDescription)")
        }
    }

    func stopMicrophone() {
        isStoppingMicrophone = true
        pendingWakeWordDetected = false
        WhisperCommandListener.shared.reset()
        micManager.stopListening()
        micActive = false
        assistantState = .idle
        appendLog("Microphone stopped.")
    }

    func startEnrollment() {
        enrollmentIndex = 0
        enrollmentMatchedCount = 0
        enrollmentAttemptCount = 0
        enrollmentCurrentPhraseMatchCount = 0
        latestEnrollmentScore = 0
        voiceModeEnabled = false
        voiceVerificationStatus = "Building Voice Profile..."
        lastEnrollmentAcceptedAt = .distantPast
        lastEnrollmentAcceptedTranscript = ""
        lastEnrollmentAttemptAt = .distantPast
        enrollmentActive = true
        enrollmentCompleted = false
        persistEnrollmentCompleted(false)
        appendLog("Voice enrollment started. Repeat each phrase \(enrollmentRequiredMatchesPerPhrase)x.")
        appendLog("Existing voice profile is preserved until new samples are collected.")
        // Reset the backend store so re-enrollment starts from a clean slate —
        // the store is append-only, so without this every re-run stacks on the
        // old samples (the 63-vs-42 pollution) and drags similarity averages down.
        // Runs detached: enrollment must not block on a cold backend.
        Task {
            do {
                try await voiceAuthClient.reset()
                await MainActor.run {
                    backendEnrollmentSampleCount = 0
                    persistBackendSampleCount(0)
                    appendLog("Voice profile store reset — re-enrolling from 0/\(voiceEnrollmentSampleTarget).")
                }
            } catch {
                await MainActor.run {
                    appendLog("[Voice] Profile reset failed (\(error.localizedDescription)) — old samples preserved; scores may skew high-N. POST /reset manually to clear.")
                }
            }
        }
    }

    func resetVoiceProfile() {
        Task {
            do {
                try await voiceAuthClient.reset()
                backendEnrollmentSampleCount = 0
                persistBackendSampleCount(0)
                voiceVerificationStatus = "No Voice Profile ❌"
                appendLog("Voice profile cleared (0/\(voiceEnrollmentSampleTarget)). Re-enroll to rebuild.")
            } catch {
                appendLog("[Voice] Profile reset failed: \(error.localizedDescription)")
            }
        }
    }

    func stopEnrollment() {
        enrollmentActive = false
        appendLog("Voice enrollment stopped.")
    }

    func executeTypedCommand() {
        let raw = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        commandInput = ""
        guard !raw.isEmpty else { return }

        guard let command = CommandValidator.validate(raw) else {
            appendLog("[Validator] Invalid command skipped: '\(raw)'")
            return
        }

        appendLog("[Typed] Received: '\(command)'")

        let priority = CommandPriority.classify(command)
        commandQueue.enqueue(text: command, priority: priority) { [weak self] in
            await self?.runCommand(command)
        }
    }

    func clearEventLog() {
        logs.removeAll()
    }

    func saveAutomation(
        keyword: String,
        offKeyword: String?,
        actions: [AutomationAction],
        editingID: UUID? = nil
    ) {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return }

        let normalizedOffKeyword = offKeyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedActions = actions.filter { !$0.type.requiresValue || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !normalizedActions.isEmpty else { return }

        if let editingID,
           let index = automations.firstIndex(where: { $0.id == editingID }) {
            automations[index].keyword = trimmedKeyword
            automations[index].offKeyword = normalizedOffKeyword
            automations[index].actions = normalizedActions
        } else {
            automations.append(
                VoiceAutomation(
                    keyword: trimmedKeyword,
                    offKeyword: normalizedOffKeyword,
                    actions: normalizedActions
                )
            )
        }

        persistAutomations()
    }

    func deleteAutomation(id: UUID) {
        automations.removeAll { $0.id == id }
        persistAutomations()
    }

    private func persistAutomations() {
        do {
            try automationStore.save(automations)
        } catch {
            appendLog("[Automation][ERROR] Failed to save automations: \(error.localizedDescription)")
        }
    }

    private func handleTranscript(_ transcript: String, isFinal: Bool) {
        lastRecognizedSpeech = transcript

        // Live partials update the on-screen card immediately (the user
        // asked for visible speech→text while talking). Command execution
        // still waits for the final below.
        guard isFinal else { return }

        if voiceModeEnabled && containsWakeWord(transcript) {
            pendingWakeWordDetected = true
            pendingWakeWordDetectedAt = Date()
        }

        // ── TTS echo suppression ─────────────────────────────────────
        if !lastSpokenResponseText.isEmpty {
            let compactTranscript = Self.normalizeCompact(transcript)
            let compactSpoken    = Self.normalizeCompact(lastSpokenResponseText)
            let windowElapsed    = Date().timeIntervalSince(lastSpokenResponseAt)
            if windowElapsed < ttsEchoSuppressWindow
                && (compactTranscript.contains(compactSpoken)
                    || compactSpoken.contains(compactTranscript)) {
                appendLog("[Echo] Suppressed TTS echo: '\(transcript)'")
                return
            }
        }

        // ── Single entry point ───────────────────────────────────
        // Whisper delivers discrete finals per VAD-segmented utterance.
        // The batch path below is the SOLE command entry (the old Apple
        // streaming dual-path was removed with SFSpeechRecognizer).
        // (isFinal is guaranteed here by the early return above.)

        dbManager.saveEvent(
            eventType: "speech_final",
            transcript: transcript,
            metadata: [
                "enrollment_active": String(enrollmentActive),
                "enrollment_completed": String(enrollmentCompleted)
            ]
        )

        if enrollmentActive {
            handleEnrollmentTranscript(transcript, isFinal: true)
            return
        }

        guard enrollmentCompleted else {
            appendLog("Enrollment required before voice command execution.")
            return
        }

        // ── Explicit exit phrases check (Requirement 6) ───────────────
        let lowerTranscript = transcript.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.sessionExitPhrases.contains(where: { lowerTranscript.contains($0) }) {
            appendLog("[VoiceSession] Explicit exit phrase detected: '\(transcript)'")
            transitionToSessionState(.idle, reason: "exit phrase detected")
            return
        }

        // ── TTS feedback loop guard ──────────────────────────────────
        if isTTSSpeaking {
            appendLog("[Echo] Dropped transcript: TTS is speaking (feedback loop prevention)")
            return
        }

        guard voiceModeEnabled else {
            appendLog("[Voice] dropped: voice mode off — transcript '\(transcript)' ignored.")
            return
        }

        let now = Date()
        guard now.timeIntervalSince(lastFinalTranscriptAt) > 0.7 else {
            appendLog("[Voice] dropped: debounce (≤0.7 s since last final) — transcript '\(transcript)' ignored.")
            return
        }
        lastFinalTranscriptAt = now

        // Check session expiration before evaluating transcript
        checkSessionExpiration()

        let isSessionValid = (voiceSessionState == .active && sessionExpiresAt != nil && now <= sessionExpiresAt!)

        // ── [Voice] NEW SESSION START ─────────────────────────────────
        // Log every new voice session so the pipeline is fully traceable.
        appendLog("[Voice] NEW SESSION START — transcript: '\(transcript)' (session active: \(isSessionValid))")

        // ── Deterministic wake-word split / Session follow-up ──────────
        let hasWakeWord = containsWakeWord(transcript)
        var rawSegments: [String] = []

        if hasWakeWord {
            rawSegments = transcript
                .replacingOccurrences(of: "(?i)\\bjarvis\\b", with: "|",
                                       options: [.regularExpression, .caseInsensitive])
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            appendLog("[Voice] segments count: \(rawSegments.count) (from wake-word split)")
            NSLog("[Voice] split into %d raw segments", rawSegments.count)
        } else if isSessionValid {
            rawSegments = [transcript]
            appendLog("[VoiceSession] Processing in-session follow-up command: '\(transcript)'")
        } else if pendingWakeWordDetected && now.timeIntervalSince(pendingWakeWordDetectedAt) <= 4.0 {
            rawSegments = [transcript]
            appendLog("[Voice] segments count: 1 (pending wake-word fallback)")
        }

        pendingWakeWordDetected = false

        guard !rawSegments.isEmpty else {
            appendLog("[Voice] no segments — wake word not found, dropping transcript.")
            return
        }

        // ── Clean each segment ────────────────────────────────────────
        var cleanedCommands: [String] = []
        for segment in rawSegments {
            guard let cmd = cleanVoiceSegment(segment) else { continue }
            cleanedCommands.append(cmd)
        }

        guard !cleanedCommands.isEmpty else {
            appendLog("[Voice] dropped: no valid command after cleaning \(rawSegments.count) segment(s) — transcript '\(transcript)' ignored.")
            return
        }

        // ── Sanitize batch: dedup + conflict resolution + cap ─────────
        let sanitized = sanitizeBatch(cleanedCommands)
        appendLog("[Voice] final commands: \(sanitized.map { "'\($0)'" }.joined(separator: ", "))")

        for cmd in sanitized {
            appendLog("[Voice] cleaned: '\(cmd)'")
        }

        lastBatchHandledTranscript = Self.normalizeCompact(transcript)

        for validated in sanitized {
            let priority = CommandPriority.classify(validated)
            let accepted = commandQueue.enqueue(text: validated, priority: priority) { [weak self] in
                await self?.verifyThenRunCommand(validated)
            }
            if !accepted {
                appendLog("[Voice] dropped: queue rejected '\(validated)' (see [Queue] line above).")
            }
        }
    }

    // MARK: - Voice segment cleaner

    private func cleanVoiceSegment(_ segment: String) -> String? {
        var cleaned = sanitizeSpokenCommand(segment)
        cleaned = removeTrailingWakeWordFragment(from: cleaned)
        cleaned = collapseRepeatedWords(cleaned)
        cleaned = normalizeMisheardTargets(in: cleaned)

        // Strip filler words
        let fillerRegex = "\\b(please|okay|ok|uh|um|you know|like)\\b"
        cleaned = cleaned
            .replacingOccurrences(of: fillerRegex, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip any residual jarvis tokens (edge-case partial matches)
        cleaned = cleaned
            .replacingOccurrences(of: "(?i)\\bjarvis\\b", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Enforce 8-word max per command
        let tokens = cleaned.split(separator: " ").map(String.init)
        let capped  = tokens.count > 8 ? Array(tokens.prefix(8)).joined(separator: " ") : cleaned

        guard let validated = CommandValidator.validate(capped) else {
            if !capped.isEmpty { appendLog("[Validator] Rejected segment: '\(capped)'") }
            return nil
        }
        return validated
    }

    private func collapseRepeatedWords(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        var output: [String] = []
        for token in tokens {
            if output.last?.lowercased() != token.lowercased() {
                output.append(token)
            }
        }
        return output.joined(separator: " ")
    }

    // MARK: - Batch sanitizer (dedup + conflict resolution + cap)

    private func sanitizeBatch(_ raw: [String]) -> [String] {
        let original = raw.count

        // Step 1: Deduplicate — last occurrence wins
        var seen = Set<String>()
        var deduplicated: [String] = []
        for cmd in raw.reversed() {
            let key = cmd.lowercased().trimmingCharacters(in: .whitespaces)
            if seen.insert(key).inserted { deduplicated.insert(cmd, at: 0) }
        }

        // Step 2: Build app-target → winning command map
        let appPrefixes = ["open ", "close ", "launch ", "start ", "run "]
        func appTarget(for cmd: String) -> (verb: String, target: String)? {
            let lower = cmd.lowercased()
            for prefix in appPrefixes {
                if lower.hasPrefix(prefix) {
                    let target = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    return (prefix.trimmingCharacters(in: .whitespaces), target)
                }
            }
            return nil
        }

        var winner = [String: String]()
        for cmd in deduplicated {
            if let (verb, target) = appTarget(for: cmd) {
                if let prev = winner[target] {
                    let prevVerb = appTarget(for: prev)?.verb ?? "?"
                    appendLog("[Conflict] resolved: \(target) \(prevVerb) → \(verb) (last wins)")
                }
                winner[target] = cmd
            }
        }

        // Step 3: Rebuild in ORIGINAL ORDER
        var emittedTargets = Set<String>()
        var combined: [String] = []
        for cmd in deduplicated {
            if let (_, target) = appTarget(for: cmd) {
                if let w = winner[target], w == cmd, !emittedTargets.contains(target) {
                    combined.append(cmd)
                    emittedTargets.insert(target)
                }
            } else {
                combined.append(cmd)
            }
        }

        // Step 4: Cap at maxBatchSize
        if combined.count > Self.maxBatchSize {
            appendLog("[Batch] capped: \(combined.count) → \(Self.maxBatchSize) commands")
            combined = Array(combined.suffix(Self.maxBatchSize))
        }

        if combined.count != original {
            appendLog("[Batch] sanitized: \(original) → \(combined.count) commands")
        }
        return combined
    }

    private func handleEnrollmentTranscript(_ transcript: String, isFinal: Bool) {
        let cleanedTranscript = normalizeEnrollmentTranscript(transcript)
        guard !cleanedTranscript.isEmpty else { return }
        guard enrollmentPhrases.indices.contains(enrollmentIndex) else { return }

        let now = Date()
        if !isFinal && now.timeIntervalSince(lastEnrollmentAttemptAt) < enrollmentAttemptThrottle {
            return
        }
        lastEnrollmentAttemptAt = now

        enrollmentAttemptCount += 1

        let target = enrollmentPhrases[enrollmentIndex]
        let score = phraseMatchScore(target: target, recognized: cleanedTranscript)
        latestEnrollmentScore = score

        let requiredTokens = requiredIntentTokens(for: target)
        let recognizedTokenSet = Set(Self.normalizedTokens(from: cleanedTranscript))
        let requiredTokenHits = requiredTokens.filter { recognizedTokenSet.contains($0) }.count
        let requiredTokenRatio: Double = requiredTokens.isEmpty ? 0 : Double(requiredTokenHits) / Double(requiredTokens.count)

        let requiredScore = isFinal ? 0.48 : 0.58
        let keywordGate = requiredTokens.count <= 2 ? requiredTokenHits >= 1 : requiredTokenRatio >= 0.60
        let matched = keywordGate && score >= requiredScore

        dbManager.saveEvent(
            eventType: "enrollment_attempt",
            transcript: cleanedTranscript,
            targetPhrase: target,
            score: score,
            matched: matched,
            phraseIndex: enrollmentIndex + 1,
            metadata: [
                "is_final": String(isFinal),
                "required_token_hits": String(requiredTokenHits),
                "required_token_ratio": String(format: "%.2f", requiredTokenRatio),
                "required_token_count": String(requiredTokens.count)
            ]
        )

        if matched {
            if now.timeIntervalSince(lastEnrollmentAcceptedAt) < enrollmentAcceptCooldown {
                return
            }

            let currentNormalized = Self.normalizeCompact(cleanedTranscript)
            let previousNormalized = Self.normalizeCompact(lastEnrollmentAcceptedTranscript)
            if !previousNormalized.isEmpty {
                let duplicateDistance = Self.levenshteinDistance(lhs: currentNormalized, rhs: previousNormalized)
                let maxLen = max(currentNormalized.count, previousNormalized.count)
                if maxLen > 0 {
                    let duplicateSimilarity = 1.0 - (Double(duplicateDistance) / Double(maxLen))
                    if duplicateSimilarity > 0.96 {
                        return
                    }
                }
            }

            lastEnrollmentAcceptedAt = now
            lastEnrollmentAcceptedTranscript = cleanedTranscript
            enrollmentMatchedCount += 1
            enrollmentCurrentPhraseMatchCount += 1

            let phraseNumber = enrollmentIndex + 1
            let phraseRepetition = enrollmentCurrentPhraseMatchCount
            appendLog(
                "Phrase \(enrollmentIndex + 1) matched " +
                "(\(enrollmentCurrentPhraseMatchCount)/\(enrollmentRequiredMatchesPerPhrase), score: \(String(format: "%.2f", score)), token-hit: \(requiredTokenHits)/\(requiredTokens.count))."
            )

            Task {
                await enrollMatchedVoiceSample(
                    phraseNumber: phraseNumber,
                    repetition: phraseRepetition,
                    transcript: cleanedTranscript
                )
            }

            if enrollmentCurrentPhraseMatchCount >= enrollmentRequiredMatchesPerPhrase {
                enrollmentIndex += 1
                enrollmentCurrentPhraseMatchCount = 0
                appendLog("Phrase \(enrollmentIndex) completed. Moving to next phrase.")
            }

            dbManager.saveEvent(
                eventType: "enrollment_match",
                transcript: cleanedTranscript,
                targetPhrase: target,
                score: score,
                matched: true,
                phraseIndex: enrollmentIndex,
                metadata: [
                    "match_count_total": String(enrollmentMatchedCount),
                    "match_count_phrase": String(enrollmentCurrentPhraseMatchCount)
                ]
            )

            if enrollmentIndex >= enrollmentPhrases.count {
                enrollmentActive = false
                enrollmentCompleted = true
                persistEnrollmentCompleted(true)

                if backendEnrollmentSampleCount >= voiceEnrollmentSampleTarget {
                    voiceVerificationStatus = "Voice Enrolled ✅"
                    appendLog("Voice enrollment completed. Voice profile ready (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget) samples).")
                } else {
                    voiceVerificationStatus = "Finalizing Voice Profile..."
                    appendLog("Voice phrases completed. Waiting for final backend voice samples (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget)).")
                }

                dbManager.saveEvent(
                    eventType: "enrollment_completed",
                    transcript: lastRecognizedSpeech,
                    matched: true,
                    phraseIndex: enrollmentPhrases.count
                )
            }
        } else {
            appendLog("Phrase mismatch (score: \(String(format: "%.2f", score)), token-hit: \(requiredTokenHits)/\(requiredTokens.count)). Please repeat phrase \(enrollmentIndex + 1).")
        }
    }

    private func restoreEnrollmentState() {
        let defaultsFlag = UserDefaults.standard.bool(forKey: Self.enrollmentCompletedDefaultsKey)
        let dbFlag = dbManager.hasEnrollmentCompletionEvent()
        let savedBackendCount = UserDefaults.standard.integer(forKey: Self.backendSampleCountDefaultsKey)

        backendEnrollmentSampleCount = savedBackendCount

        if defaultsFlag || dbFlag {
            enrollmentCompleted = true
            enrollmentActive = false
            appendLog("Enrollment restored from saved state.")
            if !defaultsFlag {
                persistEnrollmentCompleted(true)
            }

            if savedBackendCount >= voiceEnrollmentSampleTarget {
                voiceVerificationStatus = "Voice Enrolled ✅"
            } else if savedBackendCount > 0 {
                voiceVerificationStatus = "Finalizing Voice Profile..."
            }
        }
    }

    private func persistEnrollmentCompleted(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.enrollmentCompletedDefaultsKey)
    }

    private func persistBackendSampleCount(_ value: Int) {
        UserDefaults.standard.set(value, forKey: Self.backendSampleCountDefaultsKey)
    }

    private func syncVoiceProfileStatusFromBackend() async {
        do {
            let enrolledCount = try await voiceAuthClient.enrolledCount()
            backendEnrollmentSampleCount = enrolledCount
            persistBackendSampleCount(enrolledCount)

            if enrollmentCompleted {
                if enrolledCount >= voiceEnrollmentSampleTarget {
                    voiceVerificationStatus = "Voice Enrolled ✅"
                    appendLog("Voice profile restored from backend (\(enrolledCount)/\(voiceEnrollmentSampleTarget)).")
                } else if enrolledCount > 0 {
                    voiceVerificationStatus = "Voice Profile Incomplete ⚠️"
                    appendLog("Enrollment restored, but backend voice samples are incomplete (\(enrolledCount)/\(voiceEnrollmentSampleTarget)).")
                } else {
                    voiceVerificationStatus = "Voice Profile Missing ⚠️"
                    appendLog("Enrollment restored but backend voice profile is empty. Run enrollment once to rebuild speaker samples.")
                }
            }
        } catch {
            if backendEnrollmentSampleCount >= voiceEnrollmentSampleTarget {
                voiceVerificationStatus = "Voice Enrolled ✅"
            }
            appendLog("Voice backend stats unavailable. Using saved profile state (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget)).")
        }
    }

    private func phraseMatchScore(target: String, recognized: String) -> Double {
        let targetTokens = Set(Self.normalizedTokens(from: target))
        let recognizedTokens = Set(Self.normalizedTokens(from: recognized))
        guard !targetTokens.isEmpty else { return 0 }

        let tokenIntersection = targetTokens.intersection(recognizedTokens).count
        let tokenScore = Double(tokenIntersection) / Double(targetTokens.count)

        let targetNormalized = target.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let recognizedNormalized = recognized.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)

        let maxLen = max(targetNormalized.count, recognizedNormalized.count)
        guard maxLen > 0 else { return tokenScore }

        let distance = Self.levenshteinDistance(lhs: targetNormalized, rhs: recognizedNormalized)
        let charScore = 1.0 - (Double(distance) / Double(maxLen))

        return (0.6 * tokenScore) + (0.4 * max(0.0, charScore))
    }

    private static func levenshteinDistance(lhs: String, rhs: String) -> Int {
        let lhsArray = Array(lhs)
        let rhsArray = Array(rhs)

        var distance = Array(repeating: Array(repeating: 0, count: rhsArray.count + 1), count: lhsArray.count + 1)

        for i in 0...lhsArray.count {
            distance[i][0] = i
        }

        for j in 0...rhsArray.count {
            distance[0][j] = j
        }

        for i in 1...lhsArray.count {
            for j in 1...rhsArray.count {
                let cost = lhsArray[i - 1] == rhsArray[j - 1] ? 0 : 1
                distance[i][j] = min(
                    distance[i - 1][j] + 1,
                    min(
                        distance[i][j - 1] + 1,
                        distance[i - 1][j - 1] + cost
                    )
                )
            }
        }

        return distance[lhsArray.count][rhsArray.count]
    }

    func toggleVoiceMode() {
        guard voiceProfileReady else {
            voiceModeEnabled = false
            appendLog("Complete 7x3 enrollment voice samples before enabling voice mode.")
            return
        }
        voiceModeEnabled.toggle()
        pendingWakeWordDetected = false
        appendLog("Voice mode \(voiceModeEnabled ? "enabled" : "disabled").")
    }

    private func sanitizeSpokenCommand(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[\\p{Punct}\\s]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsWakeWord(_ text: String) -> Bool {
        text.lowercased().range(of: "\\bjarvis\\b", options: .regularExpression) != nil
    }

    // MARK: - Speech session helpers (Whisper era)
    //
    // Utterances are VAD-segmented and self-isolated: each silence boundary
    // finishes one STT-core recording whose transcript arrives via STTRouter.
    // No session restart is ever needed (that was an SFSpeechRecognizer
    // cumulative-buffer workaround — retired with the Apple recognizer).
    //
    // NOTE: maybeExecuteLiveVoiceCommand (the old dual-path entry) was
    // deleted here — the batch path in handleTranscript is the SOLE entry.
    // isActionableCommand / prepareVoiceCommandCandidate /
    // truncateAtFillerBoundary went with it (dual-path only).

    private func normalizeMisheardTargets(in command: String) -> String {
        let lower = command.lowercased()
        if lower.hasPrefix("open ") || lower.hasPrefix("close ") {
            if lower.contains("get her desktop") ||
                lower.contains("getha desktop") ||
                lower.contains("get desktop") ||
                lower.contains("gate desktop") {
                let verb = lower.hasPrefix("close ") ? "close" : "open"
                return "\(verb) GitHub Desktop"
            }
        }
        return command
    }

    private func removeTrailingWakeWordFragment(from command: String) -> String {
        var tokens = command.split(separator: " ").map(String.init)
        guard let last = tokens.last?.lowercased() else { return command }

        let wakeFragments = ["ja", "jar", "jarv", "jarvi", "jarvis"]
        if wakeFragments.contains(last) {
            tokens.removeLast()
        }

        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchedAutomation(for command: String) -> (automation: VoiceAutomation, isOffVariant: Bool)? {
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

    private func executeAutomation(_ automation: VoiceAutomation, isOffVariant: Bool) async {
        if isOffVariant {
            appendLog("[Automation] Off variant matched for '\(automation.keyword)'.")
            ResponseEngine.shared.respond(to: "Automation \(automation.keyword) turned off", speak: voiceResponseEnabled)
            return
        }

        appendLog("[Automation] Executing \(automation.actions.count) actions for '\(automation.keyword)'")
        assistantState = .executing

        for action in automation.actions {
            if action.type == .timer {
                let timerText = action.value.trimmingCharacters(in: .whitespacesAndNewlines)
                appendLog("[Automation] Timer started: \(timerText.isEmpty ? "custom" : timerText)")
                continue
            }

            if action.type == .stopwatch {
                appendLog("[Automation] Stopwatch started")
                continue
            }

            if action.type == .openFile {
                let result = openFilePath(action.value)
                appendLog(result ? "[Automation] Opened file: \(action.value)" : "[Automation][ERROR] Failed opening file: \(action.value)")
            } else if let planned = plannedAction(for: action) {
                await actionExecutor.execute(
                    plan: [planned],
                    onStepStart: { [weak self] plannedAction in
                        Task { @MainActor in
                            self?.appendLog("[Automation] ▶ \(plannedAction.description)")
                        }
                    },
                    onStepComplete: { [weak self] result in
                        Task { @MainActor in
                            let prefix = result.success ? "✓" : "✗"
                            self?.appendLog("[Automation] \(prefix) \(result.message)")
                        }
                    }
                )
            }

            let delayMs = UInt64(Int.random(in: 100...300))
            try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
        }

        assistantState = micActive ? .listening : .idle
        ResponseEngine.shared.respond(to: "Automation \(automation.keyword) executed", speak: voiceResponseEnabled)
    }

    private func plannedAction(for action: AutomationAction) -> PlannedAction? {
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

    private func openFilePath(_ rawPath: String) -> Bool {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }

        let expanded = (path as NSString).expandingTildeInPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [expanded]

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            appendLog("[Automation][ERROR] Open file failed: \(error.localizedDescription)")
            return false
        }
    }

    private func runCommand(_ command: String) async {
        guard !command.isEmpty else { return }

        if let match = matchedAutomation(for: command) {
            appendLog("[Automation] Triggered keyword: '\(match.automation.keyword)'")
            await executeAutomation(match.automation, isOffVariant: match.isOffVariant)
            return
        }

        // --- Quick informational commands (time / date / month / day) ---
        if tryHandleQuickInfoCommand(command) { return }
        // ---

        // --- Safety pre-check (existing blocklist) ---
        if let blockedReason = blockedCommandReason(command) {
            appendLog("Blocked command: \(blockedReason)")
            dbManager.saveEvent(
                eventType: "command_blocked",
                transcript: command,
                matched: false,
                metadata: ["reason": blockedReason]
            )
            return
        }

        // --- SafetyGuard (new, covers install / sudo / destructive) ---
        switch SafetyGuard.validate(rawCommand: command) {
        case .blocked(let reason):
            appendLog("⛔ Safety blocked: \(reason)")
            dbManager.saveEvent(
                eventType: "safety_blocked",
                transcript: command,
                matched: false,
                metadata: ["reason": reason]
            )
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            return
        case .installPreview(let cmd, let source):
            appendLog("🔒 Install preview (not executed): '\(cmd)'. \(source)")
            dbManager.saveEvent(
                eventType: "install_preview",
                transcript: command,
                matched: false,
                metadata: ["command": cmd, "source": source]
            )
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            return
        case .allowed:
            break
        }

        // --- ActionPlanner: multi-step intent parsing ---
        assistantState = .processing
        currentCommand = command
        lastRecognizedSpeech = command
        appendLog("[Plan] Planning: '\(command)'")

        let plan = await actionPlanner.plan(from: command)

        // ✅ Log the detected intent so the pipeline is fully traceable
        if let first = plan.first {
            switch first {
            case .systemInfo(let i):     appendLog("[Intent] INFO: \(i.description)")
            case .volumeControl(let a):  appendLog("[Intent] detected: \(a.description) → volume (ActionExecutor)")
            case .mediaControl(let a):   appendLog("[Intent] detected: \(a.description) → media (ActionExecutor)")
            case .displayControl(let a): appendLog("[Intent] detected: \(a.description) → display (ActionExecutor)")
            case .aiQuery:               appendLog("[Intent] detected: ai_query → Ollama")
            case .openApp(let n):        appendLog("[Intent] detected: open_app(\(n))")
            case .closeApp(let n):       appendLog("[Intent] detected: close_app(\(n))")
            case .openURL(let u):        appendLog("[Intent] detected: open_url(\(u))")
            case .searchWeb(let e, let q): appendLog("[Intent] detected: search(\(e), '\(q)')")
            case .openFolder(let p):     appendLog("[Intent] detected: open_folder(\(p))")
            default:                     appendLog("[Intent] detected: \(first.description)")
            }
        }

        // Determine if the plan is multi-step or a single action that maps
        // cleanly to the legacy single-command pipeline.
        let isSingleLegacy = planIsSingleLegacyAction(plan)

        if !isSingleLegacy {
            // == Multi-step (or media / URL / volume / search) path ==
            if plan.count > 1 {
                appendLog("[Plan] \(plan.count) steps:")
                plan.enumerated().forEach { i, a in appendLog("  \(i + 1). \(a)") }
            } else {
                appendLog("[Plan] \(plan.first?.description ?? "—")")
            }

            assistantState = .executing
            var stepResults: [String] = []
            let speakResponses = voiceResponseEnabled

            await actionExecutor.execute(
                plan: plan,
                onStepStart: { [weak self] action in
                    Task { @MainActor in
                        self?.appendLog("  ▶ \(action.description)")
                    }
                },
                onStepComplete: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        let prefix = result.success ? "✓" : "✗"
                        self.appendLog("  \(prefix) \(result.message)")
                        stepResults.append(result.message)
                        ResponseEngine.shared.respond(
                            action: result.action,
                            result: result,
                            speak: speakResponses
                        )
                    }
                }
            )

            let combinedResult = stepResults.joined(separator: " | ")
            dbManager.saveEvent(
                eventType: "multi_action_executed",
                transcript: command,
                executionResult: combinedResult
            )
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            return
        }

        // == Structured normalization path (replaces old plain-string normalize) ==
        let nc = await commandNormalizer.normalizeStructured(command)

        // Handle safety block from normalizer
        if nc.isBlocked {
            let reason = nc.blockedReason ?? "unknown"
            appendLog("⛔ [Normalizer] Blocked: \(reason)")
            dbManager.saveEvent(
                eventType: "command_blocked",
                transcript: command,
                matched: false,
                metadata: ["reason": reason]
            )
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            return
        }

        // If normalizer produced multiple actions → execute directly via ActionExecutor
        if nc.actions.count > 1 {
            let plan = nc.actions.map { $0.toPlannedAction() }
            appendLog("[Normalizer] Multi-action plan (\(plan.count) steps):")
            plan.enumerated().forEach { i, a in appendLog("  \(i + 1). \(a)") }
            assistantState = .executing
            let result = await executor.execute(.multiAction(plan))
            appendLog("Result: \(result)")
            dbManager.saveEvent(
                eventType: "multi_action_executed",
                transcript: command,
                executionResult: result
            )
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            return
        }

        // Single action — route through legacy CommandParser for backward compatibility
        let normalizedString = nc.toLegacyString()

        // Additional legacy blocklist check
        if let blockedReason = blockedCommandReason(normalizedString) {
            appendLog("Blocked command after normalization: \(blockedReason)")
            dbManager.saveEvent(
                eventType: "command_blocked",
                transcript: command,
                matched: false,
                normalizedCommand: normalizedString,
                metadata: ["reason": blockedReason]
            )
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            return
        }

        let parserInput: String
        if normalizedString.lowercased().hasPrefix("ai: ") {
            parserInput = String(normalizedString.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            parserInput = normalizedString
        }

        currentCommand = parserInput
        appendLog("[Normalizer] \(normalizedString)")

        dbManager.saveEvent(
            eventType: "command_normalized",
            transcript: command,
            normalizedCommand: normalizedString
        )

        let parsed = parser.parse(parserInput)
        assistantState = .executing
        appendLog("Executing command...")

        let result = await executor.execute(parsed)

        appendLog("Result: \(result)")

        // Deliver text + optional voice response
        let speak = voiceResponseEnabled
        switch parsed {
        case .aiQuery:
            // AI query result → show full response + speak if enabled
            ResponseEngine.shared.respond(to: result, speak: speak)
        case .openApp(let n):
            ResponseEngine.shared.respond(to: "Opening \(n)", speak: speak)
        case .closeApp(let n):
            ResponseEngine.shared.respond(to: "Closing \(n)", speak: speak)
        default:
            if !result.isEmpty {
                ResponseEngine.shared.respond(to: result, speak: speak)
            }
        }

        dbManager.saveEvent(
            eventType: "command_executed",
            transcript: command,
            normalizedCommand: normalizedString,
            executionResult: result
        )
        currentCommand = ""
        assistantState = micActive ? .listening : .idle
    }

    /// Returns true when the plan contains exactly one action that falls
    /// into the legacy single-command parser's domain (app open/close/create/ai).
    private func planIsSingleLegacyAction(_ plan: [PlannedAction]) -> Bool {
        guard plan.count == 1 else { return false }
        switch plan[0] {
        case .openApp, .closeApp, .createFile, .createFolder, .aiQuery:
            return true
        default:
            return false
        }
    }

    private func verifyThenRunCommand(_ command: String) async {
        guard voiceProfileReady else {
            voiceVerificationStatus = "Voice Profile Incomplete ⚠️"
            appendLog("[Voice] dropped: profile not ready (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget)) — command '\(command)' rejected.")
            dbManager.saveEvent(
                eventType: "voice_profile_incomplete",
                transcript: command,
                matched: false,
                metadata: [
                    "backend_samples": String(backendEnrollmentSampleCount),
                    "sample_target": String(voiceEnrollmentSampleTarget)
                ]
            )
            return
        }

        do {
            // Single verification attempt only — NO retries.
            // Borderline retry and network retry have been removed per spec requirement.
            let result = try await attemptVerification()

            let wakeWordDetected = containsWakeWord(lastRecognizedSpeech)
            let effectiveThreshold = wakeWordDetected ? 0.65 : voiceVerificationThreshold
            let isVerifiedByThreshold = result.similarity >= effectiveThreshold

            appendLog("[Voice] verify: sim=\(fmtScore(result.similarity)) " +
                      "max=\(fmtScore(result.maxSimilarity)) avg=\(fmtScore(result.avgSimilarity)) " +
                      "conf=\(result.confidence.rawValue) n=\(result.samplesCompared) " +
                      "thr=\(fmtScore(effectiveThreshold)) wake=\(wakeWordDetected ? "yes" : "no") " +
                      "cmd='\(command)'")

            switch result.confidence {
            case .strong:
                voiceVerificationStatus = "Verified (Strong) ✅"
                lastVoiceSimilarity = result.similarity
                appendLog("[Voice] Verified (strong). Score: \(fmtScore(result.similarity)) " +
                          "[max: \(fmtScore(result.maxSimilarity)), avg: \(fmtScore(result.avgSimilarity)), " +
                          "samples: \(result.samplesCompared)]")
                extendSessionTimeout(forCommand: command)
                await runCommand(command)

            case .low:
                if isVerifiedByThreshold {
                    voiceVerificationStatus = "Verified (Low Confidence) ⚠️"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Verified (low confidence). Score: \(fmtScore(result.similarity)) " +
                              "[max: \(fmtScore(result.maxSimilarity)), avg: \(fmtScore(result.avgSimilarity)), threshold: \(fmtScore(effectiveThreshold))]")
                    dbManager.saveEvent(
                        eventType: "voice_low_confidence",
                        transcript: command,
                        score: result.similarity,
                        matched: true,
                        metadata: [
                            "confidence": "low",
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                    extendSessionTimeout(forCommand: command)
                    await runCommand(command)
                } else {
                    voiceVerificationStatus = "Unknown Voice ❌"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Rejected by threshold. Score: \(fmtScore(result.similarity)) < \(fmtScore(effectiveThreshold)) — need ≥ \(fmtScore(effectiveThreshold)) to run; re-enroll in a quiet room if this persists.")
                    if voiceSessionState == .active {
                        appendLog("[VoiceSession] In-session command '\(command)' rejected due to failed verification. Session timer unchanged.")
                    }
                    dbManager.saveEvent(
                        eventType: "voice_rejected",
                        transcript: command,
                        score: result.similarity,
                        matched: false,
                        normalizedCommand: command,
                        metadata: [
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                }

            case .rejected:
                if isVerifiedByThreshold {
                    voiceVerificationStatus = "Verified (Wake Word Relaxed) ⚠️"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Wake-word threshold pass. Score: \(fmtScore(result.similarity)) >= \(fmtScore(effectiveThreshold))")
                    dbManager.saveEvent(
                        eventType: "voice_low_confidence",
                        transcript: command,
                        score: result.similarity,
                        matched: true,
                        metadata: [
                            "confidence": "rejected_override",
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                    extendSessionTimeout(forCommand: command)
                    await runCommand(command)
                } else {
                    voiceVerificationStatus = "Unknown Voice ❌"
                    lastVoiceSimilarity = result.similarity
                    appendLog("[Voice] Rejected. Score: \(fmtScore(result.similarity)) " +
                              "[max: \(fmtScore(result.maxSimilarity)), avg: \(fmtScore(result.avgSimilarity)), threshold: \(fmtScore(effectiveThreshold))] — need ≥ \(fmtScore(effectiveThreshold)) to run.")
                    if voiceSessionState == .active {
                        appendLog("[VoiceSession] In-session command '\(command)' rejected due to failed verification. Session timer unchanged.")
                    }
                    dbManager.saveEvent(
                        eventType: "voice_rejected",
                        transcript: command,
                        score: result.similarity,
                        matched: false,
                        normalizedCommand: command,
                        metadata: [
                            "threshold": fmtScore(effectiveThreshold),
                            "wake_word": wakeWordDetected ? "true" : "false"
                        ]
                    )
                }

            case .none:
                voiceVerificationStatus = "No Voice Profile ❌"
                lastVoiceSimilarity = 0
                appendLog("[Voice] No stored voice profile. Command rejected.")
            }
        } catch let authError {
            // Fix #10: Auth failure — single attempt only.
            // If the backend is unreachable, fall back silently (allow command).
            // Do NOT retry; do NOT re-enqueue.
            let isNetworkError = authError.localizedDescription.lowercased().contains("unavailable")
                || authError.localizedDescription.lowercased().contains("connect")
                || authError.localizedDescription.lowercased().contains("url")

            if isNetworkError {
                appendLog("[Voice] ⚠️ Auth backend unreachable — allowing command with fallback (no retry).")
                voiceVerificationStatus = "Auth Fallback ⚠️"
                dbManager.saveEvent(
                    eventType: "voice_auth_fallback",
                    transcript: command,
                    matched: true,
                    metadata: ["reason": "backend_offline"]
                )
                await runCommand(command)
            } else {
                // Non-network error (e.g. audio capture failure) — hard reject, no retry.
                voiceVerificationStatus = "Unknown Voice ❌"
                appendLog("[Voice] Verification error: \(authError.localizedDescription). Command rejected.")
                dbManager.saveEvent(
                    eventType: "voice_verification_error",
                    transcript: command,
                    matched: false,
                    metadata: ["error": authError.localizedDescription]
                )
            }
        }
    }

    /// Single verification attempt — exports the most recent utterance-length
    /// audio window at 16 kHz and calls backend.
    private func attemptVerification() async throws -> VoiceVerificationResult {
        let sampleURL = try micManager.exportRecentAudioSample(
            durationSeconds: Self.verifyAudioSeconds,
            targetSampleRate: Self.voiceSampleRate
        )
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        return try await voiceAuthClient.verifyDetailed(audioFileURL: sampleURL)
    }

    private func fmtScore(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func enrollMatchedVoiceSample(
        phraseNumber: Int,
        repetition: Int,
        transcript: String
    ) async {
        do {
            let sampleURL = try micManager.exportRecentAudioSample(
                durationSeconds: Self.enrollAudioSeconds,
                targetSampleRate: Self.voiceSampleRate
            )
            defer { try? FileManager.default.removeItem(at: sampleURL) }
            let enrolledCount = try await voiceAuthClient.enroll(audioFileURL: sampleURL)
            backendEnrollmentSampleCount = enrolledCount
            persistBackendSampleCount(enrolledCount)

            appendLog(
                "Voice sample stored for phrase \(phraseNumber) rep \(repetition) " +
                "(backend: \(enrolledCount)/\(voiceEnrollmentSampleTarget))."
            )

            dbManager.saveEvent(
                eventType: "voice_enroll_sample",
                transcript: transcript,
                matched: true,
                phraseIndex: phraseNumber,
                metadata: [
                    "repetition": String(repetition),
                    "backend_count": String(enrolledCount),
                    "sample_target": String(voiceEnrollmentSampleTarget)
                ]
            )

            if enrollmentCompleted && enrolledCount >= voiceEnrollmentSampleTarget {
                voiceVerificationStatus = "Voice Enrolled ✅"
                appendLog("Voice profile finalized (\(enrolledCount)/\(voiceEnrollmentSampleTarget)). Voice mode is ready.")
            } else if enrollmentCompleted {
                voiceVerificationStatus = "Finalizing Voice Profile..."
            }
        } catch {
            appendLog("Voice sample capture failed for phrase \(phraseNumber) rep \(repetition): \(error.localizedDescription)")
            dbManager.saveEvent(
                eventType: "voice_enroll_error",
                transcript: transcript,
                matched: false,
                phraseIndex: phraseNumber,
                metadata: [
                    "repetition": String(repetition),
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func blockedCommandReason(_ command: String) -> String? {
        let lowered = command.lowercased()

        let destructiveRegex = "\\b(delete|remove|rm|trash|erase|wipe)\\b"
        if lowered.range(of: destructiveRegex, options: .regularExpression) != nil {
            return "destructive operations (delete/remove) are disabled"
        }

        let sensitivePathRegex = "\\b(/system|/library|/private|/usr|/bin|/sbin|/etc|/var|root)\\b"
        if lowered.range(of: sensitivePathRegex, options: .regularExpression) != nil {
            return "access to protected system paths is disabled"
        }

        if lowered.contains("system file") || lowered.contains("main system file") {
            return "system file access is disabled"
        }

        return nil
    }

    // MARK: - Quick informational command handler
    @discardableResult
    private func tryHandleQuickInfoCommand(_ command: String) -> Bool {
        // Strip wake word and normalize
        var lower = command.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.hasPrefix("jarvis ") {
            lower = String(lower.dropFirst("jarvis ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Remove trailing punctuation
        lower = lower.trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))

        let now = Date()
        let calendar = Calendar.current
        let formatter = DateFormatter()

        // ── Time patterns ────────────────────────────────────────────
        let timePatterns = [
            "what is the time", "what's the time", "what time is it",
            "tell me the time", "current time", "time right now",
            "what is time", "whats the time", "show me the time",
            "the time", "time please"
        ]
        if timePatterns.contains(where: { lower.contains($0) }) {
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let timeStr = formatter.string(from: now)
            appendLog("[QuickInfo] Detected time query → \(timeStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            popupManager.show(message: timeStr, icon: "clock.fill")
            return true
        }

        // ── Date patterns ────────────────────────────────────────────
        let datePatterns = [
            "what is today's date", "what is the date", "today's date",
            "what day is today", "what is today", "what date is it",
            "tell me the date", "current date", "todays date",
            "what's today's date", "whats todays date", "show me the date",
            "date today", "date right now"
        ]
        if datePatterns.contains(where: { lower.contains($0) }) {
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            let dateStr = formatter.string(from: now)
            appendLog("[QuickInfo] Detected date query → \(dateStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            popupManager.show(message: dateStr, icon: "calendar")
            return true
        }

        // ── Day of week patterns ─────────────────────────────────────
        let dayPatterns = [
            "what day is it", "what day is this", "which day is it",
            "which day is today", "tell me the day", "what day"
        ]
        if dayPatterns.contains(where: { lower.contains($0) }) {
            let dayNames = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"]
            let weekday = calendar.component(.weekday, from: now)
            let dayStr = dayNames[weekday - 1]
            appendLog("[QuickInfo] Detected day query → \(dayStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            popupManager.show(message: dayStr, icon: "calendar")
            return true
        }

        // ── Month patterns ───────────────────────────────────────────
        let monthPatterns = [
            "what month is it", "what month", "which month",
            "tell me the month", "current month"
        ]
        if monthPatterns.contains(where: { lower.contains($0) }) {
            let months = ["January","February","March","April","May","June",
                          "July","August","September","October","November","December"]
            let monthIdx = calendar.component(.month, from: now)
            let monthStr = months[monthIdx - 1]
            appendLog("[QuickInfo] Detected month query → \(monthStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            popupManager.show(message: monthStr, icon: "calendar.badge.clock")
            return true
        }

        // ── Year ─────────────────────────────────────────────────────
        let yearPatterns = ["what year is it", "what year", "current year", "which year"]
        if yearPatterns.contains(where: { lower.contains($0) }) {
            let year = calendar.component(.year, from: now)
            let yearStr = String(year)
            appendLog("[QuickInfo] Detected year query → \(yearStr)")
            currentCommand = ""
            assistantState = micActive ? .listening : .idle
            popupManager.show(message: yearStr, icon: "calendar.badge.clock")
            return true
        }

        return false
    }

    private func handleAudioLevel(_ level: Float) {
        smoothedAudioLevelDB = Self.smooth(
            previous: smoothedAudioLevelDB,
            current: level,
            alpha: smoothingFactor
        )

        audioLevelDB = smoothedAudioLevelDB
        audioLevelNormalized = Self.normalizeDB(smoothedAudioLevelDB)

        let now = Date()

        // Whisper STT processes the utterance only when VAD sees silence.
        // Continuous speech NEVER ends the utterance on its own — the end
        // comes from the 20 s WhisperCommandListener failsafe, and by then
        // the tail is cut, the embedding is garbage, and nothing executes.
        // So: treat a long run of UNBROKEN voice as its own boundary.
        // Mid-speech split (4.0 s voiced): end the current utterance so its
        // transcript routes; the next voiced tick re-opens a fresh one.
        // Short natural pauses still end via the silence rule below.
        // All split/end claims are suppressed while the pill owns the core.
        if previousVoiceDetected, !STTRouter.shared.pillSuppressesCommandVAD {
            let voicedRun = now.timeIntervalSince(recordingStartedAt)
            if voicedRun >= Self.maxContinuousSpeechSeconds {
                previousVoiceDetected = false
                assistantState = .processing
                appendLog("Recording split (continuous speech \(String(format: "%.1f", voicedRun))s) — transcribing segment.")
                WhisperCommandListener.shared.endUtterance()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    if self.assistantState != .executing {
                        self.assistantState = self.micActive ? .listening : .idle
                    }
                }
                return
            }
        }

        let voiceDetected: Bool
        if previousVoiceDetected {
            voiceDetected = smoothedAudioLevelDB > voiceContinueThresholdDB
        } else {
            voiceDetected = smoothedAudioLevelDB > voiceStartThresholdDB
        }

        if voiceDetected {
            lastVoiceTimestamp = now
            if !previousVoiceDetected {
                previousVoiceDetected = true
                recordingStartedAt = now
                assistantState = .recording
                appendLog("Recording started (voice detected).")
                // Start a Whisper utterance on the STT core — unless the
                // dictation pill owns it (⌘⇧D active): then VAD must not
                // steal claims, or the next pill toggle loses the race.
                // Level metering above keeps running regardless.
                if !STTRouter.shared.pillSuppressesCommandVAD {
                    WhisperCommandListener.shared.beginUtterance()
                }
            }
            return
        }

        if previousVoiceDetected {
            let silenceDuration = now.timeIntervalSince(lastVoiceTimestamp)
            let recordingDuration = now.timeIntervalSince(recordingStartedAt)

            if recordingDuration >= minimumRecordingDuration && silenceDuration >= requiredSilenceDuration {
                previousVoiceDetected = false
                assistantState = .processing
                appendLog("Recording ended (silence detected).")
                // Finish the Whisper utterance — its transcript arrives
                // asynchronously via STTRouter → handleTranscript(isFinal:).
                // Suppressed while the pill owns the core (pill stops its
                // own recording via toggleDictation, not via VAD).
                if !STTRouter.shared.pillSuppressesCommandVAD {
                    WhisperCommandListener.shared.endUtterance()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self else { return }
                    if self.assistantState != .executing {
                        self.assistantState = self.micActive ? .listening : .idle
                    }
                }
            }
            return
        }

        if micActive && assistantState != .executing && assistantState != .processing {
            assistantState = .listening
        }
    }

    private func appendLog(_ event: String) {
        let line = logger.log(event: event)
        logs.append(line)
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
    }

    private static func normalizeDB(_ db: Float) -> Double {
        let clamped = max(-80.0, min(0.0, db))
        return Double((clamped + 80.0) / 80.0)
    }

    private static func smooth(previous: Float, current: Float, alpha: Float) -> Float {
        (alpha * current) + ((1 - alpha) * previous)
    }

    private static func normalizedTokens(from text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
    }

    private static func normalizeCompact(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    private func normalizeEnrollmentTranscript(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let lowered = cleaned.lowercased()
        if let range = lowered.range(of: "jarvis", options: .backwards) {
            return String(cleaned[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tokens = Self.normalizedTokens(from: cleaned)
        if tokens.count > 14 {
            return tokens.suffix(14).joined(separator: " ")
        }

        return cleaned
    }

    private func requiredIntentTokens(for phrase: String) -> [String] {
        let stopWords: Set<String> = [
            "jarvis", "the", "a", "an", "to", "please"
        ]
        let tokens = Self.normalizedTokens(from: phrase).filter { !stopWords.contains($0) }

        if tokens.contains("open") && tokens.contains("finder") {
            return ["open", "finder"]
        }

        if tokens.contains("open") && tokens.contains("chrome") {
            return ["open", "chrome"]
        }

        if tokens.contains("close") && tokens.contains("code") {
            return ["close", "code"]
        }

        return Array(Set(tokens))
    }
}