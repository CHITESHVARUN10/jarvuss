import AVFoundation
import XCTest
@testable import JarvisMacOS

private struct EnrollmentTestMicrophone: AudioCapturing {
    let directory: URL
    func startListeningWithPermission(onLevelUpdate: @escaping (Float) -> Void,
                                     onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?) async throws {
        XCTFail("Enrollment unit tests must not open the microphone")
    }
    func stopListening() {}
    func exportRecentAudioSample(durationSeconds: Double, targetSampleRate: Double?) throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("mock audio".utf8).write(to: url)
        return url
    }
}

private actor EnrollmentTestBackend: SpeakerVerifying {
    var count = 0
    var fail = false
    var deferred = false
    var continuation: CheckedContinuation<Void, Never>?
    func setFailure(_ value: Bool) { fail = value }
    func setDeferred() { deferred = true }
    func release() { continuation?.resume(); continuation = nil }
    func isWaiting() -> Bool { continuation != nil }
    func enroll(audioFileURL: URL) async throws -> Int {
        if deferred { await withCheckedContinuation { continuation = $0 } }
        if fail { throw URLError(.cannotConnectToHost) }
        count += 1
        return count
    }
    func verify(audioFileURL: URL) async throws -> Double { 1 }
    func verifyDetailed(audioFileURL: URL) async throws -> VoiceVerificationResult { fatalError("Not used") }
    func reset() async throws { count = 0 }
    func enrolledCount() async throws -> Int { count }
}

@MainActor
final class GuidedEnrollmentTests: XCTestCase {
    private var directory: URL!
    private var app: AppState!
    private var backend: EnrollmentTestBackend!
    private var savedDefaults: [String: Any] = [:]
    private let keys = [AppState.enrollmentCompletedDefaultsKey, AppState.backendSampleCountDefaultsKey]

