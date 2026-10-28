import XCTest
@testable import JarvisMacOS

final class DisplaySafetyTests: XCTestCase {
    func testZeroNegativeAndExtremeHardwareRequestsKeepDisplayFloors() {
        for value in [Int.min, -100, 0, 1, 9, 10, 19, 20, 50, 100, 1000, Int.max] {
            XCTAssertTrue((10...100).contains(DisplaySafety.brightness(value)))
            XCTAssertTrue((20...100).contains(DisplaySafety.contrast(value)))
        }
        XCTAssertEqual(DisplaySafety.safeVCPValue(0x10, 0), 10)
        XCTAssertEqual(DisplaySafety.safeVCPValue(0x12, 0), 20)
        XCTAssertEqual(DisplaySafety.safeVCPValue(0x62, 0), 0, "Muting audio must remain available")
    }

    func testRepeatedRelativeDimmingAndExtremeDeltasCannotCrossTheFloorsOrOverflow() {
        var brightness = 60, contrast = 50
        for _ in 0..<30 {
            brightness = DisplaySafety.adjustedBrightness(current: brightness, delta: 10, increasing: false)
            contrast = DisplaySafety.adjustedContrast(current: contrast, delta: 10, increasing: false)
        }
        XCTAssertEqual(brightness, 10)
        XCTAssertEqual(contrast, 20)
        XCTAssertEqual(DisplaySafety.adjustedBrightness(current: Int.max, delta: Int.max, increasing: true), 100)
        XCTAssertEqual(DisplaySafety.adjustedContrast(current: Int.min, delta: Int.max, increasing: false), 20)
    }

    func testSpokenAbsoluteResponsesReportTheAppliedSafetyFloor() {
        XCTAssertEqual(DisplayAction.setBrightness(0).responseText, "Brightness set to 10 percent")
        XCTAssertEqual(DisplayAction.setContrast(0).responseText, "Contrast set to 20 percent")
    }

    func testSoftwareAndBuiltInFloorsRejectNonfiniteAndBlackoutValues() {
        for value: Float in [-1, 0, 0.01, 0.5, 1, 100, .nan, .infinity, -.infinity] {
            XCTAssertTrue((0.1...1).contains(DisplaySafety.hardwareBrightness(value)))
            XCTAssertTrue((0.2...1).contains(DisplaySafety.softwareFactor(value)))
        }
        XCTAssertEqual(DisplaySafety.hardwareBrightness(0), 0.1)
        XCTAssertEqual(DisplaySafety.softwareFactor(0), 0.2)
    }

    func testAlreadyBlackOrCorruptGammaTablesCannotBecomeTheDimmingBaseline() {
        XCTAssertFalse(SoftwareDimmingController.usableBaseline([[0, 0], [0, 0], [0, 0]]))
        XCTAssertFalse(SoftwareDimmingController.usableBaseline([[0, .nan], [0, 1], [0, 1]]))
        XCTAssertTrue(SoftwareDimmingController.usableBaseline([[0, 0.5, 1], [0, 0.5, 1], [0, 0.5, 1]]))
    }

    func testOnlyWholeSafeRecoveryPhrasesAreAccepted() {
        for text in ["Restore my display", "Jarvis, restore my display!", "restore my screen.", "screen rescue", "Restore display"] {
            XCTAssertTrue(DisplaySafety.isRecoveryRequest(text), text)
        }
        for text in ["don't restore my display", "please don't restore display", "restore my display and open Terminal",
                     "restore my display then delete files", "write the phrase restore my display", "screen rescue open safari", ""] {
            XCTAssertFalse(DisplaySafety.isRecoveryRequest(text), text)
        }
    }

    func testRescueResetsGammaAndAttemptsEveryMonitorEvenAfterAWriteFails() {
        var events: [String] = []
        let operations = DisplayRecoveryOperations(resetGamma: { events.append("gamma") },
            builtIn: { events.append("builtin"); return true }, externalIDs: { [2, 1, 1] },
            brightness: { id, value in events.append("brightness-\(id)-\(value)"); return id != 1 },
            contrast: { id, value in events.append("contrast-\(id)-\(value)"); return true })
        let result = operations.perform()
        XCTAssertEqual(events, ["gamma", "builtin", "brightness-1-60", "contrast-1-50", "brightness-2-60", "contrast-2-50"])
        XCTAssertEqual(result.targets, 3)
        XCTAssertEqual(result.failures, 1)
        XCTAssertFalse(result.complete)
    }

    func testMissingHardwareDoesNotClaimConfirmedRecovery() {
        let report = DisplayRecoveryOperations(resetGamma: {}, builtIn: { nil }, externalIDs: { [] },
            brightness: { _, _ in XCTFail("No connected displays"); return false },
            contrast: { _, _ in XCTFail("No connected displays"); return false }).perform()
        XCTAssertFalse(report.complete)
    }

