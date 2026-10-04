import AVFoundation
import Foundation

/// Acoustic wake-word detection ("Jarvis"), fed by the MicManager audio tap.
///
/// Why this exists: the VAD is reactive — it fires 250–400 ms after speech
/// starts, so the wake word's first syllables only survive because the
/// pre-roll (WhisperCommandListener) splices them back in from the mic ring.
/// A real-time acoustic detector removes the dependency on the wake word
/// surviving transcription at all: on detection the app anchors the pre-roll
/// precisely, confirms with a cue, and accepts the following utterance as the
/// command even if "Jarvis" never appears in the transcript.
///
/// ENGINE STATUS — the Porcupine binding below is compiled only when the
/// framework is present (`#if canImport(Porcupine)`), so this ships INERT:
/// no SDK, no AccessKey, no behavior change. To enable it:
///   1. Vendor the macOS Porcupine framework (Picovoice's SwiftPM package at
///      github.com/Picovoice/porcupine is iOS-only — use the macOS
///      xcframework from their releases, or the CocoaPods `Porcupine-iOS`
///      pod which does declare macOS support).
///   2. Provide an AccessKey: `PORCUPINE_ACCESS_KEY` env var or the
///      `jarvis.wakeWord.porcupineKey` UserDefaults key. Never commit it.
/// License: Porcupine is free for personal use; commercial use requires a
/// paid Picovoice license — openWakeWord is the license-clean alternative.
final class WakeWordDetector {
    static let shared = WakeWordDetector()

    /// Fired on the MAIN queue when the wake word is heard.
    var onDetection: (() -> Void)?

    private let engine: WakeWordEngine
    private let lock = NSLock()
    /// Int16 carry-over between tap callbacks: engines require exact fixed
    /// frame sizes, so a remainder is held rather than dropping/aligning.
    private var frameRemainder: [Int16] = []
    /// Throttle: one detection callback per this window (engines can fire
    /// repeatedly on the same utterance).
    private var lastDetectionAt = Date.distantPast
    private let detectionCooldown: TimeInterval = 2.0

    var isEnabled: Bool { engine.isEnabled }

    private convenience init() {
        self.init(engine: Self.makeEngine())
    }

    /// Test/composition seam: inject a scripted engine.
    init(engine: WakeWordEngine) {
        self.engine = engine
        if engine.isEnabled {
            NSLog(
                "[Jarvis][Wake] Acoustic detector active (%@, %d-sample frames @ %.0f Hz)",
                String(describing: type(of: engine)), engine.frameLength, engine.sampleRate)
        } else {
            NSLog("[Jarvis][Wake] Acoustic detector inert — no engine/AccessKey; wake path uses pre-roll only")
        }
    }

    private static func makeEngine() -> WakeWordEngine {
        #if canImport(Porcupine)
        if let key = Self.accessKey, let porcupine = PorcupineEngine(accessKey: key) {
            return porcupine
        }
        #endif
        return NilWakeWordEngine()
    }

    /// AccessKey lookup: env first (dev), then UserDefaults (settings).
    static var accessKey: String? {
        if let env = ProcessInfo.processInfo.environment["PORCUPINE_ACCESS_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return env.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let stored = UserDefaults.standard.string(forKey: "jarvis.wakeWord.porcupineKey"),
           !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return stored.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Called from the audio tap thread with a native-rate buffer. Converts
    /// Float32 mono → engine-rate Int16 and re-chunks into exact frames.
    func ingest(buffer: AVAudioPCMBuffer) {
        guard engine.isEnabled, let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let native = Array(UnsafeBufferPointer(start: channels[0], count: frameCount))
        let nativeRate = buffer.format.sampleRate
        let rate = engine.sampleRate
        let engineSamples: [Float] = nativeRate == rate
            ? native
            : MicManager.resampleLinear(native, from: nativeRate, to: rate)

        lock.lock()
        frameRemainder.append(contentsOf: engineSamples.map {
            Int16(clamping: Int($0 * 32767.0))
        })

        var detected = false
        let frameLength = engine.frameLength
        while frameRemainder.count >= frameLength {
            let frame = Array(frameRemainder[0..<frameLength])
            frameRemainder.removeFirst(frameLength)
            if engine.process(frame: frame) {
                detected = true
                // The current frame is consumed either way; stop scanning so
                // one utterance yields at most one detection callback.
                break
            }
        }
        lock.unlock()

        guard detected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastDetectionAt) > detectionCooldown else { return }
        lastDetectionAt = now
        DispatchQueue.main.async { [weak self] in
            self?.onDetection?()
        }
    }
}

// MARK: - Engines

/// Feed a native-rate mic buffer in; get a detection out. Engines are fed
/// exact `frameLength` frames at `sampleRate` — the detector owns both the
/// resampling and the frame alignment.
protocol WakeWordEngine: AnyObject {
    var isEnabled: Bool { get }
    var sampleRate: Double { get }
    var frameLength: Int { get }
    func process(frame: [Int16]) -> Bool
}

/// The default engine: nothing to detect with, everything else unchanged.
final class NilWakeWordEngine: WakeWordEngine {
    var isEnabled: Bool { false }
    var sampleRate: Double { 16_000 }
    var frameLength: Int { 512 }
    func process(frame: [Int16]) -> Bool { false }
}

#if canImport(Porcupine)
import Porcupine

/// Picovoice Porcupine, driven frame-by-frame through the LOW-LEVEL class —
/// deliberately not `PorcupineManager`, which runs its own AVAudioEngine and
/// would fight MicManager for the input device. "jarvis" is a built-in
/// keyword, so no custom model training is needed.
final class PorcupineEngine: WakeWordEngine {
    private let porcupine: Porcupine
    let sampleRate: Double
    let frameLength: Int
    let keywordIndex: Int32

    var isEnabled: Bool { true }

    init?(accessKey: String) {
        guard !accessKey.isEmpty else { return nil }
        do {
            let instance = try Porcupine(
                accessKey: accessKey,
                keywords: [Porcupine.BuiltInKeyword.jarvis],
                modelPath: nil)
            self.porcupine = instance
            self.sampleRate = Double(instance.sampleRate)
            self.frameLength = Int(instance.frameLength)
            self.keywordIndex = 0
        } catch {
            NSLog("[Jarvis][Wake] Porcupine init failed: %@", String(describing: error))
            return nil
        }
    }

    func process(frame: [Int16]) -> Bool {
        do {
            let keyword = try porcupine.process(pcm: frame)
            return keyword == keywordIndex
        } catch {
            NSLog("[Jarvis][Wake] Porcupine process error: %@", String(describing: error))
            return false
        }
    }
}
#endif
