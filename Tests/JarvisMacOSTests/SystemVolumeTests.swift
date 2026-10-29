import XCTest
@testable import JarvisMacOS

final class SystemVolumeTests: XCTestCase {
    func testExactSpokenAmountsAndAbsoluteVersusRelativeSemantics() {
        let cases: [(String, VolumeAction)] = [
            ("increase the volume by twenty five percent", .increase(by: 25)),
            ("decrease sound by 17%", .decrease(by: 17)),
            ("set system volume to forty-two percent", .setLevel(42)),
            ("increase volume to 60 percent", .setLevel(60)),
            ("decrease audio to twenty percent", .setLevel(20)),
            ("volume up by 35", .increase(by: 35)),
            ("turn the volume down by 12 percentage points", .decrease(by: 12)),
            ("turn up the sound", .increase(by: 10)),
            ("make it quieter", .decrease(by: 10)),
            ("Jarvis, could you set the volume to one hundred percent please?", .setLevel(100)),
            ("set volume to zero", .setLevel(0)),
            ("increase volume by zero percent", .increase(by: 0)),
            ("mute system sound", .mute), ("unmute audio", .unmute)
        ]
        for (text, action) in cases {
            XCTAssertEqual(SystemVolumeParser.route(text), .volumeControl(action), text)
            XCTAssertEqual(FastPathRouter.route(text), .execute([.volumeControl(action)]), text)
        }
        XCTAssertEqual(SystemVolumeParser.number("ninety nine"), 99)
        XCTAssertEqual(SystemVolumeParser.number("twenty-one"), 21)
        XCTAssertNil(SystemVolumeParser.number("twenty one two"))
    }

    func testParserDoesNotSwallowOtherFeaturesOrMalformedAmounts() {
        for text in ["increase volume by -10", "set volume to 101 percent", "set volume to 1.5",
                     "volume up by 999999999999999999999999", "increase volume by twenty five bananas",
                     "don't mute", "do not increase the volume", "explain how to increase volume",
                     "play Volume Up", "set Spotify volume to 30", "increase microphone volume",
                     "turn up brightness", "volume up in Spotify", "increase volume and open Safari",
                     "set volume to twenty and five", "increase volume by ten then decrease it"] {
            XCTAssertNil(SystemVolumeParser.route(text), text)
        }
    }

    func testNativeCommandsBypassInferenceInBothModes() async {
        let original = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        defer { if let original { setenv("JARVIS_RUST_PIPELINE", original, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") } }
        for mode in ["0", "1"] {
            setenv("JARVIS_RUST_PIPELINE", mode, 1)
            let planner = ActionPlanner(ollamaClient: NoVolumeLLM(), intentModelRouter: NoVolumeModel(), intentLog: IntentRouterLog(enabled: false))
            for text in ["increase the volume by twenty five percent", "volume up by 35", "mute system audio",
                         "set volume to forty two percent", "what is the current volume level"] {
                let plan = await planner.plan(from: text)
                XCTAssertEqual(plan, [SystemVolumeParser.route(text)!], text)
                XCTAssertNotNil(CommandValidator.validate(text), text)
            }
        }
    }

    func testLearnedMappingCannotOverwriteStandaloneAmountsAndRejectsInvalidChainNumbers() {
        XCTAssertEqual(IntentActionMapper.map([["name": "volume.up", "args": ["by": 10]]],
                                               sourceText: "increase volume by 25"), [.volumeControl(.increase(by: 25))])
        XCTAssertEqual(IntentActionMapper.map([["name": "volume.up", "args": ["by": 10]]],
                                               sourceText: "increase volume to 40"), [.volumeControl(.setLevel(40))])
        XCTAssertNil(IntentActionMapper.map([["name": "volume.mute", "args": [:]]], sourceText: "don't mute"))
        XCTAssertNil(IntentActionMapper.map([["name": "volume.unknown", "args": [:]]], sourceText: "mute"))
        for value in [true, -1, 101, 1.5, Double.nan, Double.infinity, "50"] as [Any] {
            XCTAssertNil(IntentActionMapper.map([["name": "volume.set", "args": ["level": value]]]))
        }
        XCTAssertEqual(IntentActionMapper.map([["name": "volume.down", "args": ["by": 20]]]), [.volumeControl(.decrease(by: 20))])
    }

    func testLiveDefaultOutputAndExternalVolumeChangesAreUsed() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.increase(by: 15)).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0.55, accuracy: 0.001)
        audio.allow(.virtualVolume, 0.2) // User changed volume outside Jarvis.
        XCTAssertTrue(controller.executeResult(.decrease(by: 5)).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0.15, accuracy: 0.001)
        audio.selected = audio.second
        audio.allow(.virtualVolume, 0.7)
        XCTAssertTrue(controller.executeResult(.decrease(by: 10)).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0.6, accuracy: 0.001)
        XCTAssertEqual(audio.writes.map(\.device), [42, 42, 99])
    }