    @MainActor
    func testRecoveryWithoutBetterDisplaySkipsIntegrationAndUsesNativeControls() async {
        let helper = BetterDisplayRecovery(isRunning: { false }, request: { _ in
            XCTFail("An absent or stopped BetterDisplay must not receive requests or start timeout waits")
            return false
        })
        let better = await helper.restore(needsContrast: true)
        XCTAssertNil(better, "Not installed/not running is skipped, not failed")
        var events: [String] = []
        let report = DisplayRecoveryOperations(resetGamma: { events.append("gamma") },
            builtIn: { events.append("builtin"); return true }, externalIDs: { [2] },
            brightness: { _, level in events.append("brightness-\(level)"); return true },
            contrast: { _, level in events.append("contrast-\(level)"); return true }).perform()
        XCTAssertEqual(events, ["gamma", "builtin", "brightness-60", "contrast-50"])
        XCTAssertTrue(report.complete)
        XCTAssertTrue(report.status(betterDisplay: better).hasPrefix("Display restored"))
        XCTAssertFalse(report.status(betterDisplay: better).contains("BetterDisplay"))
    }

    @MainActor
    func testRunningBetterDisplayOnBuiltInOnlySkipsExternalContrast() async {
        var requests: [[String: String]] = []
        let helper = BetterDisplayRecovery(isRunning: { true }, request: { parameters in
            requests.append(parameters)
            return true
        })
        let result = await helper.restore(needsContrast: false)
        XCTAssertEqual(result, true)
        XCTAssertEqual(requests, BetterDisplayRecovery.steps.filter { $0["hardwareContrast"] == nil })
    }

    @MainActor
    func testUnresponsiveOptionalIntegrationStopsAfterTimeoutAndReportsUnconfirmed() async {
        var requests = 0
        let helper = BetterDisplayRecovery(isRunning: { true }, request: { _ in
            requests += 1
            return nil // Simulated notification timeout; no real app or display access.
        })
        let result = await helper.restore(needsContrast: true)
        XCTAssertEqual(result, false)
        XCTAssertEqual(requests, 1)
        let report = DisplayRecoveryReport(targets: 1, failures: 0)
        XCTAssertTrue(report.status(betterDisplay: result).contains("BetterDisplay did not confirm"))
        XCTAssertFalse(report.status(betterDisplay: result).hasPrefix("Display restored"))
    }

    func testUnsupportedNativeControlsWithoutBetterDisplayDoNotSuggestInstallingIt() {
        let report = DisplayRecoveryReport(targets: 1, failures: 1)
        XCTAssertFalse(report.status(betterDisplay: nil).contains("BetterDisplay"))
        XCTAssertTrue(report.status(betterDisplay: nil).contains("could not be confirmed"))
    }

    @MainActor
    func testBetterDisplayRescueUsesAbsoluteLevelsWithoutFactoryResets() {
        let steps = BetterDisplayRecovery.steps
        XCTAssertTrue(steps.contains(["softwareBrightness": "1.0"]))
        XCTAssertTrue(steps.contains(["suspendImageAdjustments": "on"]))
        XCTAssertTrue(steps.contains(["brightness": "0.6"]))
        XCTAssertTrue(steps.contains(["hardwareContrast": "0.5"]))
        XCTAssertEqual(steps.count, 4)
    }
}

@MainActor
final class DisplayRecoveryEntryTests: XCTestCase {
    func testActionAndFinalLiveAndTypedRecoveryBypassVerificationWithoutOtherCommands() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var recoveries = 0
        let app = AppState(logger: Logger(logURL: folder.appendingPathComponent("commands.log")), dbManager: DBManager(configuration: [:]),
            statsRecorder: StatsRecorder(buffer: StatsBufferStore(fileURL: folder.appendingPathComponent("stats.json")), retryInterval: 0),
            intentLog: IntentRouterLog(enabled: false), activateServices: false,
            emergencyDisplayRecovery: { recoveries += 1 })
        XCTAssertFalse(app.voiceProfileReady)
        let previousVerification = app.actionPillRequiresVerify
        app.actionPillRequiresVerify = true
        defer { app.actionPillRequiresVerify = previousVerification }
        app.handleActionPillCommand("Restore my display!")
        XCTAssertEqual(recoveries, 1)
        XCTAssertFalse(app.commandQueue.isExecuting)
        app.handleTranscript("Jarvis restore my display", isFinal: false)
        XCTAssertEqual(recoveries, 1, "A partial transcript must not execute")
        app.handleTranscript("Jarvis restore my display", isFinal: true)
        XCTAssertEqual(recoveries, 2)
        app.commandInput = "screen rescue"
        app.executeTypedCommand()
        XCTAssertEqual(recoveries, 3)
        XCTAssertFalse(app.recoverDisplayIfRequested("restore my display and open Safari"))
        XCTAssertEqual(recoveries, 3)
        app.voiceVerificationStatus = ""
        app.handleActionPillCommand("restore my display and open Safari")
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(recoveries, 3)
        XCTAssertEqual(app.voiceVerificationStatus, "No command audio available", "Compound commands must still require recorded verification audio")
    }

    func testDictationOfTheSafeWordRemainsTextAndNeverRoutesAsACommand() {
        var commands = 0
        let router = STTRouter(currentPhase: { .Ready }, cancelCapture: {}, startModal: { _ in })
        router.onCommandTranscript = { _ in commands += 1 }
        router.onActionTranscript = { _ in commands += 1 }
        XCTAssertTrue(router.claimForPill())
        XCTAssertEqual(router.routeTranscript("Restore my display"), "Restore my display")
        XCTAssertEqual(commands, 0)
    }
}
