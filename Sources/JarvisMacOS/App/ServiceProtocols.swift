import AVFoundation
import Foundation

// MARK: - Service seams
//
// Protocols for AppState's collaborators so units are constructible with
// fakes (no mic / network / database in tests). Conformances sit next to
// each protocol; stored properties stay concrete only where views observe
// the concrete type (DBManager → StatsView), everything else injects the
// protocol with a concrete default — zero call-site churn.

// MARK: - LLMGenerating

/// Single local LLM. Production: OllamaClient.
protocol LLMGenerating {
    func generate(prompt: String) async -> String
}

extension OllamaClient: LLMGenerating {}

// MARK: - SpeakerVerifying

/// Voiceprint enroll / verify / reset / stats. Production: VoiceAuthClient.
protocol SpeakerVerifying {
    func enroll(audioFileURL: URL) async throws -> Int
    func verify(audioFileURL: URL) async throws -> Double
    func verifyDetailed(audioFileURL: URL) async throws -> VoiceVerificationResult
    func reset() async throws
    func enrolledCount() async throws -> Int
}

extension VoiceAuthClient: SpeakerVerifying {}

// MARK: - PlanExecuting

/// Runs a PlannedAction plan step-by-step. Production: ActionExecutor.
protocol PlanExecuting {
    var onLog: ((String) -> Void)? { get set }
    func execute(
        plan: [PlannedAction],
        onStepStart: @escaping (PlannedAction) -> Void,
        onStepComplete: @escaping (ActionResult) -> Void
    ) async
}

extension ActionExecutor: PlanExecuting {}

// MARK: - AudioCapturing

/// Microphone lifecycle + recent-audio export. Production: MicManager.
protocol AudioCapturing {
    func startListeningWithPermission(
        onLevelUpdate: @escaping (Float) -> Void,
        onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    ) async throws
    func stopListening()
    func exportRecentAudioSample(durationSeconds: Double, targetSampleRate: Double?) throws -> URL
}

extension MicManager: AudioCapturing {}

// MARK: - EventLogging

/// PostgreSQL event/stats logging. Production: DBManager.
///
/// AppState.dbManager stays concrete for now because StatsView observes
/// `DBManager` directly — migrating that view is a separate change. New
/// code should depend on this protocol instead.
protocol EventLogging: AnyObject {
    var loggingEnabled: Bool { get set }
    var isConfigured: Bool { get }

    func setup()
    func reloadConfiguration()
    func saveEvent(
        eventType: String,
        transcript: String?,
        targetPhrase: String?,
        score: Double?,
        matched: Bool?,
        phraseIndex: Int?,
        normalizedCommand: String?,
        executionResult: String?,
        metadata: [String: String]?
    )
    func upsertDailyStats(_ bucket: DayBucket)
    func fetchDailyStats(sinceDays: Int) async -> [DayBucket]
    func hasEnrollmentCompletionEvent() async -> Bool
}

extension DBManager: EventLogging {}
