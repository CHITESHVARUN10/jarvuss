import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let enrollmentCompletedDefaultsKey = "jarvis.enrollment.completed"
    static let backendSampleCountDefaultsKey = "jarvis.voice.backendSampleCount"

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
    /// Follow-up grace after a command, seconds (1–10, user-selectable).
    @Published var sessionTimeoutSeconds: Int =
        min(max(UserDefaults.standard.object(forKey: "jarvis.sessionTimeoutSeconds") as? Int ?? 10, 1), 10) {
        didSet {
            UserDefaults.standard.set(sessionTimeoutSeconds, forKey: "jarvis.sessionTimeoutSeconds")
        }
    }
    var sessionTimeout: TimeInterval { TimeInterval(sessionTimeoutSeconds) }
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
    /// Live-mode (wake word) verification policy — independent of the ⌘⇧A
    /// toggle so either mode can be gated independently. Default true.
    @Published var voiceModeRequiresVerify: Bool = UserDefaults.standard.object(forKey: "jarvis.voiceModeRequiresVerify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceModeRequiresVerify, forKey: "jarvis.voiceModeRequiresVerify") }
    }
    /// Python backend process policy — Automatic (start on demand, idle out),
    /// Always running (launch at boot), or Off (never start).
    @Published var backendMode: BackendMode = BackendServiceManager.mode {
        didSet {
            guard oldValue != backendMode else { return }
            BackendServiceManager.mode = backendMode
            Task { @MainActor in
                await applyBackendMode(backendMode)
            }
        }
    }
    /// First-run setup: false until "Finish setup" (Setup pane). Drives the
    /// initial pane selection and the rail badge.
    @Published var setupCompleted: Bool = UserDefaults.standard.bool(forKey: "jarvis.setup.completed") {
        didSet { UserDefaults.standard.set(setupCompleted, forKey: "jarvis.setup.completed") }
    }
    /// Active section — AppState-owned so pages can deep-link each other
    /// (Setup → Connections). Assistant is the workspace entry point; the
    /// first-run checklist lives under Preferences and keeps its own badge.
    @Published var activeSection: RailSection = .assistant
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
    /// Dictation diagnostics (Assistant → Behaviour): one JSONL line per
    /// dictation with the raw input, rules/final text, and timing breakdown.
    @Published var dictationDevLogEnabled: Bool =
        UserDefaults.standard.bool(forKey: DictationDevLog.defaultsKey) {
        didSet { UserDefaults.standard.set(dictationDevLogEnabled, forKey: DictationDevLog.defaultsKey) }
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
    @Published var ollamaModelInstalled: Bool = false
    @Published var ollamaStatusText: String = "qwen2.5 · 1.5b instruct"
    /// Reads the backend's configured values (never the password) for
    /// prefilling the Connections pane form.
    @Published var postgresForm = PostgresForm()
    /// Event-logging switch (UserDefaults-backed) — gates all PG writes.
    @Published var eventLoggingEnabled: Bool = UserDefaults.standard.object(forKey: "jarvis.eventLogging.enabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(eventLoggingEnabled, forKey: "jarvis.eventLogging.enabled")
            dbManager.loggingEnabled = eventLoggingEnabled
            if eventLoggingEnabled {
                dbManager.setup()
                statsRecorder.requestFlush()
            }
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
    var enrollmentPreparing = false
    var enrollmentPreparationTask: Task<Void, Never>?
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

    var micStartedForEnrollment = false
    var activeCommandRunToken: UUID?
    let micManager: AudioCapturing
    private let logger: Logger
    let dbManager: DBManager
    let actionExecutor: PlanExecuting
    private let automationStore = AutomationStore()
    let voiceAuthClient: SpeakerVerifying
    let spotifyClient = SpotifyClient()
    let postgresClient = PostgresClient()
    let actionPlanner: ActionPlanning
    let statsRecorder: StatsRecorder
    let intentLog: IntentRouterLog
    let presentsUI: Bool
    private let emergencyDisplayRecovery: @MainActor () -> Void
    private let backendServiceManager = BackendServiceManager.shared
    private let displayController = DisplayController()
    let commandQueue = CommandQueueManager()

    private var previousVoiceDetected = false
    private var lastVoiceTimestamp = Date.distantPast
    private var smoothedAudioLevelDB: Float = -160.0
    /// False until the first real level arrives after a mic (re)start — the
    /// seed replaces the -160 dB cold start that delayed VAD onset ~250 ms.
    private var smoothedAudioLevelSeeded = false
    private var recordingStartedAt = Date.distantPast
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
    var lastEnrollmentAcceptedAt = Date.distantPast
    var lastEnrollmentAcceptedTranscript = ""
    var lastEnrollmentAttemptAt = Date.distantPast

    private let voiceStartThresholdDB: Float = -42.0
    private let voiceContinueThresholdDB: Float = -50.0
    private let minimumRecordingDuration: TimeInterval = 0.8
    private let requiredSilenceDuration: TimeInterval = 1.2
    private let smoothingFactor: Float = 0.35
    /// Longest unbroken voiced run before the utterance is force-segmented
    /// (see handleAudioLevel). Sits just past Rust chunk_seconds=6 so each
    /// segment carries a live partial before the split fires.
    private static let maxContinuousSpeechSeconds: TimeInterval = 8.0
    let enrollmentAcceptCooldown: TimeInterval = 1.4
    let enrollmentAttemptThrottle: TimeInterval = 0.30
    let voiceVerificationThreshold = 0.70
    /// How long after hearing "Jarvis" a follow-up without the wake word is
    /// still accepted as its command ("Jarvis" … pause … "open Spotify").
    private static let pendingWakeWordGraceSeconds: TimeInterval = 4.0
    static let verifyAudioSeconds = 3.5
    static let enrollAudioSeconds = 3.5
    /// Minimum RMS of the verify clip — below this the buffer is silence and
    /// the backend would 400 (or Resemblyzer would embed noise). Skip the
    /// POST and reject locally instead.
    static let verifyMinClipRMS: Float = 0.005
    // Hallucinated-singleton filtering lives in TranscriptSanitizer
    // (single table shared with the batch path).
    /// Resemblyzer embeds via preprocess_wav at 16 kHz. Exporting at the
    /// same rate removes a resample-variance source between enroll-time
    /// and verify-time embeddings and keeps clips comparable sample-for-sample.
    static let voiceSampleRate = 16_000.0

    /// Read-only surfaces for the Assistant pane (threshold display, profile row).
    var voiceVerifyThreshold: Double { voiceVerificationThreshold }
    var displayProfileName: String { displayController.profileName }

    var voiceEnrollmentSampleTarget: Int {
        enrollmentPhrases.count * enrollmentRequiredMatchesPerPhrase
    }

    var voiceProfileReady: Bool {
        // The backend sample count is the source of truth. The local
        // `enrollmentCompleted` flag is only a cache and can lag behind a
        // restored profile (e.g. after deleting preferences).
        backendEnrollmentSampleCount >= voiceEnrollmentSampleTarget
    }

    var eventLogText: String {
        logs.joined(separator: "\n")
    }

    var canUseVoiceMode: Bool { !voiceModeRequiresVerify || voiceProfileReady }

    var currentEnrollmentPhrase: String {
        guard enrollmentPhrases.indices.contains(enrollmentIndex) else { return "Completed" }
        return enrollmentPhrases[enrollmentIndex]
    }

    init(
        micManager: AudioCapturing = MicManager.shared,
        logger: Logger = Logger(),
        dbManager: DBManager = DBManager(),
        actionPlanner: ActionPlanning = ActionPlanner(),
        actionExecutor: PlanExecuting = ActionExecutor(),
        voiceAuthClient: SpeakerVerifying = VoiceAuthClient(),
        statsRecorder: StatsRecorder = .shared,
        intentLog: IntentRouterLog = .shared,
        activateServices: Bool = true,
        emergencyDisplayRecovery: (@MainActor () -> Void)? = nil
    ) {
        self.micManager = micManager
        self.logger = logger
        self.dbManager = dbManager
        self.actionPlanner = actionPlanner
        self.actionExecutor = actionExecutor
        self.voiceAuthClient = voiceAuthClient
        self.statsRecorder = statsRecorder
        self.intentLog = intentLog
        self.presentsUI = activateServices
        self.emergencyDisplayRecovery = emergencyDisplayRecovery ?? { DisplayRecovery.shared.restore() }
        micManager.setInterruptionHandler { [weak self] message in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pillActive = self.presentsUI && DictationController.shared.hasModalSession
                self.stopMicrophone(cancelPill: false)
                self.microphoneError = message
                self.appendLog(message)
                if pillActive { DictationController.shared.presentCaptureFailure(message) }
                else if self.presentsUI {
                    self.popupManager.show(message: message, icon: "mic.slash", duration: 6)
                }
            }
        }
        guard activateServices else { return }
        AppState.shared = self
        commandQueue.onCancel = { [weak self] in self?.invalidateActiveCommand() }
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
            MainActor.assumeIsolated {
                guard let self, self.isLiveListening, !self.isStoppingMicrophone else { return }
                self.appendLog("[Speech][Whisper] FINAL: '\(text)'")
                self.handleTranscript(text, isFinal: true)
            }
        }
        // Action pill (⌘⇧A): the press is the intent — no wake word, no
        // voice-mode gate. Runs through the SAME verify/execute path as
        // typed commands (verify per the user setting above).
        STTRouter.shared.onActionTranscript = { [weak self] text in
            MainActor.assumeIsolated {
                self?.handleActionPillCommand(text)
            }
        }
        // Live partials (per-chunk stitch, ~6 s cadence) drive the main
        // window "LIVE TRANSCRIPT" card while the user is still talking.
        STTRouter.shared.onCommandPartial = { [weak self] text in
            MainActor.assumeIsolated {
                guard let self, self.isLiveListening, !self.isStoppingMicrophone else { return }
                self.handleTranscript(text, isFinal: false)
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
        statsRecorder.onFlush = { [dbManager] batch in
            await dbManager.upsertDailyStats(batch)
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
            appendLog("[VoiceSession] Session extended (+\(sessionTimeoutSeconds)s) by command: '\(command)'. Expires at \(timeStr)")
        }
    }

    // MARK: - Fix #1: Hard Reset Voice Pipeline
    /// Wipes ALL cross-transcript state so no stale command can bleed into
    /// a new voice recognition session. Called before every session restart.
    private func resetVoicePipelineState() {
        lastBatchHandledTranscript   = ""
        pendingWakeWordDetected      = false
        pendingWakeWordDetectedAt    = .distantPast
        smoothedAudioLevelSeeded     = false
        appendLog("[Voice] Pipeline state hard-reset.")
    }

    func bootstrap() async {
        BackendServiceManager.statusChangeHandler = { [weak self] status in
            self?.backendStatus = status
        }
        BackendServiceManager.idleStopHandler = { [weak self] message in
            Task { @MainActor in
                self?.backendStatus = "Not started"
                self?.appendLog(message)
            }
        }
        setupTablesIfConfigured()

        await applyBackendModeAtLaunch(BackendServiceManager.mode)

        await refreshOllamaStatus()
        reflectPostgresConfigWithoutBackend()

        restoreEnrollmentStateFast()
        await reconcileEnrollmentFromDB()
        await syncVoiceProfileStatusFromBackend()
        // Listening is MANUAL by design: the mic stays cold until the user
        // taps the orb or presses a hotkey. Wake word, VAD and dictation all
        // come up from the same startMicrophone() — nothing to arm here.
        appendLog("Ready. Tap the orb (or press ⌘⇧D / ⌘⇧A) to start listening.")
    }

    /// Backend lifecycle at launch. `.always` starts the process; the other
    /// modes probe and report only — nothing Python is spawned until a
    /// feature needs it (verification, enrollment, Spotify, Connections).
    private func applyBackendModeAtLaunch(_ mode: BackendMode) async {
        guard mode != .off else {
            backendStatus = "Backend off"
            appendLog("[Backend] Mode is Off — voice auth, Spotify and the intent model are unavailable.")
            return
        }

        if await BackendServiceManager.shared.isHealthy() {
            BackendServiceManager.noteActivity()
            BackendServiceManager.armIdleWatchdog()
            backendStatus = "Backend running"
            appendLog("[Backend] Found an already-running backend on port 8000 — reusing it.")
            await refreshSpotifyStatus()
            return
        }

        if mode == .automatic {
            backendStatus = "Not started"
            appendLog("[Backend] Automatic mode — backend starts on demand (0 MB Python at idle).")
        } else {
            await startBundledBackendIfNeeded()
        }
    }

    /// Reacts to a mode change made in Settings while running.
    private func applyBackendMode(_ mode: BackendMode) async {
        switch mode {
        case .off:
            backendServiceManager.stopIfNeeded { [weak self] message in
                Task { @MainActor in self?.appendLog(message) }
            }
            backendStatus = "Backend off"
            appendLog("[Backend] Mode set to Off — voice auth, Spotify and the intent model are unavailable.")
        case .always:
            await startBundledBackendIfNeeded()
        case .automatic:
            BackendServiceManager.noteActivity()
            BackendServiceManager.armIdleWatchdog()
            if await BackendServiceManager.shared.isHealthy() {
                backendStatus = "Backend running"
            } else {
                backendStatus = "Not started"
                appendLog("[Backend] Mode set to Automatic — backend will start on demand.")
            }
        }
    }

    /// Table creation + the Rails-style status that needs no backend: the
    /// merged RuntimeConfiguration IS the configuration truth on this Mac.
    private func setupTablesIfConfigured() {
        dbManager.setup()
        if dbManager.isConfigured {
            appendLog("PostgreSQL logging is enabled.")
        } else {
            appendLog("PostgreSQL logging disabled (optional). To enable: export PGHOST=127.0.0.1 PGPORT=5432 PGDATABASE=jarvis_db PGUSER=jarvis_user — missing: \(DBManager.missingEnvKeys.joined(separator: ","))")
        }
    }

    private func reflectPostgresConfigWithoutBackend() {
        postgresConfigured = dbManager.isConfigured
        postgresStatusText = postgresConfigured ? "Configured" : "Not configured"
    }

    func shutdown() {
        stopEnrollment()
        statsRecorder.flush()
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
            BackendServiceManager.noteActivity()
            BackendServiceManager.armIdleWatchdog()
            await refreshSpotifyStatus()
        } else {
            backendStartupError = result.message
            backendStatus = "Backend failed"
            appendLog("[Backend][ERROR] \(result.message)")
            popupManager.show(message: "Backend start failed. Some features may be unavailable.", icon: "exclamationmark.triangle.fill", duration: 4)
        }
    }

    private var microphoneSessionID: UUID?
    private var microphoneStartPending = false
    @Published private(set) var microphoneError: String?

    func startMicrophone() async {
        guard !micActive, !microphoneStartPending else { return }
        let sessionID = UUID()
        microphoneSessionID = sessionID
        microphoneStartPending = true
        microphoneError = nil
        defer {
            if microphoneSessionID == sessionID { microphoneStartPending = false }
        }
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
                        guard let self, self.microphoneSessionID == sessionID,
                              self.micActive, !self.isStoppingMicrophone else { return }
                        self.handleAudioLevel(level)
                    }
                },
                onAudioBuffer: { buffer in
                    // Acoustic wake-word engine (inert without SDK + key):
                    // tap-thread ingest, internally locked.
                    WakeWordDetector.shared.ingest(buffer: buffer)
                }
            )

            guard microphoneSessionID == sessionID, !Task.isCancelled else {
                // A stop during the permission dialog must win. A newer
                // session owns its own capture and must not be stopped here.
                if microphoneSessionID == sessionID || microphoneSessionID == nil {
                    micManager.stopListening()
                    micActive = false
                }
                return
            }

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
            guard microphoneSessionID == sessionID else { return }
            micManager.stopListening()
            micActive = false
            micTransientAutoStart = false
            assistantState = .idle
            appendLog("Microphone start failed: \(error.localizedDescription)")
            microphoneError = error.localizedDescription
            if presentsUI && !Task.isCancelled {
                popupManager.show(message: error.localizedDescription, icon: "mic.slash", duration: 6)
            }
        }
    }

    func stopMicrophone(cancelPill: Bool = true) {
        microphoneSessionID = nil
        microphoneStartPending = false
        isStoppingMicrophone = true
        if cancelPill, presentsUI {
            PillShortcutCoordinator.shared.cancel()
            if DictationController.shared.hasModalSession { DictationController.shared.dismissTranscript() }
        }
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
    var micTransientAutoStart = false

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
        appendLog("One-shot use finished — mic back to idle (listening stays manual).")
        stopMicrophone(cancelPill: false)
    }

    /// Action-pill (⌘⇧A) command entry. Same shape as executeTypedCommand:
    /// validate → classify → enqueue. No wake word (the keypress is the
    /// intent). Verification is per `actionPillRequiresVerify`, changeable
    /// in Settings without touching code.
    @discardableResult
    func recoverDisplayIfRequested(_ text: String) -> Bool {
        guard DisplaySafety.isRecoveryRequest(text) else { return false }
        commandQueue.cancelAll()
        appendLog("[Display recovery] Exact recovery phrase accepted; no verification or AI required.")
        emergencyDisplayRecovery()
        return true
    }

    func handleActionPillCommand(_ raw: String) {
        if recoverDisplayIfRequested(raw) { return }
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
            // Snapshot before queuing or dismissing: a later recording must
            // never replace the audio used to authorize this command.
            let samples = take_verification_audio()
            guard samples.len() > 0 else {
                appendLog("[Action] No audio from this recording; verification rejected.")
                voiceVerificationStatus = "No command audio available"
                return
            }
            let audio = Array(UnsafeBufferPointer(start: samples.as_ptr(), count: samples.len()))
            commandQueue.enqueue(text: command, priority: priority) { [weak self] in
                guard let self else { return }
                let sampleURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("jarvis-action-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: sampleURL) }
                do {
                    try MicManager.writeWav(samples: audio, sampleRate: Self.voiceSampleRate, to: sampleURL)
                    await self.verifyThenRunCommand(command, capturedAudio: sampleURL)
                } catch {
                    self.appendLog("[Action] Could not prepare verification audio: \(error.localizedDescription)")
                }
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
        if recoverDisplayIfRequested(raw) { return }
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
    /// Keeps the last 5 executed commands for the Assistant pane's Recent card.
    func trackRecentCommand(_ command: String) {
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

    func handleTranscript(_ transcript: String, isFinal: Bool) {
        lastRecognizedSpeech = transcript

        // Live partials update the on-screen card immediately (the user
        // asked for visible speech→text while talking). Command execution
        // still waits for the final below.
        guard isFinal else { return }
        if !enrollmentActive && recoverDisplayIfRequested(transcript) { return }

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
            if let app = AppAliasResolver.knownAppName(t) { return "open \(app)" }
            return transcript
        }()
        let transcriptForCommand = repairedTranscript

        guard canUseVoiceMode else {
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
        // Each native capture has its own generation; do not drop a second
        // intentional utterance merely because it arrives quickly.

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
                if self?.voiceModeRequiresVerify == true {
                    await self?.verifyThenRunCommand(validated)
                } else {
                    await self?.runCommand(validated)
                }
            }
            if !accepted {
                appendLog("[Voice] dropped: queue rejected '\(validated)' (see [Queue] line above).")
            }
        }
    }

    func toggleVoiceMode() {
        if voiceModeRequiresVerify {
            guard voiceProfileReady else {
                voiceModeEnabled = false
                appendLog("Complete 7x3 enrollment voice samples before enabling verified voice mode (or turn live-mode verification off).")
                return
            }
        }
        voiceModeEnabled.toggle()
        pendingWakeWordDetected = false
        appendLog("Voice mode \(voiceModeEnabled ? "enabled" : "disabled")\(voiceModeRequiresVerify ? "" : " (wake word only — verification off)").")
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

    /// Acoustic wake word heard (only fires when a real engine is enabled —
    /// see WakeWordDetector). Anchors the pending-wake state so the command
    /// about to be spoken is accepted even if the transcript never contains
    /// "Jarvis", and confirms audibly so the user knows the mic is hot.
    private func handleAcousticWakeWord() {
        guard isLiveListening, voiceModeEnabled, !isStoppingMicrophone, !isTTSSpeaking else { return }
        pendingWakeWordDetected = true
        pendingWakeWordDetectedAt = Date()
        appendLog("[Wake] Acoustic wake word detected — pre-roll anchored.")
        // Tink is the system's subtle cue; NSSound plays nothing when the
        // user's sound is off — that is their setting, not a failure.
        NSSound(named: "Tink")?.play()
    }

    private func handleAudioLevel(_ level: Float) {
        guard micActive, !micTransientAutoStart, !isStoppingMicrophone else { return }
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

    func appendLog(_ event: String) {
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


}
