import AppKit
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

    static weak var shared: AppState?

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
    /// Action-pill (⌘⇧A) verification policy. True = voiceprint-check the
    /// transcript like voice mode; false = the keypress IS the intent, run
    /// immediately. UserDefaults-backed so it survives relaunch; toggled
    /// from the in-app Settings (no code change to flip it).
    @Published var actionPillRequiresVerify: Bool = UserDefaults.standard.object(forKey: "jarvis.actionPillRequiresVerify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(actionPillRequiresVerify, forKey: "jarvis.actionPillRequiresVerify") }
    }
    /// Swift → Rust migration flag: command understanding routed through the
    /// Rust core (validator, safety, app aliases, fast-path + rules). OFF keeps
    /// the Swift pipeline and logs shadow-parity lines for comparison.
    @Published var useRustPipeline: Bool = JarvisFlags.useRustPipeline {
        didSet { JarvisFlags.useRustPipeline = useRustPipeline }
    }
    /// Self-protection ceiling in GB (0 = off) — the MemoryGuard watchdog
    /// terminates the app past it. UserDefaults-backed so it survives
    /// relaunch; default scales with physical RAM on first run.
    @Published var memoryLimitGB: Int =
        (UserDefaults.standard.object(forKey: MemoryGuard.limitDefaultsKey) as? Int)
        ?? MemoryGuard.defaultLimitGB(physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory) {
        didSet { UserDefaults.standard.set(memoryLimitGB, forKey: MemoryGuard.limitDefaultsKey) }
    }
    @Published var voiceVerificationStatus = "Unknown Voice ❌"
    @Published var lastVoiceSimilarity = 0.0
    @Published var backendEnrollmentSampleCount = 0
    @Published var automations: [VoiceAutomation] = []
    @Published var backendStatus: String = "Not started"
    @Published var backendStartupError: String?
    // MARK: - Connectors (Spotify)
    /// Presence-only Spotify link state — never holds secrets. Refreshed on
    /// demand from GET /spotify/status.
    @Published var spotifyLinked: Bool = false
    @Published var spotifyExpired: Bool = true
    @Published var spotifyStatusText: String = "Not connected"
    // MARK: - Connectors (PostgreSQL)
    /// True once GET /postgres/status reports a configured backend PG.
    @Published var postgresConfigured: Bool = false
    @Published var postgresStatusText: String = "Not configured"
    @Published var postgresMissingKeys: [String] = []
    /// Local Ollama server reachability (GET /api/tags probe).
    @Published var ollamaReachable: Bool = false
    @Published var ollamaStatusText: String = "qwen2.5 · 1.5b instruct"
    /// Reads the backend's configured values (never the password) for
    /// prefilling the Connections pane form.
    @Published var postgresForm = PostgresForm()
    /// Event-logging switch (UserDefaults-backed) — gates all PG writes.
    @Published var eventLoggingEnabled: Bool = UserDefaults.standard.object(forKey: "jarvis.eventLogging.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(eventLoggingEnabled, forKey: "jarvis.eventLogging.enabled")
            dbManager.loggingEnabled = eventLoggingEnabled
        }
    }
    /// Recent commands ring (last 5) for the Assistant pane.
    @Published var recentCommands: [String] = []
    /// When true, Jarvis speaks its responses aloud via AVSpeechSynthesizer.
    @Published var voiceResponseEnabled: Bool = false
    /// Current display brightness level (0-100) for UI display and controls.
    @Published var currentBrightness: Int = 50
    /// Current display contrast level (0-100, external monitors via DDC/CI).
    @Published var currentContrast: Int = 50

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

    private let micManager: AudioCapturing
    private let logger: Logger
    let dbManager: DBManager
    private var actionExecutor: PlanExecuting = ActionExecutor()
    private let automationStore = AutomationStore()
    private let voiceAuthClient: SpeakerVerifying = VoiceAuthClient()
    let spotifyClient = SpotifyClient()
    let postgresClient = PostgresClient()
    private let actionPlanner = ActionPlanner()
    private let backendServiceManager = BackendServiceManager()
    private let displayController = DisplayController()
    let commandQueue = CommandQueueManager()

    private var previousVoiceDetected = false
    private var lastVoiceTimestamp = Date.distantPast
    private var smoothedAudioLevelDB: Float = -160.0
    /// False until the first real level arrives after a mic (re)start — the
    /// seed replaces the -160 dB cold start that delayed VAD onset ~250 ms.
    private var smoothedAudioLevelSeeded = false
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
    private let requiredSilenceDuration: TimeInterval = 1.2
    private let smoothingFactor: Float = 0.35
    /// Longest unbroken voiced run before the utterance is force-segmented
    /// (see handleAudioLevel). Sits just past Rust chunk_seconds=6 so each
    /// segment carries a live partial before the split fires.
    private static let maxContinuousSpeechSeconds: TimeInterval = 8.0
    private let enrollmentAcceptCooldown: TimeInterval = 1.4
    private let enrollmentAttemptThrottle: TimeInterval = 0.30
    private let voiceVerificationThreshold = 0.70
    /// How long after hearing "Jarvis" a follow-up without the wake word is
    /// still accepted as its command ("Jarvis" … pause … "open Spotify").
    private static let pendingWakeWordGraceSeconds: TimeInterval = 4.0
    private static let verifyAudioSeconds = 3.5
    private static let enrollAudioSeconds = 3.5
    /// Minimum RMS of the verify clip — below this the buffer is silence and
    /// the backend would 400 (or Resemblyzer would embed noise). Skip the
    /// POST and reject locally instead.
    private static let verifyMinClipRMS: Float = 0.005
    // Hallucinated-singleton filtering lives in TranscriptSanitizer
    // (single table shared with the batch path).
    /// Resemblyzer embeds via preprocess_wav at 16 kHz. Exporting at the
    /// same rate removes a resample-variance source between enroll-time
    /// and verify-time embeddings and keeps clips comparable sample-for-sample.
    private static let voiceSampleRate = 16_000.0

    /// Read-only surfaces for the Assistant pane (threshold display, profile row).
    var voiceVerifyThreshold: Double { voiceVerificationThreshold }
    var displayProfileName: String { displayController.profileName }

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
        micManager: AudioCapturing = MicManager.shared,
        logger: Logger = Logger(),
        dbManager: DBManager = DBManager()
    ) {
        self.micManager = micManager
        self.logger = logger
        self.dbManager = dbManager
        AppState.shared = self
        commandQueue.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        actionExecutor.onLog = { [weak self] msg in
            Task { @MainActor in self?.appendLog(msg) }
        }
        displayController.onLog = { [weak self] msg in
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
        // Action pill (⌘⇧A): the press is the intent — no wake word, no
        // voice-mode gate. Runs through the SAME verify/execute path as
        // typed commands (verify per the user setting above).
        STTRouter.shared.onActionTranscript = { [weak self] text in
            Task { @MainActor in
                self?.handleActionPillCommand(text)
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
        dbManager.loggingEnabled = eventLoggingEnabled
        refreshBrightness()
        refreshContrast()
        // Usage stats: Postgres primary, local JSON buffer when PG is off.
        // Recorder always buffers; flush upserts deltas keyed by day.
        StatsRecorder.shared.onFlush = { [weak self] snapshot in
            guard let self else { return }
            guard self.dbManager.isConfigured else { return }
            let pending = StatsRecorder.shared.bufferedDays()
            for bucket in pending {
                self.dbManager.upsertDailyStats(bucket)
            }
            if !pending.isEmpty {
                StatsRecorder.shared.markBackfilled(days: pending.map { $0.day })
            }
            _ = snapshot
        }

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

    // MARK: - Display Contrast UI Controls

    func refreshContrast() {
        if let val = displayController.getCurrentContrast() {
            currentContrast = val
        }
    }

    func increaseContrastUI() {
        let msg = displayController.execute(.increaseContrast(by: 10))
        appendLog("[UI] \(msg)")
        refreshContrast()
    }

    func decreaseContrastUI() {
        let msg = displayController.execute(.decreaseContrast(by: 10))
        appendLog("[UI] \(msg)")
        refreshContrast()
    }

    func setContrastUI(_ percent: Int) {
        let msg = displayController.execute(.setContrast(percent))
        appendLog("[UI] \(msg)")
        refreshContrast()
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
        smoothedAudioLevelSeeded     = false
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
        await refreshPostgresStatus()
        await refreshOllamaStatus()

        restoreEnrollmentStateFast()
        await reconcileEnrollmentFromDB()
        await syncVoiceProfileStatusFromBackend()
        // Listening is MANUAL by design: the mic stays cold until the user
        // taps the orb or presses a hotkey. Wake word, VAD and dictation all
        // come up from the same startMicrophone() — nothing to arm here.
        appendLog("Ready. Tap the orb (or press ⌘⇧D / ⌘⇧A) to start listening.")
    }

    func shutdown() {
        StatsRecorder.shared.flush()
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
            await refreshSpotifyStatus()
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
                onAudioBuffer: { buffer in
                    // Acoustic wake-word engine (inert without SDK + key):
                    // tap-thread ingest, internally locked.
                    WakeWordDetector.shared.ingest(buffer: buffer)
                }
            )

            // Detection anchors the pre-roll window and arms the command —
            // the follow-up utterance is then accepted even if "Jarvis"
            // never survives transcription (Phase 3.3).
            WakeWordDetector.shared.onDetection = { [weak self] in
                self?.handleAcousticWakeWord()
            }

            micActive = true
            assistantState = .listening
            appendLog("Microphone + Whisper recognizer started.")
            // Surface the auto-paste grant in the app's own log: a stale
            // grant (toggle ON, binary replaced by a rebuild) reads as
            // "paste does nothing" with no other clue.
            appendLog(has_accessibility_permission()
                ? "[AX] Auto-paste permission: granted."
                : "[AX] Auto-paste permission: MISSING — dictation will copy instead. Remove + re-add Jarvis in Privacy & Security → Accessibility.")
        } catch {
            micActive = false
            assistantState = .idle
            appendLog("Microphone start failed: \(error.localizedDescription)")
        }
    }

    func stopMicrophone() {
        isStoppingMicrophone = true
        micTransientAutoStart = false
        pendingWakeWordDetected = false
        WhisperCommandListener.shared.reset()
        micManager.stopListening()
        micActive = false
        assistantState = .idle
        appendLog("Microphone stopped.")
    }

    // MARK: - Transient mic (one-shot hotkey pills)

    /// True when the mic was brought up ONLY so a ⌘⇧D/⌘⇧A press could record
    /// — no manual listening was on. When that pill finishes, the pipeline
    /// goes back down, so a hotkey never leaves the app live-listening.
    private var micTransientAutoStart = false

    /// True when the USER has listening on — not when a one-shot hotkey pill
    /// (⌘⇧D / ⌘⇧A) borrowed the mic for its recording. The main-window orb
    /// and stage text key off this, so a pill never lights up the live UI.
    var isLiveListening: Bool { micActive && !micTransientAutoStart }

    /// Called by the hotkey path right before it starts the mic for a pill.
    func markTransientMicStart() {
        micTransientAutoStart = true
    }

    /// The user started listening on purpose (orb tap / panel button): the
    /// transient rule no longer applies — the mic stays up. The same goes for
    /// an enrollment auto-start: the user owns the mic now.
    func noteManualMicStart() {
        micTransientAutoStart = false
        micStartedForEnrollment = false
    }

    /// Called when a pill session ends. Stops the mic only when THIS session
    /// was its reason to exist (see `markTransientMicStart`).
    func restoreMicAfterTransientStartIfNeeded() {
        guard micTransientAutoStart else { return }
        micTransientAutoStart = false
        guard micActive else { return }
        appendLog("One-shot use finished — mic back to idle (listening stays manual).")
        stopMicrophone()
    }

    func startEnrollment(resetStore: Bool = true) {
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

        // Enrollment captures from the live mic pipeline, so it must not
        // depend on the user already having a listening session running
        // (the old flow greyed the button out until ⌘⇧D had brought the mic
        // up). Bring the mic up here when idle; `releaseEnrollmentMicIfNeeded`
        // returns it to idle when enrollment ends — listening stays manual.
        if micActive {
            // A one-shot pill may hold a transient mic right when Enroll is
            // pressed; adopt it so the pill's teardown can't stop capture
            // under the live enrollment.
            if micTransientAutoStart {
                micTransientAutoStart = false
                micStartedForEnrollment = true
            }
        } else {
            micStartedForEnrollment = true
            appendLog("Microphone started for enrollment.")
            Task {
                await startMicrophone()
                if !micActive {
                    appendLog("[Voice] Enrollment can't capture — microphone failed to start.")
                }
            }
        }

        guard resetStore else {
            appendLog("Enrolling from a clean slate (0/\(voiceEnrollmentSampleTarget)) — only these new samples will be used.")
            return
        }

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

    /// Wipe every previously stored voice sample, then start a fresh enrollment
    /// so verification uses ONLY the new recordings. Aborts (without touching
    /// the old samples) if the backend wipe fails.
    func retrainVoiceProfile() {
        guard !enrollmentActive else { return }
        Task {
            do {
                try await voiceAuthClient.reset()
                await MainActor.run {
                    backendEnrollmentSampleCount = 0
                    persistBackendSampleCount(0)
                    voiceVerificationStatus = "No Voice Profile ❌"
                    appendLog("Voice profile wiped — all \(voiceEnrollmentSampleTarget)-sample history deleted. Starting fresh enrollment.")
                    startEnrollment(resetStore: false)
                }
            } catch {
                await MainActor.run {
                    appendLog("[Voice] Retrain aborted — could not wipe old samples: \(error.localizedDescription)")
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
        releaseEnrollmentMicIfNeeded()
        appendLog("Voice enrollment stopped.")
    }

    /// True when enrollment started the mic itself (Enroll/Retrain pressed
    /// with listening idle). Like the hotkey pills, the mic goes back down
    /// when enrollment ends — a user-started session is never touched.
    private var micStartedForEnrollment = false

    /// Returns the mic to idle when enrollment was its only reason to exist.
    private func releaseEnrollmentMicIfNeeded() {
        guard micStartedForEnrollment else { return }
        micStartedForEnrollment = false
        guard micActive else { return }
        appendLog("Enrollment finished — mic back to idle (listening stays manual).")
        stopMicrophone()
    }

    /// Action-pill (⌘⇧A) command entry. Same shape as executeTypedCommand:
    /// validate → classify → enqueue. No wake word (the keypress is the
    /// intent). Verification is per `actionPillRequiresVerify`, changeable
    /// in Settings without touching code.
    func handleActionPillCommand(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog("[Action] dropped: empty transcript.")
            return
        }
        guard let command = CommandValidator.validate(trimmed) else {
            appendLog("[Action] Invalid command skipped: '\(trimmed)'")
            return
        }
        appendLog("[Action] Received: '\(command)' (verify: \(actionPillRequiresVerify ? "on" : "off"))")
        let priority = CommandPriority.classify(command)
        if actionPillRequiresVerify {
            commandQueue.enqueue(text: command, priority: priority) { [weak self] in
                await self?.verifyThenRunCommand(command)
            }
        } else {
            commandQueue.enqueue(text: command, priority: priority) { [weak self] in
                await self?.runCommand(command)
            }
        }
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

    // MARK: - Connectors (Spotify status)

    /// Presence-only refresh: linked = keys saved + a usable token.
    func refreshSpotifyStatus() async {
        do {
            let st = try await spotifyClient.status()
            spotifyExpired = st.expired
            spotifyLinked = st.clientPresent && st.accessPresent && !st.expired
            spotifyStatusText = !st.clientPresent ? "Keys missing"
                : st.expired ? "Token expired — reconnect"
                : "Connected"
            appendLog("[Spotify] Status: \(spotifyStatusText)")
        } catch {
            spotifyLinked = false
            spotifyStatusText = "Backend unreachable"
            appendLog("[Spotify] Status check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connectors (PostgreSQL)

    /// Refresh from GET /postgres/status; prefills the Connections form
    /// (host/port/db/user — never the password) for editing.
    func refreshPostgresStatus() async {
        do {
            let st = try await postgresClient.status()
            postgresConfigured = st.configured
            postgresMissingKeys = st.missing
            postgresStatusText = st.configured ? "Configured"
                : st.missing.isEmpty ? "Not configured"
                : "Missing: \(st.missing.joined(separator: ", "))"
            if postgresConfigured {
                postgresForm = PostgresForm(
                    host: st.host, port: st.port,
                    database: st.database, user: st.user,
                    password: ""
                )
            }
            dbManager.reloadConfiguration()
            appendLog("[Postgres] Status: \(postgresStatusText)")
        } catch {
            postgresConfigured = false
            postgresStatusText = "Backend unreachable"
            appendLog("[Postgres] Status check failed: \(error.localizedDescription)")
        }
    }

    func savePostgresCredentials() async -> String {
        do {
            let msg = try await postgresClient.save(
                host: postgresForm.host, port: postgresForm.port,
                database: postgresForm.database, user: postgresForm.user,
                password: postgresForm.password
            )
            postgresForm.password = ""
            dbManager.reloadConfiguration()
            await refreshPostgresStatus()
            return msg
        } catch {
            return error.localizedDescription
        }
    }

    func testPostgresConnection() async -> String {
        do {
            return try await postgresClient.test()
        } catch {
            return error.localizedDescription
        }
    }

    /// Probe GET /api/tags (2 s timeout) — drives the Ollama chip.
    func refreshOllamaStatus() async {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            ollamaReachable = ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
        } catch {
            ollamaReachable = false
        }
        ollamaStatusText = ollamaReachable ? "qwen2.5 · 1.5b instruct" : "Offline — commands still work"
    }

    /// Keeps the last 5 executed commands for the Assistant pane's Recent card.
    private func trackRecentCommand(_ command: String) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        if recentCommands.count > 5 {
            recentCommands = Array(recentCommands.prefix(5))
        }
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

        if voiceModeEnabled && TranscriptSanitizer.containsWakeWord(transcript) {
            pendingWakeWordDetected = true
            pendingWakeWordDetectedAt = Date()
        }

        // ── TTS echo suppression ─────────────────────────────────────
        if !lastSpokenResponseText.isEmpty {
            let compactTranscript = TranscriptSanitizer.normalizeCompact(transcript)
            let compactSpoken    = TranscriptSanitizer.normalizeCompact(lastSpokenResponseText)
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

        // Voice-mode app shortcut mishear guard: Whisper often returns a bare
        // app name ("Spotify") when the user said "open Spotify". The typed
        // box works because CommandValidator never sees the truncation, but
        // voice drops single nouns as non-commands. Repair the obvious case:
        // a bare known-app noun in voice mode becomes "open <app>".
        let repairedTranscript: String = {
            let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let apps: Set<String> = ["spotify", "chrome", "whatsapp"]
            if apps.contains(t) { return "open \(t)" }
            return transcript
        }()
        let transcriptForCommand = repairedTranscript

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
        // NOTE: everything below uses transcriptForCommand (the repaired
        // text), not the raw transcript: a bare "Spotify" mishear was
        // already repaired to "open spotify" above.
        let hasWakeWord = TranscriptSanitizer.containsWakeWord(transcriptForCommand)
        var rawSegments: [String] = []

        // ── Whisper hallucination filter ──────────────────────────
        // "Thank you." on silence is the classic whisper hallucination —
        // never a command. Drop singleton fillers without a wake word BEFORE
        // verify/enqueue so they can't hit /verify (400), Ollama, or the
        // queue.
        if !hasWakeWord, TranscriptSanitizer.isHallucinatedSingleton(transcriptForCommand) {
            appendLog("[Voice] dropped: hallucination filter ('\(transcriptForCommand)' without wake word).")
            return
        }

        if hasWakeWord {
            rawSegments = transcriptForCommand
                .replacingOccurrences(of: "(?i)\\bjarvis\\b", with: "|",
                                       options: [.regularExpression, .caseInsensitive])
                .split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            appendLog("[Voice] segments count: \(rawSegments.count) (from wake-word split)")
            NSLog("[Voice] split into %d raw segments", rawSegments.count)

            if rawSegments.isEmpty {
                // "Jarvis." alone: the user is addressing us and paused before
                // the command. Hold the wake state and ARM the session so the
                // follow-up utterance is accepted WITHOUT a second "Jarvis".
                // The old code cleared the flag at the end of this same call
                // and dropped the transcript — exactly why wake + pause failed.
                extendSessionTimeout(forCommand: "wake word only")
                appendLog("[Voice] wake word alone — session armed, listening for the follow-up command.")
                return
            }
            // Consumed by this transcript's command segments.
            pendingWakeWordDetected = false
        } else if isSessionValid {
            rawSegments = [transcriptForCommand]
            pendingWakeWordDetected = false
            appendLog("[VoiceSession] Processing in-session follow-up command: '\(transcriptForCommand)'")
        } else if pendingWakeWordDetected,
                  now.timeIntervalSince(pendingWakeWordDetectedAt) <= Self.pendingWakeWordGraceSeconds {
            // Wake word was heard within the grace window but the session
            // arming did not land (session reset races). Accept this as the
            // follow-up command rather than dropping it.
            rawSegments = [transcriptForCommand]
            pendingWakeWordDetected = false
            appendLog("[Voice] segments count: 1 (pending wake-word fallback)")
        } else {
            pendingWakeWordDetected = false
        }

        guard !rawSegments.isEmpty else {
            appendLog("[Voice] no segments — wake word not found, dropping transcript.")
            return
        }

        // ── Clean each segment ────────────────────────────────────────
        var cleanedCommands: [String] = []
        for segment in rawSegments {
            guard let cmd = TranscriptSanitizer.cleanVoiceSegment(segment, onLog: { [weak self] in self?.appendLog($0) }) else { continue }
            cleanedCommands.append(cmd)
        }

        guard !cleanedCommands.isEmpty else {
            appendLog("[Voice] dropped: no valid command after cleaning \(rawSegments.count) segment(s) — transcript '\(transcriptForCommand)' ignored.")
            return
        }

        // ── Sanitize batch: dedup + conflict resolution + cap ─────────
        let sanitized = TranscriptSanitizer.sanitizeBatch(cleanedCommands, maxBatchSize: Self.maxBatchSize, onLog: { [weak self] in self?.appendLog($0) })
        appendLog("[Voice] final commands: \(sanitized.map { "'\($0)'" }.joined(separator: ", "))")

        for cmd in sanitized {
            appendLog("[Voice] cleaned: '\(cmd)'")
        }

        lastBatchHandledTranscript = TranscriptSanitizer.normalizeCompact(transcriptForCommand)

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
        let recognizedTokenSet = Set(TranscriptSanitizer.normalizedTokens(from: cleanedTranscript))
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

            let currentNormalized = TranscriptSanitizer.normalizeCompact(cleanedTranscript)
            let previousNormalized = TranscriptSanitizer.normalizeCompact(lastEnrollmentAcceptedTranscript)
            if !previousNormalized.isEmpty {
                let duplicateDistance = StringDistance.levenshtein(currentNormalized, previousNormalized)
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

                releaseEnrollmentMicIfNeeded()

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

    /// Boot fast-path: UserDefaults only, never touches the DB (sync psql
    /// from @MainActor deadlocked boot in __DISPATCH_WAIT_FOR_QUEUE__).
    /// The DB reconcile runs async right after (see reconcileEnrollmentFromDB).
    private func restoreEnrollmentStateFast() {
        let defaultsFlag = UserDefaults.standard.bool(forKey: Self.enrollmentCompletedDefaultsKey)
        let savedBackendCount = UserDefaults.standard.integer(forKey: Self.backendSampleCountDefaultsKey)

        backendEnrollmentSampleCount = savedBackendCount

        if defaultsFlag {
            enrollmentCompleted = true
            enrollmentActive = false
            appendLog("Enrollment restored from saved state.")
            if savedBackendCount >= voiceEnrollmentSampleTarget {
                voiceVerificationStatus = "Voice Enrolled ✅"
            } else if savedBackendCount > 0 {
                voiceVerificationStatus = "Finalizing Voice Profile..."
            }
        }
    }

    /// Background reconcile: if the DB has an enrollment_completed event we
    /// never persisted locally (fresh profile, wiped defaults), adopt it.
    private func reconcileEnrollmentFromDB() async {
        guard !enrollmentCompleted else { return }
        guard dbManager.isConfigured else { return }
        if await dbManager.hasEnrollmentCompletionEvent() {
            enrollmentCompleted = true
            enrollmentActive = false
            persistEnrollmentCompleted(true)
            appendLog("Enrollment restored from saved state.")
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
        let targetTokens = Set(TranscriptSanitizer.normalizedTokens(from: target))
        let recognizedTokens = Set(TranscriptSanitizer.normalizedTokens(from: recognized))
        guard !targetTokens.isEmpty else { return 0 }

        let tokenIntersection = targetTokens.intersection(recognizedTokens).count
        let tokenScore = Double(tokenIntersection) / Double(targetTokens.count)

        let targetNormalized = target.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
        let recognizedNormalized = recognized.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)

        let maxLen = max(targetNormalized.count, recognizedNormalized.count)
        guard maxLen > 0 else { return tokenScore }

        let distance = StringDistance.levenshtein(targetNormalized, recognizedNormalized)
        let charScore = 1.0 - (Double(distance) / Double(maxLen))

        return (0.6 * tokenScore) + (0.4 * max(0.0, charScore))
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

    private func matchedAutomation(for command: String) -> (automation: VoiceAutomation, isOffVariant: Bool)? {
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
            } else {
                // Never skip silently: an action whose value is empty used to
                // vanish here with no trace, which read as "the routine ran
                // but the second step never happened".
                appendLog("[Automation][ERROR] Skipped \(action.type.rawValue) — no value configured")
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

    /// Watchdog window for one command: beyond this, the pipeline is
    /// declared wedged and the visible state is released. Longer than the
    /// Ollama call timeout (60 s) so a legitimately slow answer never trips
    /// it. Internal so tests can shorten it.
    static var commandWatchdogSeconds: TimeInterval = 90

    /// A command may await something that never returns (a blocked child
    /// process was the real case — see Process.waitUntilExit(timeout:)).
    /// Whatever the cause, the UI must not sit on "Working" forever: this
    /// wrapper releases assistantState/currentCommand if the body overruns.
    private func runCommand(_ command: String) async {
        let token = UUID()
        activeCommandRunToken = token
        let seconds = Self.commandWatchdogSeconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.activeCommandRunToken == token else { return }
            self.activeCommandRunToken = nil
            self.appendLog("⚠️ Command watchdog: '\(command)' still running after \(Int(seconds)) s — releasing the state (the action may be waiting on a system dialog).")
            self.currentCommand = ""
            if self.assistantState == .executing || self.assistantState == .processing {
                self.assistantState = self.micActive ? .listening : .idle
            }
        }
        await runCommandBody(command)
        activeCommandRunToken = nil
    }

    private var activeCommandRunToken: UUID?

    private func runCommandBody(_ command: String) async {
        guard !command.isEmpty else { return }
        trackRecentCommand(command)
        var succeeded = false
        // One id for this whole utterance — ties the model_hit/model_miss,
        // plan branch and execute events together in intent_router.jsonl.
        let intentRequestID = UUID()
        defer {
            StatsRecorder.shared.recordCommand(success: succeeded)
            // Final outcome line for every utterance (RL corpus): input, and
            // whether the chosen pipeline actually executed it.
            IntentRouterLog.shared.append([
                "event": "execute_command",
                "request_id": intentRequestID.uuidString,
                "text": command,
                "success": succeeded,
            ])
        }

        if let match = matchedAutomation(for: command) {
            appendLog("[Automation] Triggered keyword: '\(match.automation.keyword)'")
            await executeAutomation(match.automation, isOffVariant: match.isOffVariant)
            succeeded = true
            return
        }

        // --- Quick informational commands (time / date / month / day) ---
        if tryHandleQuickInfoCommand(command) { return }
        // ---

        // --- SafetyGuard: single pre-pipeline gate (sudo / destructive /
        // install-preview / protected paths). Previously two overlapping
        // blocklists ran here; SafetyGuard is now the only one.
        switch SafetyGuard.validate(rawCommand: command) {
        case .blocked(let reason):
            appendLog("⛔ Safety blocked: \(reason)")
            dbManager.saveEvent(
                eventType: "safety_blocked",
                transcript: command,
                matched: false,
                metadata: ["reason": reason]
            )
            StatsRecorder.shared.recordCommand(success: false)
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
            StatsRecorder.shared.recordCommand(success: false)
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

        // One id ties the model_hit/model_miss, plan branch and execute
        // events together in intent_router.jsonl (RL corpus).
        let plan = await actionPlanner.plan(from: command, requestID: intentRequestID)

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

        // == Unified execution: every plan (single or multi-step) runs
        // through ActionExecutor. The old single-legacy fork re-parsed the
        // already-planned action through CommandNormalizer + CommandParser
        // (including a redundant potential Ollama call) — removed.
        do {
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
                        IntentRouterLog.shared.append([
                            "event": "execute_step",
                            "request_id": intentRequestID.uuidString,
                            "text": command,
                            "action": result.action.description,
                            "success": result.success,
                            "message": result.message,
                        ])
                        ResponseEngine.shared.respond(
                            action: result.action,
                            result: result,
                            speak: speakResponses
                        )
                        // Single-step informational answers (time/date via
                        // planner, brightness/contrast reads, volume reads)
                        // also surface in the floating panel so background
                        // ⌘⇧A isn't log-only.
                        if plan.count == 1, result.success, case .systemInfo = result.action {
                            self.showFloatingResult(result.message, icon: "info.circle.fill")
                        }
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
            succeeded = true
        }

    }

    private func verifyThenRunCommand(_ command: String) async {
        guard voiceProfileReady else {
            voiceVerificationStatus = "Voice Profile Incomplete ⚠️"
            appendLog("[Voice] dropped: profile not ready (\(backendEnrollmentSampleCount)/\(voiceEnrollmentSampleTarget)) — command '\(command)' rejected.")
            StatsRecorder.shared.recordCommand(success: false)
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

            let wakeWordDetected = TranscriptSanitizer.containsWakeWord(lastRecognizedSpeech)
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
                    StatsRecorder.shared.recordCommand(success: false)
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
                    StatsRecorder.shared.recordCommand(success: false)
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
            // Network-down fallback allows the command ONLY when it carries
            // a wake word or arrives in an active session — a hallucinated
            // singleton ("Thank you.") with no wake word must never execute
            // just because the backend is offline. Do NOT retry; do NOT
            // re-enqueue.
            let isNetworkError = authError.localizedDescription.lowercased().contains("unavailable")
                || authError.localizedDescription.lowercased().contains("connect")
                || authError.localizedDescription.lowercased().contains("url")

            if isNetworkError {
                let hasWake = TranscriptSanitizer.containsWakeWord(lastRecognizedSpeech)
                    || voiceSessionState == .active
                guard hasWake else {
                    voiceVerificationStatus = "Unknown Voice ❌"
                    appendLog("[Voice] dropped: auth fallback refused — no wake word in '\(command)' (backend offline).")
                    StatsRecorder.shared.recordCommand(success: false)
                    dbManager.saveEvent(
                        eventType: "voice_auth_fallback_refused",
                        transcript: command,
                        matched: false,
                        metadata: ["reason": "backend_offline_no_wake"]
                    )
                    return
                }
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
                StatsRecorder.shared.recordCommand(success: false)
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
    /// audio window at 16 kHz and calls backend. Silence clips (RMS below
    /// verifyMinClipRMS) are rejected locally: the backend would 400 them
    /// and Resemblyzer would embed noise, so never POST them.
    private func attemptVerification() async throws -> VoiceVerificationResult {
        let sampleURL = try micManager.exportRecentAudioSample(
            durationSeconds: Self.verifyAudioSeconds,
            targetSampleRate: Self.voiceSampleRate
        )
        defer { try? FileManager.default.removeItem(at: sampleURL) }
        let rms = Self.clipRMS(ofWavAt: sampleURL)
        guard rms >= Self.verifyMinClipRMS else {
            appendLog("[Voice] dropped: verify clip is silence (rms \(String(format: "%.4f", rms))) — backend skipped.")
            throw MicManagerError.insufficientAudio
        }
        return try await voiceAuthClient.verifyDetailed(audioFileURL: sampleURL)
    }

    /// RMS of a WAV file's samples (float32 mono written by MicManager).
    /// Returns 0 when the file can't be read — treated as silence upstream.
    private static func clipRMS(ofWavAt url: URL) -> Float {
        guard let data = try? Data(contentsOf: url), data.count > 44 else { return 0 }
        let samples = data.dropFirst(44)
        let count = samples.count / MemoryLayout<Float>.size
        guard count > 0 else { return 0 }
        var squareSum: Float = 0
        samples.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            for i in 0..<count { squareSum += ptr[i] * ptr[i] }
        }
        return sqrt(squareSum / Float(count))
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

    /// Floating result panel: shows a short answer (time, date, brightness)
    /// in a global NSPanel above ALL apps — the in-window PopupView only
    /// renders when Jarvis is frontmost, so background ⌘⇧A answers were
    /// invisible. Auto-dismisses after 3 s. Callers also mirror into
    /// ResponseEngine so the main window shows it when frontmost.
    private func showFloatingResult(_ text: String, icon: String) {
        FloatPanel.show(text: text, icon: icon)
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

    /// Acoustic wake word heard (only fires when a real engine is enabled —
    /// see WakeWordDetector). Anchors the pending-wake state so the command
    /// about to be spoken is accepted even if the transcript never contains
    /// "Jarvis", and confirms audibly so the user knows the mic is hot.
    private func handleAcousticWakeWord() {
        guard micActive, voiceModeEnabled, !isStoppingMicrophone, !isTTSSpeaking else { return }
        pendingWakeWordDetected = true
        pendingWakeWordDetectedAt = Date()
        appendLog("[Wake] Acoustic wake word detected — pre-roll anchored.")
        // Tink is the system's subtle cue; NSSound plays nothing when the
        // user's sound is off — that is their setting, not a failure.
        NSSound(named: "Tink")?.play()
    }

    private func handleAudioLevel(_ level: Float) {
        // A pill owns this audio (⌘⇧D / ⌘⇧A recording): its own HUD and its
        // own meter are the UI for it. Driving the main window from the same
        // audio lit up the orb as "Recording"/"Processing" during every
        // action command — the main stage must stay untouched until the
        // pipeline is genuinely idle again.
        if STTRouter.shared.pillSuppressesCommandVAD { return }

        if smoothedAudioLevelSeeded {
            smoothedAudioLevelDB = Self.smooth(
                previous: smoothedAudioLevelDB,
                current: level,
                alpha: smoothingFactor
            )
        } else {
            // Seed with the first observed level instead of smoothing up from
            // -160 dB: crossing the -42 dB start threshold took ~5 callbacks
            // (~250 ms) of ramp, which is the main reason VAD onset was late
            // and the pre-roll had to exist at all.
            smoothedAudioLevelDB = level
            smoothedAudioLevelSeeded = true
        }

        // Publish dedupe: at ~60 Hz the raw values keep changing in
        // sub-perceptual steps (the smoother converges asymptotically during
        // silence), and every @Published write re-evaluates every view that
        // observes AppState — a whole-UI redraw per audio tick. 0.5% / 0.5 dB
        // steps are visually identical and let quiet audio stop the churn.
        let normalized = Self.normalizeDB(smoothedAudioLevelDB)
        let quantizedNormalized = (normalized * 200).rounded() / 200
        if quantizedNormalized != audioLevelNormalized {
            audioLevelNormalized = quantizedNormalized
        }
        let quantizedDB = (smoothedAudioLevelDB * 2).rounded() / 2
        if quantizedDB != audioLevelDB {
            audioLevelDB = quantizedDB
        }

        let now = Date()

        // Whisper STT processes the utterance only when VAD sees silence.
        // Continuous speech NEVER ends the utterance on its own — the end
        // comes from the 30 s WhisperCommandListener failsafe, and by then
        // the tail is cut, the embedding is garbage, and nothing executes.
        // So: treat a long run of UNBROKEN voice as its own boundary.
        // Mid-speech split (8.0 s voiced): end the current utterance so its
        // transcript routes; the next voiced tick re-opens a fresh one.
        // Short natural pauses still end via the silence rule below.
        // All split/end claims are suppressed while the pill owns the core.
        if previousVoiceDetected, !STTRouter.shared.pillSuppressesCommandVAD {
            let voicedRun = now.timeIntervalSince(recordingStartedAt)
            if voicedRun >= Self.maxContinuousSpeechSeconds {
                previousVoiceDetected = false
                recordingStartedAt = now
                lastVoiceTimestamp = now
                assistantState = .processing
                appendLog("Recording split (continuous speech \(String(format: "%.1f", voicedRun))s) — transcribing segment; tail re-arms.")
                WhisperCommandListener.shared.endUtterance()
                // Re-arm NOW instead of waiting for a fresh rising edge: the
                // user is still mid-sentence. The core is busy inferring the
                // segment just ended, so this claim usually loses and the
                // per-tick retry below opens the follow-up recording the
                // moment it frees — pre-roll covering the inference gap.
                WhisperCommandListener.shared.beginUtterance()
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
                // Start a Whisper utterance on the STT core — unless a
                // push-to-talk pill owns it (⌘⇧D / ⌘⇧A active): then VAD
                // must not steal claims, or the next pill toggle loses
                // the race. Level metering above keeps running regardless.
                if !STTRouter.shared.pillSuppressesCommandVAD {
                    WhisperCommandListener.shared.beginUtterance()
                }
            } else if !STTRouter.shared.pillSuppressesCommandVAD,
                      !WhisperCommandListener.shared.isUtteranceActive {
                // Core-busy retry: the rising edge tried to claim the core
                // while it was busy (previous final inferring, model
                // reloading) and the whole voiced run would otherwise be lost
                // with no retry — the "phantom recording" (Swift shows
                // Recording, Rust captured nothing). One cheap attempt per
                // VAD tick; once the core frees, this lands and the pre-roll
                // covers the gap since speech actually started.
                WhisperCommandListener.shared.beginUtterance()
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
                // Suppressed while a pill owns the core (pills stop their
                // own recordings via toggle, not via VAD).
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

        // Only when the state actually needs to change: @Published emits on
        // every assignment, equal or not, so re-setting .listening each tick
        // would re-render every observer at audio rate while idle-listening.
        if micActive && assistantState != .executing && assistantState != .processing && assistantState != .listening {
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

    private func normalizeEnrollmentTranscript(_ text: String) -> String {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let lowered = cleaned.lowercased()
        if let range = lowered.range(of: "jarvis", options: .backwards) {
            return String(cleaned[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let tokens = TranscriptSanitizer.normalizedTokens(from: cleaned)
        if tokens.count > 14 {
            return tokens.suffix(14).joined(separator: " ")
        }

        return cleaned
    }

    private func requiredIntentTokens(for phrase: String) -> [String] {
        let stopWords: Set<String> = [
            "jarvis", "the", "a", "an", "to", "please"
        ]
        let tokens = TranscriptSanitizer.normalizedTokens(from: phrase).filter { !stopWords.contains($0) }

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