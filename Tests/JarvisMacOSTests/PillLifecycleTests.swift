import XCTest
@testable import JarvisMacOS

@MainActor
final class PillLifecycleTests: XCTestCase {
    private var controller: DictationController!
    private var nativePhase: AppPhase = .Ready
    private var clock = Date()
    private var starts = 0
    private var cancels = 0
    private var releases = 0
    private var restartModes: [PillMode] = []
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        STTRouter.shared.releaseModalOwner()
        STTRouter.shared.releaseFromCommand()
        STTRouter.shared.cancelPendingModalStarts()
        STTRouter.shared.pillSuppressesCommandVAD = false
        suite = "jarvis-pill-test-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        controller = DictationController(defaults: defaults, capture: DictationCapture(
            phase: { self.nativePhase },
            start: { self.starts += 1; self.nativePhase = .Recording; return true },
            stop: { self.nativePhase = .Processing },
            cancel: { self.cancels += 1; self.nativePhase = .Ready }
        ), presentsUI: false, releaseTransientMic: { self.releases += 1 },
            requestRestart: { self.restartModes.append($0) }, now: { self.clock })
        controller.phase = .Ready
    }

    override func tearDown() {
        controller.dismissTranscript()
        controller = nil
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testCloseWhileRecordingCancelsCaptureAndDropsLateTranscript() {
        controller.toggleDictation()
        XCTAssertEqual(starts, 1)
        controller.dismissTranscript()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(STTRouter.shared.owner, .none)
        XCTAssertFalse(STTRouter.shared.pillSuppressesCommandVAD)
        controller.receiveDictationTranscript("late ghost text", speechSeconds: 2)
        XCTAssertEqual(controller.transcript, "")
    }

    func testSecondPressStopsCaptureAndThirdPressCancelsProcessing() {
        controller.toggleDictation()
        controller.toggleDictation()
        XCTAssertEqual(controller.phase, .Processing)
        XCTAssertEqual(releases, 1, "The one-shot mic must close before polish or popup dismissal")
        controller.toggleDictation()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(STTRouter.shared.owner, .none)
    }

    func testShortcutOnFinishedCardClosesWithoutStartingAnotherRecording() {
        controller.toggleDictation()
        controller.phase = .TranscriptReady
        nativePhase = .Ready // even with a stale native/UI phase mirror
        controller.toggleDictation()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(STTRouter.shared.owner, .none)
    }

    func testOtherShortcutAlsoClosesFinishedCardWithoutOpeningAnUnpreparedMic() {
        controller.toggleDictation()
        controller.phase = .TranscriptReady
        nativePhase = .TranscriptReady
        controller.toggleAction()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(STTRouter.shared.owner, .none)
    }

    func testCancelledModelWaitCannotOpenARecordingWhenModelBecomesReady() {
        nativePhase = .Preparing
        controller.phase = .Preparing
        controller.toggleDictation()
        XCTAssertTrue(controller.pendingStartOnReady)
        controller.toggleDictation()
        XCTAssertFalse(controller.pendingStartOnReady)
        nativePhase = .Ready
        controller.phase = .Ready
        controller.flushPendingStart()
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(STTRouter.shared.owner, .none)
    }

    func testAnOldModelWaitRequiresAFreshPressRatherThanStartingMinutesLater() {
        nativePhase = .Preparing
        controller.phase = .Preparing
        controller.toggleDictation()
        clock = clock.addingTimeInterval(60)
        nativePhase = .Ready
        controller.phase = .Ready
        controller.flushPendingStart()
        XCTAssertFalse(controller.pendingStartOnReady)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(STTRouter.shared.owner, .none)
    }

    func testRetryCancelsOldCaptureAndRequestsFreshMicrophonePreparation() {
        controller.toggleAction()
        controller.phase = .Error
        nativePhase = .Error
        controller.retryRecording()
        XCTAssertEqual(starts, 1, "Retry must prepare fresh audio before recording")
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(controller.phase, .Ready)
        XCTAssertEqual(STTRouter.shared.owner, .none)
        XCTAssertEqual(restartModes, [.action])
    }

    func testSecondPressCancelsPendingPermissionAndRejectsLateCompletion() async {
        let started = expectation(description: "prepare waiting")
        let finished = expectation(description: "old permission returned")
        var continuation: CheckedContinuation<Bool, Never>?
        var toggles = 0
        var cleanups = 0
        let coordinator = PillShortcutCoordinator(prepare: {
            let ready = await withCheckedContinuation { continuation = $0; started.fulfill() }
            finished.fulfill()
            return ready
        }, cancelPreparation: { cleanups += 1 }, hasSession: { false }, toggle: { _ in toggles += 1 })
        coordinator.press(.dictate)
        await fulfillment(of: [started], timeout: 1)
        coordinator.press(.dictate)
        XCTAssertNil(coordinator.pendingMode)
        continuation?.resume(returning: true)
        await fulfillment(of: [finished], timeout: 1)
        await Task.yield()
        XCTAssertEqual(toggles, 0)
        XCTAssertEqual(cleanups, 1)
    }

    func testClosingAnExistingPillDoesNotPrepareTheMicrophone() {
        var toggles = 0
        let coordinator = PillShortcutCoordinator(prepare: {
            XCTFail("Stop/close must not open a microphone")
            return true
        }, cancelPreparation: {}, hasSession: { true }, toggle: { _ in toggles += 1 })
        coordinator.press(.action)
        XCTAssertEqual(toggles, 1)
    }
}