    override func setUpWithError() throws {
        for key in keys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-enrollment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = EnrollmentTestBackend()
        app = AppState(micManager: EnrollmentTestMicrophone(directory: directory),
                       logger: Logger(logURL: directory.appendingPathComponent("commands.log")),
                       dbManager: DBManager(configuration: [:]), voiceAuthClient: backend,
                       statsRecorder: StatsRecorder(buffer: StatsBufferStore(fileURL: directory.appendingPathComponent("stats.json")), retryInterval: 0),
                       intentLog: IntentRouterLog(logURL: directory.appendingPathComponent("intent.jsonl")), activateServices: false, prepareVoiceBackend: { true })
        app.enrollmentActive = true
    }
    override func tearDownWithError() throws {
        app.stopEnrollment(); app = nil
        for key in keys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedDefaults = [:]
        try? FileManager.default.removeItem(at: directory)
    }
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Enrollment task did not settle")
    }
    private func sample() async {
        app.lastEnrollmentAcceptedAt = .distantPast
        app.handleEnrollmentTranscript(app.currentEnrollmentPhrase, isFinal: true)
        await until { !app.enrollmentSavingSample }
    }

    func testThreeIdenticalFinalUtterancesAreSavedBeforeAdvancing() async {
        for repetition in 1...3 {
            await sample()
            XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, repetition)
            XCTAssertEqual(app.backendEnrollmentSampleCount, repetition)
            XCTAssertEqual(app.enrollmentIndex, 0)
        }
        XCTAssertTrue(app.enrollmentAwaitingNextPhrase)
        await sample()
        XCTAssertEqual(app.backendEnrollmentSampleCount, 3, "Extra speech cannot count while waiting for Next phrase")
        app.advanceEnrollmentPhrase()
        XCTAssertEqual(app.enrollmentIndex, 1)
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 0)
        XCTAssertFalse(app.enrollmentAwaitingNextPhrase)
    }
    func testFailedSaveDoesNotAdvanceAndSamePhraseCanBeRetried() async {
        await backend.setFailure(true)
        await sample()
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 0)
        XCTAssertEqual(app.backendEnrollmentSampleCount, 0)
        XCTAssertTrue(app.enrollmentMessage.contains("could not be saved"))
        await backend.setFailure(false)
        await sample()
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 1)
    }
    func testInFlightDuplicateAndLateCompletionAfterPauseAreIgnored() async {
        await backend.setDeferred()
        app.handleEnrollmentTranscript(app.currentEnrollmentPhrase, isFinal: true)
        for _ in 0..<100 {
            if await backend.isWaiting() { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(app.enrollmentSavingSample)
        app.handleEnrollmentTranscript(app.currentEnrollmentPhrase, isFinal: true)
        XCTAssertEqual(app.enrollmentMatchedCount, 0)
        let task = app.enrollmentSampleTask
        app.stopEnrollment()
        await backend.release()
        await task?.value
        XCTAssertTrue(app.enrollmentPaused)
        XCTAssertEqual(app.enrollmentMatchedCount, 0)
        XCTAssertEqual(app.backendEnrollmentSampleCount, 0)
        XCTAssertFalse(app.enrollmentCompleted)
    }
    func testFinalSavedSampleCompletesWithoutAnotherPhrase() async {
        app.enrollmentPhrases = ["Jarvis open Chrome"]
        for _ in 0..<3 { await sample() }
        XCTAssertTrue(app.voiceProfileReady)
        XCTAssertTrue(app.enrollmentCompleted)
        XCTAssertFalse(app.enrollmentActive)
        XCTAssertFalse(app.enrollmentPaused)
        XCTAssertFalse(app.enrollmentAwaitingNextPhrase)
    }
    func testPauseKeepsPositionAndCannotSkipUnfinishedPhrase() {
        app.enrollmentIndex = 4
        app.enrollmentCurrentPhraseMatchCount = 1
        app.advanceEnrollmentPhrase()
        XCTAssertEqual(app.enrollmentIndex, 4)
        app.stopEnrollment()
        app.stopEnrollment()
        XCTAssertTrue(app.enrollmentPaused)
        XCTAssertEqual(app.enrollmentIndex, 4)
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 1)
    }
    func testPartialAndMismatchedUtterancesNeverCount() async {
        app.handleEnrollmentTranscript(app.currentEnrollmentPhrase, isFinal: false)
        app.handleEnrollmentTranscript("a completely different request", isFinal: true)
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 0)
        XCTAssertFalse(app.enrollmentSavingSample)
        let count = try? await backend.enrolledCount()
        XCTAssertEqual(count, 0)
    }
    func testResumePreservesStoredSamplesAndPhrasePosition() async {
        await sample()
        app.stopEnrollment()
        app.micActive = true // Existing manual session; no microphone is opened.
        app.resumeEnrollment()
        await until { !app.enrollmentPreparing }
        XCTAssertTrue(app.enrollmentActive)
        XCTAssertFalse(app.enrollmentPaused)
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 1)
        XCTAssertEqual(app.backendEnrollmentSampleCount, 1)
        await sample()
        XCTAssertEqual(app.enrollmentCurrentPhraseMatchCount, 2)
    }
    func testConfirmedClearRemovesCompletionAndPausedProgress() async {
        app.enrollmentActive = false
        app.enrollmentCompleted = true
        app.backendEnrollmentSampleCount = 42
        app.enrollmentPaused = true
        app.enrollmentIndex = 5
        app.voiceModeEnabled = true
        app.resetVoiceProfile()
        XCTAssertTrue(app.voiceProfileResetting)
        await until { !app.voiceProfileResetting }
        XCTAssertFalse(app.voiceProfileReady)
        XCTAssertFalse(app.enrollmentCompleted)
        XCTAssertFalse(app.enrollmentPaused)
        XCTAssertFalse(app.voiceModeEnabled)
        XCTAssertEqual(app.enrollmentIndex, 0)
    }

}
