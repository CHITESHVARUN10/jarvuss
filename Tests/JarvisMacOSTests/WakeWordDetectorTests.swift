import AVFoundation
import XCTest
@testable import JarvisMacOS

/// Scripted engine: records every frame it sees, detects on a chosen call.
private final class RecordingEngine: WakeWordEngine {
    var isEnabled: Bool { true }
    let sampleRate: Double
    let frameLength: Int
    private(set) var processedFrames: [[Int16]] = []
    private(set) var processedCount = 0
    var detectOnCall: Int?

    init(frameLength: Int = 512, sampleRate: Double = 16_000) {
        self.frameLength = frameLength
        self.sampleRate = sampleRate
    }

    func process(frame: [Int16]) -> Bool {
        processedFrames.append(frame)
        processedCount += 1
        if let detectOnCall, processedCount == detectOnCall { return true }
        return false
    }
}

final class WakeWordDetectorTests: XCTestCase {

    // MARK: - MicManager resampler (the pre-roll's DSP)

    func testResample48kTo16kLength() {
        let input = (0..<48_000).map { Float(sin(Double($0) * 0.01)) }
        let output = MicManager.resampleLinear(input, from: 48_000, to: 16_000)
        // 1 s of 48 kHz → 1 s of 16 kHz, exact by construction.
        XCTAssertEqual(output.count, 16_000)
    }

    func testResamplePreservesLowFrequencyShape() {
        // A slow ramp must survive linear interpolation: first/mid/last track.
        let input = (0..<9_600).map { Float($0) / 9_600 }
        let output = MicManager.resampleLinear(input, from: 48_000, to: 16_000)
        XCTAssertEqual(Double(output.first!), 0.0, accuracy: 0.001)
        XCTAssertEqual(Double(output.last!), Double(input.last!), accuracy: 0.01)
    }

    func testResampleNoopAtSameRate() {
        let input: [Float] = [0.1, 0.2, 0.3]
        let output = MicManager.resampleLinear(input, from: 16_000, to: 16_000)
        XCTAssertEqual(output, input)
    }

    // MARK: - Frame alignment (Porcupine requires exact frame sizes)

    func testFramesAreExactLengthAndCarryOverBetweenBuffers() {
        let engine = RecordingEngine(frameLength: 512, sampleRate: 16_000)
        let detector = WakeWordDetector(engine: engine)
        let buffer = Self.makeBuffer(frames: 4_096, sampleRate: 48_000)

        detector.ingest(buffer: buffer)
        // 4096 @ 48k → 1365 @ 16k → two full 512 frames, 341 held over.
        XCTAssertEqual(engine.processedCount, 2)
        XCTAssertTrue(engine.processedFrames.allSatisfy { $0.count == 512 })

        // A second buffer must CONTINUE the remainder, not realign:
        // 341 + 1365 = 1706 → THREE frames (1706 / 512 = 3.33), whereas a
        // realigning implementation would only produce 2 (1365 / 512).
        detector.ingest(buffer: buffer)
        XCTAssertEqual(engine.processedCount, 5)
        XCTAssertTrue(engine.processedFrames.allSatisfy { $0.count == 512 })

        // Long-run invariant: 170 + 1365 = 1535 → 2 frames, 511 held back —
        // a partial frame is never emitted early.
        detector.ingest(buffer: buffer)
        XCTAssertEqual(engine.processedCount, 7)
        XCTAssertTrue(engine.processedFrames.allSatisfy { $0.count == 512 })
    }

    func testInt16ConversionClampsInsteadOfWrapping() {
        let engine = RecordingEngine(frameLength: 512, sampleRate: 16_000)
        let detector = WakeWordDetector(engine: engine)
        // Full-scale + out-of-range values: must clamp, never wrap to -32768.
        let buffer = Self.makeBuffer(frames: 512, sampleRate: 16_000, value: 2.5)

        detector.ingest(buffer: buffer)
        XCTAssertGreaterThanOrEqual(engine.processedCount, 1)
        XCTAssertTrue(engine.processedFrames[0].allSatisfy { $0 == 32_767 })
    }

    func testDetectionFiresCallbackOnceAndRespectsCooldown() {
        let engine = RecordingEngine(frameLength: 512, sampleRate: 16_000)
        engine.detectOnCall = 1
        let detector = WakeWordDetector(engine: engine)

        let fired = expectation(description: "detection callback")
        detector.onDetection = { fired.fulfill() }

        let buffer = Self.makeBuffer(frames: 4_096, sampleRate: 16_000)
        detector.ingest(buffer: buffer)
        wait(for: [fired], timeout: 2.0)

        // Cooldown: a second detection inside the window does not re-fire.
        let refire = expectation(description: "no refire")
        refire.isInverted = true
        engine.detectOnCall = engine.processedCount + 1
        detector.ingest(buffer: buffer)
        wait(for: [refire], timeout: 0.5)
    }

    func testInertEngineNeverProcesses() {
        let detector = WakeWordDetector(engine: NilWakeWordEngine())
        XCTAssertFalse(detector.isEnabled)
        // Must not crash and must not call anything.
        detector.onDetection = { XCTFail("inert detector fired") }
        detector.ingest(buffer: Self.makeBuffer(frames: 4_096, sampleRate: 48_000))
    }

    // MARK: - Helpers

    private static func makeBuffer(frames: Int, sampleRate: Double, value: Float = 0.25) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        for index in 0..<frames {
            channel[index] = value
        }
        return buffer
    }
}
