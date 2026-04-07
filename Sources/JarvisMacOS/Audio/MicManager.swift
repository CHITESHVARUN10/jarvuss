import Foundation
import AVFoundation

enum MicManagerError: LocalizedError {
    case permissionDenied
    case missingUsageDescription
    case insufficientAudio

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Enable it in System Settings > Privacy & Security > Microphone."
        case .missingUsageDescription:
            return "Missing `NSMicrophoneUsageDescription` in app Info.plist. Launch as an app bundle with this key."
        case .insufficientAudio:
            return "Not enough recent microphone audio collected yet."
        }
    }
}

final class MicManager {
    private let audioEngine = AVAudioEngine()
    private var isTapInstalled = false
    private var onLevelUpdate: ((Float) -> Void)?
    private var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?
    private let recentAudioQueue = DispatchQueue(label: "jarvis.mic.recent-audio")
    private var recentSamples: [Float] = []
    private var recentSampleRate: Double = 16_000
    private let maxBufferedSeconds: Double = 8.0

    private(set) var isListening = false
    var voiceDetectionThresholdDB: Float = -35.0

    func requestPermission() async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            return false
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func startListening(
        onLevelUpdate: @escaping (Float) -> Void,
        onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil
    ) throws {
        guard !isListening else { return }

        self.onLevelUpdate = onLevelUpdate
        self.onAudioBuffer = onAudioBuffer
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        if !isTapInstalled {
            inputNode.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let dbLevel = Self.rmsToDecibels(from: buffer)
                self.onLevelUpdate?(dbLevel)
                self.onAudioBuffer?(buffer)
                self.captureRecentSamples(from: buffer, sampleRate: format.sampleRate)
            }
            isTapInstalled = true
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    func stopListening() {
        guard isListening || isTapInstalled else { return }
        audioEngine.stop()

        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }

        onAudioBuffer = nil

        isListening = false
    }

    func startListeningWithPermission(
        onLevelUpdate: @escaping (Float) -> Void,
        onAudioBuffer: ((AVAudioPCMBuffer) -> Void)? = nil
    ) async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            throw MicManagerError.missingUsageDescription
        }

        let granted = await requestPermission()
        guard granted else {
            throw MicManagerError.permissionDenied
        }
        try startListening(onLevelUpdate: onLevelUpdate, onAudioBuffer: onAudioBuffer)
    }

    func isVoiceLikelyPresent(decibelLevel: Float) -> Bool {
        decibelLevel > voiceDetectionThresholdDB
    }

    func exportRecentAudioSample(durationSeconds: Double = 2.0) throws -> URL {
        let exported: (samples: [Float], sampleRate: Double) = recentAudioQueue.sync {
            let sampleRate = max(recentSampleRate, 8_000)
            let desiredCount = Int(sampleRate * durationSeconds)
            let clipped = desiredCount > 0 && recentSamples.count > desiredCount
                ? Array(recentSamples.suffix(desiredCount))
                : recentSamples
            return (clipped, sampleRate)
        }

        guard !exported.samples.isEmpty else {
            throw MicManagerError.insufficientAudio
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-voice-sample-\(UUID().uuidString).wav")

        try writeWav(samples: exported.samples, sampleRate: exported.sampleRate, to: tempURL)
        return tempURL
    }

    deinit {
        stopListening()
    }

    private static func rmsToDecibels(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160.0 }
        let channel = channels[0]
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return -160.0 }

        var squareSum: Float = 0.0
        for sampleIndex in 0..<frames {
            let sample = channel[sampleIndex]
            squareSum += sample * sample
        }

        let meanSquare = squareSum / Float(frames)
        let rms = sqrt(max(meanSquare, Float.leastNonzeroMagnitude))
        return 20.0 * log10(rms)
    }

    private func captureRecentSamples(from buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let channels = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channel = channels[0]
        let slice = Array(UnsafeBufferPointer(start: channel, count: frameLength))

        recentAudioQueue.async {
            self.recentSampleRate = sampleRate
            self.recentSamples.append(contentsOf: slice)

            let maxCount = Int(sampleRate * self.maxBufferedSeconds)
            if self.recentSamples.count > maxCount {
                self.recentSamples.removeFirst(self.recentSamples.count - maxCount)
            }
        }
    }

    private func writeWav(samples: [Float], sampleRate: Double, to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw MicManagerError.insufficientAudio
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channel = buffer.floatChannelData?[0] else {
            throw MicManagerError.insufficientAudio
        }

        for index in 0..<samples.count {
            channel[index] = samples[index]
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }
}