    func testBoundariesAndIdempotentCommandsSucceedWithoutFallbacks() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.95)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.increase(by: 20)).success)
        XCTAssertEqual(audio.value(.virtualVolume), 1)
        XCTAssertTrue(controller.executeResult(.setLevel(100)).success)
        XCTAssertTrue(controller.executeResult(.increase(by: 10)).success)
        XCTAssertEqual(audio.writes.count, 1)
        XCTAssertTrue(controller.executeResult(.decrease(by: 100)).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0)
        XCTAssertTrue(controller.executeResult(.decrease(by: 10)).success)
        for amount in [Int.min, -1, 101, Int.max] {
            XCTAssertFalse(controller.executeResult(.increase(by: amount)).success)
            XCTAssertFalse(controller.executeResult(.setLevel(amount)).success)
        }
        XCTAssertEqual(audio.writes.count, 2)
    }

    func testMainScalarAndChannelOnlyDevicesPreserveBalance() {
        let audio = FakeSystemAudio()
        audio.allow(.volume(0), 0.3)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.setLevel(40)).success)
        XCTAssertEqual(audio.value(.volume(0)), 0.4, accuracy: 0.001)
        audio.values[42] = [:]; audio.writable[42] = []
        audio.allow(.volume(1), 0.4); audio.allow(.volume(2), 0.2)
        XCTAssertTrue(controller.executeResult(.increase(by: 20)).success)
        XCTAssertEqual(audio.value(.volume(1)), 0.6, accuracy: 0.001)
        XCTAssertEqual(audio.value(.volume(2)), 0.3, accuracy: 0.001)
    }

    func testHardwareMuteIsIdempotentAndKeepsVolume() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.37); audio.allow(.mute(0), 0)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.mute).success)
        XCTAssertTrue(controller.executeResult(.mute).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0.37)
        XCTAssertEqual(audio.writes.count, 1)
        XCTAssertTrue(controller.readResult().message.contains("muted"))
        XCTAssertTrue(controller.executeResult(.unmute).success)
        XCTAssertEqual(audio.value(.mute(0)), 0)
        XCTAssertEqual(audio.value(.virtualVolume), 0.37)
    }

    func testFallbackMuteRestoresOriginalPerChannelLevelsAfterRepeatedMute() {
        let audio = FakeSystemAudio()
        audio.allow(.volume(1), 0.4); audio.allow(.volume(2), 0.2)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.mute).success)
        XCTAssertTrue(controller.executeResult(.mute).success)
        XCTAssertEqual(audio.value(.volume(1)), 0)
        XCTAssertEqual(audio.value(.volume(2)), 0)
        XCTAssertTrue(controller.executeResult(.unmute).success)
        XCTAssertEqual(audio.value(.volume(1)), 0.4)
        XCTAssertEqual(audio.value(.volume(2)), 0.2)
    }

    func testUnmuteNeverRestoresAnotherDevicesLevelOrInventsOne() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.65)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.mute).success)
        audio.selected = audio.second; audio.allow(.virtualVolume, 0)
        XCTAssertFalse(controller.executeResult(.unmute).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0)
        audio.selected = audio.first
        XCTAssertTrue(controller.executeResult(.unmute).success)
        XCTAssertEqual(audio.value(.virtualVolume), 0.65)
        audio.allow(.virtualVolume, 0)
        XCTAssertFalse(make(audio).executeResult(.unmute).success)
    }

    func testChangingVolumeUnmutesAndReturnsActualClampedLevel() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.95); audio.allow(.mute(0), 1)
        let result = make(audio).executeResult(.increase(by: 20))
        XCTAssertTrue(result.success)
        XCTAssertEqual(audio.value(.mute(0)), 0)
        XCTAssertTrue(result.message.contains("100%"))
        XCTAssertFalse(result.message.contains("20%"))
    }

    func testReadonlyMutePreflightPreventsSilentGainChanges() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4); audio.allow(.mute(0), 1, writable: false)
        XCTAssertFalse(make(audio).executeResult(.increase(by: 10)).success)
        XCTAssertTrue(audio.writes.isEmpty)
    }

    func testUnsupportedDigitalReadonlyAndAggregateOutputsNeverWrite() {
        let audio = FakeSystemAudio()
        let controller = make(audio)
        XCTAssertFalse(controller.executeResult(.increase(by: 10)).success)
        audio.allow(.virtualVolume, 0.5, writable: false)
        XCTAssertTrue(controller.readResult().success)
        XCTAssertFalse(controller.executeResult(.decrease(by: 10)).success)
        audio.selected = SystemAudioOutput(id: 42, uid: "aggregate", name: "Multi-output", isAggregate: true)
        audio.allow(.virtualVolume, 0.5)
        XCTAssertFalse(controller.executeResult(.setLevel(30)).success)
        XCTAssertFalse(controller.readResult().success)
        XCTAssertTrue(audio.writes.isEmpty)
    }

    func testAllChannelsMustBeWritableBeforeAnyChannelIsChanged() {
        let audio = FakeSystemAudio()
        audio.allow(.volume(1), 0.5); audio.allow(.volume(2), 0.5, writable: false)
        XCTAssertFalse(make(audio).executeResult(.setLevel(30)).success)
        XCTAssertTrue(audio.writes.isEmpty)
    }

    func testNoOutputAndInvalidReadingsFailWithoutWriting() {
        let audio = FakeSystemAudio()
        audio.noOutput = true
        XCTAssertFalse(make(audio).executeResult(.mute).success)
        audio.noOutput = false
        for value in [Float.nan, .infinity, -0.5, 1.5] {
            audio.allow(.virtualVolume, value)
            XCTAssertFalse(make(audio).executeResult(.increase(by: 10)).success)
        }
        XCTAssertTrue(audio.writes.isEmpty)
    }

    func testDeviceIDReuseOrRouteChangeStopsBeforeWriting() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4)
        audio.onDefaultRead = { count in
            if count > 1 { audio.selected = SystemAudioOutput(id: 42, uid: "reused-id", name: "New device", isAggregate: false) }
        }
        XCTAssertFalse(make(audio).executeResult(.setLevel(30)).success)
        XCTAssertTrue(audio.writes.isEmpty)
    }

    func testMidChannelRouteChangeReportsPartialFailureWithoutTouchingNewOutput() {
        let audio = FakeSystemAudio()
        audio.allow(.volume(1), 0.4); audio.allow(.volume(2), 0.4)
        audio.onWrite = { audio.selected = audio.second }
        let result = make(audio).executeResult(.setLevel(20))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("may have changed"))
        XCTAssertEqual(audio.writes.count, 1)
        XCTAssertEqual(audio.writes.first?.device, 42)
        XCTAssertEqual(audio.values[42]?[.volume(2)], 0.4)
    }

    func testRejectedAndUnconfirmedWritesAreNotReportedAsSuccess() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4); audio.failWrites = true
        let controller = make(audio)
        XCTAssertFalse(controller.executeResult(.setLevel(70)).success)
        audio.failWrites = false; audio.ignoreWrites = true
        let result = controller.executeResult(.setLevel(70))
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.message.contains("did not confirm"))
        XCTAssertEqual(audio.value(.virtualVolume), 0.4)
    }

    func testSmallIgnoredChangesStillFailAndZeroDeltaDoesNotUnmute() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4); audio.allow(.mute(0), 1)
        let controller = make(audio)
        XCTAssertTrue(controller.executeResult(.increase(by: 0)).success)
        XCTAssertEqual(audio.value(.mute(0)), 1)
        XCTAssertTrue(audio.writes.isEmpty)
        audio.ignoreWrites = true
        XCTAssertFalse(controller.executeResult(.increase(by: 1)).success)
    }

    func testPartialMuteChannelsCannotPretendToBeAnUnmutedDevice() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4); audio.allow(.mute(1), 1)
        let controller = make(audio)
        XCTAssertFalse(controller.executeResult(.unmute).success)
        XCTAssertFalse(controller.executeResult(.increase(by: 10)).success)
        XCTAssertTrue(audio.writes.isEmpty)
    }

    func testDelayedReadbackIsBoundedAndCanConfirm() {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4); audio.ignoreWrites = true
        var waits = 0
        let controller = VolumeController(audio: audio, waitForReadback: {
            waits += 1
            if waits == 2 { audio.allow(.virtualVolume, 0.7) }
        })
        XCTAssertTrue(controller.executeResult(.setLevel(70)).success)
        XCTAssertEqual(waits, 2)
    }

    @MainActor
    func testAsyncExecutorKeepsHALCallsOffTheMainThread() async {
        let audio = FakeSystemAudio()
        audio.allow(.virtualVolume, 0.4)
        audio.onDefaultRead = { _ in XCTAssertFalse(Thread.isMainThread) }
        let controller = make(audio)
        let changed = await controller.perform(.increase(by: 10))
        XCTAssertTrue(changed.success)
        let read = await controller.perform(nil)
        XCTAssertTrue(read.success)
        XCTAssertTrue(read.message.contains("50%"))
    }

    @MainActor
    func testFeedbackUsesObservedResultInsteadOfRequestedDelta() {
        let action = PlannedAction.volumeControl(.increase(by: 20))
        let result = ActionResult(action: action, success: true, message: "Speakers: volume 100%.")
        XCTAssertEqual(ResponseEngine.shared.naturalResponse(for: action, result: result), result.message)
    }

    private func make(_ audio: FakeSystemAudio) -> VolumeController {
        VolumeController(audio: audio, waitForReadback: {})
    }
}

