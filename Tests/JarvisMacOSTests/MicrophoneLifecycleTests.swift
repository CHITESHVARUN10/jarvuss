import AVFoundation
import XCTest
@testable import JarvisMacOS

private final class DeferredMicrophone: AudioCapturing {
    var continuation: CheckedContinuation<Void, Never>?
    var started: XCTestExpectation?
    var capturing = false
    var interruption: ((String) -> Void)?
    func setInterruptionHandler(_ handler: @escaping (String) -> Void) { interruption = handler }
    var starts = 0
    var stops = 0

    @MainActor
    func startListeningWithPermission(onLevelUpdate: @escaping (Float) -> Void,
                                     onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?) async throws {
        starts += 1
        await withCheckedContinuation {
            continuation = $0
            started?.fulfill()
        }
        // Deliberately ignore cancellation, as a system permission prompt can.
        capturing = true
    }
    func stopListening() { stops += 1; capturing = false }
    func exportRecentAudioSample(durationSeconds: Double, targetSampleRate: Double?) throws -> URL {
        throw MicManagerError.insufficientAudio
    }
}

@MainActor
final class MicrophoneLifecycleTests: XCTestCase {
    private var directory: URL!
    private var app: AppState!
    private var microphone: DeferredMicrophone!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        microphone = DeferredMicrophone()
        app = AppState(micManager: microphone,
            logger: Logger(logURL: directory.appendingPathComponent("commands.log")),
            dbManager: DBManager(configuration: [:]),
            statsRecorder: StatsRecorder(buffer: StatsBufferStore(fileURL: directory.appendingPathComponent("stats.json")), retryInterval: 0),
            intentLog: IntentRouterLog(enabled: false), activateServices: false)
    }

    override func tearDownWithError() throws {
        app = nil
        microphone = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testTransientlyUnavailableInputFormatIsRejectedBeforeInstallingATap() {
        XCTAssertFalse(MicManager.isUsableInputFormat(sampleRate: 0, channels: 1))
        XCTAssertFalse(MicManager.isUsableInputFormat(sampleRate: 48000, channels: 0))
        XCTAssertFalse(MicManager.isUsableInputFormat(sampleRate: .nan, channels: 1))
        XCTAssertTrue(MicManager.isUsableInputFormat(sampleRate: 48000, channels: 2))
    }

    func testInputWatchdogDistinguishesSilentBuffersFromStoppedDelivery() {
        let now = Date()
        XCTAssertFalse(MicManager.inputHasStalled(lastBufferAt: now, now: now))
        XCTAssertFalse(MicManager.inputHasStalled(lastBufferAt: now.addingTimeInterval(-2), now: now))
        XCTAssertTrue(MicManager.inputHasStalled(lastBufferAt: now.addingTimeInterval(-4), now: now))
        XCTAssertTrue(MicManager.inputHasStalled(lastBufferAt: nil, now: now))
    }

    func testAudioDeviceExceptionIsConvertedToARetryableError() {
        XCTAssertThrowsError(try MicManager.performAudioOperation {
            NSException(name: .invalidArgumentException, reason: "Input device changed during tap installation").raise()
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Input device changed"))
            XCTAssertTrue(error.localizedDescription.contains("Retry"))
        }
    }

    func testInputDeviceChangeStopsTheVisibleMicrophoneSession() async {
        microphone.started = expectation(description: "permission pending")
        let start = Task { await app.startMicrophone() }
        await fulfillment(of: [microphone.started!], timeout: 1)
        microphone.continuation?.resume()
        await start.value
        XCTAssertTrue(app.micActive)
        microphone.interruption?("Input device changed")
        XCTAssertFalse(app.micActive)
        XCTAssertFalse(microphone.capturing)
    }

    func testStopDuringPermissionPromptCannotRestartMicrophone() async {
        microphone.started = expectation(description: "permission pending")
        let start = Task { await app.startMicrophone() }
        await fulfillment(of: [microphone.started!], timeout: 1)
        app.stopMicrophone()
        microphone.continuation?.resume()
        await start.value
        XCTAssertFalse(app.micActive)
        XCTAssertFalse(app.isLiveListening)
        XCTAssertFalse(microphone.capturing)
    }

    func testRepeatedStartsDoNotOpenCompetingCaptureSessions() async {
        microphone.started = expectation(description: "permission pending")
        let first = Task { await app.startMicrophone() }
        await fulfillment(of: [microphone.started!], timeout: 1)
        await app.startMicrophone()
        XCTAssertEqual(microphone.starts, 1)
        microphone.continuation?.resume()
        await first.value
        XCTAssertTrue(app.micActive)
        app.stopMicrophone()
        XCTAssertFalse(microphone.capturing)
    }

    func testTransientCleanupAlsoCancelsAnUnfinishedStart() async {
        microphone.started = expectation(description: "permission pending")
        app.markTransientMicStart()
        let start = Task { await app.startMicrophone() }
        await fulfillment(of: [microphone.started!], timeout: 1)
        app.restoreMicAfterTransientStartIfNeeded()
        microphone.continuation?.resume()
        await start.value
        XCTAssertFalse(app.micActive)
        XCTAssertFalse(app.micTransientAutoStart)
        XCTAssertFalse(microphone.capturing)
    }
}
