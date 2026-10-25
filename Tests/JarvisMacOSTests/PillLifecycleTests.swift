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

    func testMicrophoneFailureShowsAnActionErrorThatCanRetryWithFreshPreparation() {
        controller.presentCaptureFailure("Input device is unavailable", mode: .action)
        XCTAssertEqual(controller.phase, .Error)
        XCTAssertEqual(controller.errorMessage, "Input device is unavailable")
        XCTAssertEqual(STTRouter.shared.owner, .action)
        XCTAssertTrue(controller.hasModalSession)
        controller.retryRecording()
        XCTAssertEqual(STTRouter.shared.owner, .none)
        XCTAssertEqual(restartModes, [.action])
        XCTAssertEqual(starts, 0)
    }

    func testStopFailureDoesNotBecomeAnEndlessProcessingPill() {
        controller = DictationController(defaults: defaults, capture: DictationCapture(
            phase: { self.nativePhase },
            start: { self.nativePhase = .Recording; return true },
            stop: { self.nativePhase = .Error }, cancel: { self.nativePhase = .Ready },
            error: { "No microphone audio was received" }
        ), presentsUI: false, releaseTransientMic: {}, requestRestart: { self.restartModes.append($0) })
        controller.toggleDictation()
        controller.toggleDictation()
        XCTAssertEqual(controller.phase, .Error)
        XCTAssertEqual(controller.errorMessage, "No microphone audio was received")
        XCTAssertTrue(controller.hasModalSession)
        controller.retryRecording()
        XCTAssertEqual(restartModes, [.dictate])
    }

    func testFailedPreparationReportsTheRequestedModeInsteadOfSilentlyDoingNothing() async {
        for mode in [PillMode.dictate, .action] {
            let reported = expectation(description: "preparation failed")
            var cleanups = 0
            let coordinator = PillShortcutCoordinator(prepare: { false },
                cancelPreparation: { cleanups += 1 }, hasSession: { false },
                toggle: { _ in XCTFail("Unavailable input must not start recording") },
                preparationFailed: { receivedMode in
                    XCTAssertEqual(receivedMode, mode)
                    reported.fulfill()
                })
            coordinator.press(mode)
            await fulfillment(of: [reported], timeout: 1)
            XCTAssertEqual(cleanups, 1)
            XCTAssertNil(coordinator.pendingMode)
        }
    }

    func testMissedHotkeyReleaseRecoversButPhysicalAutoRepeatIsSuppressed() {
        var latch = HotkeyLatch()
        XCTAssertTrue(latch.press())
        latch.recover(physicalKeyDown: true)
        XCTAssertFalse(latch.press())
        latch.recover(physicalKeyDown: false)
        XCTAssertTrue(latch.press(), "A swallowed Carbon key-up must not disable subsequent presses")
        latch.release()
        XCTAssertFalse(latch.held)
    }
    func testPreparationIsVisibleSynchronouslyBeforePermissionWorkStarts() async {
        var events: [String] = []
        let done = expectation(description: "toggle")
        let coordinator = PillShortcutCoordinator(prepare: {
            events.append("permission")
            return true
        }, cancelPreparation: {}, hasSession: { false }, toggle: { _ in
            events.append("toggle")
            done.fulfill()
        }, preparationBegan: { _ in events.append("visible") })
        coordinator.press(.dictate)
        XCTAssertEqual(events, ["visible"])
        await fulfillment(of: [done], timeout: 1)
        XCTAssertEqual(events, ["visible", "permission", "toggle"])
    }

    func testRecordingLimitIsPersistedBoundedAndFrozenForCurrentCapture() {
        var limits: [UInt64] = []
        controller = DictationController(defaults: defaults, capture: DictationCapture(
            phase: { self.nativePhase },
            start: { self.nativePhase = .Recording; return true }, stop: {},
            cancel: { self.nativePhase = .Ready }, configureLimit: { limits.append($0) }
        ), presentsUI: false, releaseTransientMic: {}, requestRestart: { _ in })
        XCTAssertEqual(controller.recordingLimitMinutes, 5)
        controller.recordingLimitMinutes = 15
        controller.toggleDictation()
        XCTAssertEqual(limits, [900])
        controller.recordingLimitMinutes = 20
        XCTAssertEqual(controller.activeRecordingLimitMinutes, 15)
        XCTAssertEqual(defaults.integer(forKey: DictationController.recordingLimitDefaultsKey), 20)
        controller.dismissTranscript()
        let restored = DictationController(defaults: defaults, presentsUI: false)
        XCTAssertEqual(restored.recordingLimitMinutes, 20)
        controller.recordingLimitMinutes = 999
        XCTAssertEqual(controller.recordingLimitMinutes, 60)
        controller.recordingLimitMinutes = -1
        XCTAssertEqual(controller.recordingLimitMinutes, 1)
    }

    func testNativeAutoStopClosesActivityAndUsesCapturedDuration() {
        controller = DictationController(defaults: defaults, capture: DictationCapture(
            phase: { self.nativePhase },
            start: { self.nativePhase = .Recording; return true }, stop: {},
            cancel: { self.nativePhase = .Ready }, seconds: { 900 }
        ), presentsUI: false, releaseTransientMic: { self.releases += 1 }, requestRestart: { _ in })
        controller.toggleDictation()
        controller.captureFinished()
        XCTAssertEqual(controller.pendingSpeechSecs, 900)
        XCTAssertEqual(releases, 1)
        controller.captureFinished()
        XCTAssertEqual(releases, 1, "Duplicate native state callbacks must not release a later microphone")
    }

    func testStopAtTheSameTimeAsNativeLimitRetainsOwnershipForTheFinal() {
        controller.toggleDictation()
        nativePhase = .Processing
        controller.toggleDictation()
        XCTAssertEqual(controller.phase, .Processing)
        XCTAssertEqual(STTRouter.shared.owner, .pill)
    }

    func testWakeCommandPreRollIncludesAsynchronousMicrophoneStartup() {
        let window = WhisperCommandListener.preRollWindow(elapsed: 1.2, captured: 0.1)
        XCTAssertEqual(window.duration, 1.9, accuracy: 0.0001)
        XCTAssertEqual(window.duplicateSamples, 1600)
        XCTAssertEqual(WhisperCommandListener.preRollWindow(elapsed: 30, captured: 0).duration, 8)
    }

}