private final class FakeSystemAudio: SystemAudioAccess {
    struct Write { let device: UInt32; let property: SystemAudioProperty; let value: Float }
    let first = SystemAudioOutput(id: 42, uid: "built-in", name: "Speakers", isAggregate: false)
    let second = SystemAudioOutput(id: 99, uid: "headphones", name: "Headphones", isAggregate: false)
    lazy var selected = first
    var values: [UInt32: [SystemAudioProperty: Float]] = [:]
    var writable: [UInt32: Set<SystemAudioProperty>] = [:]
    var writes: [Write] = []
    var defaultReads = 0
    var noOutput = false
    var failWrites = false
    var ignoreWrites = false
    var onDefaultRead: ((Int) -> Void)?
    var onWrite: (() -> Void)?

    func allow(_ property: SystemAudioProperty, _ value: Float, writable enabled: Bool = true) {
        values[selected.id, default: [:]][property] = value
        if enabled { writable[selected.id, default: []].insert(property) }
        else { writable[selected.id, default: []].remove(property) }
    }
    func value(_ property: SystemAudioProperty) -> Float { values[selected.id]?[property] ?? -999 }
    func defaultOutput() throws -> SystemAudioOutput {
        if noOutput { throw SystemAudioError(message: "No audio output.") }
        defaultReads += 1; onDefaultRead?(defaultReads)
        return selected
    }
    func outputChannelCount(_ device: SystemAudioOutput) throws -> Int { 2 }
    func isSettable(_ property: SystemAudioProperty, on device: SystemAudioOutput) -> Bool {
        writable[device.id]?.contains(property) == true
    }
    func read(_ property: SystemAudioProperty, on device: SystemAudioOutput) throws -> Float {
        guard let value = values[device.id]?[property] else { throw SystemAudioError(message: "Unsupported property.") }
        return value
    }
    func write(_ value: Float, to property: SystemAudioProperty, on device: SystemAudioOutput) throws {
        if failWrites { throw SystemAudioError(message: "Core Audio -1") }
        writes.append(Write(device: device.id, property: property, value: value))
        if !ignoreWrites { values[device.id, default: [:]][property] = value }
        onWrite?()
    }
}

private struct NoVolumeLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("Volume must route locally"); return "" }
}
private struct NoVolumeModel: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("Volume must not wait for inference"); return nil }
}
