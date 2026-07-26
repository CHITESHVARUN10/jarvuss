import Foundation
import AVFoundation
import CoreAudio

final class AudioGainController {
    var onLog: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private let mainMixer: AVAudioMixerNode
    private let outputNode: AVAudioOutputNode
    private let queue = DispatchQueue(label: "com.jarvis.audio-gain", qos: .userInitiated)

    private var isRunning = false
    private var currentVolume: Float = 1.0

    init() {
        self.inputNode = engine.inputNode
        self.mainMixer = engine.mainMixerNode
        self.outputNode = engine.outputNode
    }

    @discardableResult
    func startIfNeeded() -> Bool {
        queue.sync {
            if isRunning { return true }

            guard validateBlackHoleRouting() else {
                emit("[AudioGain][ERROR] System audio not routed through BlackHole")
                emit("[AudioGain][ERROR] BlackHole not configured as system output")
                return false
            }

            let inputFormat = inputNode.inputFormat(forBus: 0)
            guard inputFormat.channelCount > 0 else {
                emit("[AudioGain][ERROR] Invalid input format for AudioGain pipeline")
                return false
            }

            engine.stop()
            inputNode.removeTap(onBus: 0)
            engine.disconnectNodeOutput(inputNode)
            engine.disconnectNodeOutput(mainMixer)

            engine.connect(inputNode, to: mainMixer, format: inputFormat)
            engine.connect(mainMixer, to: outputNode, format: mainMixer.outputFormat(forBus: 0))
            mainMixer.outputVolume = currentVolume

            do {
                engine.prepare()
                try engine.start()
                isRunning = true
                emit("[AudioGain] Pipeline started")
                return true
            } catch {
                emit("[AudioGain][ERROR] Failed to start pipeline: \(error.localizedDescription)")
                isRunning = false
                return false
            }
        }
    }

    func setVolume(_ percent: Int) -> Bool {
        let safe = max(0, min(100, percent))
        let value = Float(safe) / 100.0

        let started = startIfNeeded()
        guard started else { return false }

        queue.sync {
            currentVolume = value
            mainMixer.outputVolume = value
        }
        emit("[AudioGain] Volume set: \(value)")
        return true
    }

    func increase(by percent: Int) -> Bool {
        let delta = max(0, percent)
        let current = currentVolumeFactor()
        let target = Int(round(Double((current * 100.0) + Float(delta))))
        return setVolume(target)
    }

    func decrease(by percent: Int) -> Bool {
        let delta = max(0, percent)
        let current = currentVolumeFactor()
        let target = Int(round(Double((current * 100.0) - Float(delta))))
        return setVolume(target)
    }

    func currentVolumeFactor() -> Float {
        queue.sync { currentVolume }
    }

    private func validateBlackHoleRouting() -> Bool {
        let inputName = defaultDeviceName(isInput: true) ?? "Unknown"
        let outputName = defaultDeviceName(isInput: false) ?? "Unknown"

        let inputLabel = inputName.lowercased().contains("blackhole") ? "BlackHole" : inputName
        let outputLower = outputName.lowercased()
        let outputLabel = (outputLower.contains("hdmi") || outputLower.contains("display")) ? "HDMI" : outputName

        emit("[AudioGain] Input device: \(inputLabel)")
        emit("[AudioGain] Output device: \(outputLabel)")

        let hasBlackHoleInput = inputName.lowercased().contains("blackhole")
        let validOutputRoute = outputName.lowercased().contains("multi-output") || outputName.lowercased().contains("blackhole")

        if !hasBlackHoleInput {
            emit("[Volume][ERROR] System not routed through BlackHole")
            return false
        }

        if !validOutputRoute {
            emit("[Volume][ERROR] Invalid audio routing configuration")
            return false
        }

        return true
    }

    private func defaultDeviceName(isInput: Bool) -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let selector = isInput ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr else { return nil }

        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let nameStatus = AudioObjectGetPropertyData(
            deviceID,
            &nameAddress,
            0,
            nil,
            &nameSize,
            &nameRef
        )

        guard nameStatus == noErr else { return nil }
        return nameRef?.takeUnretainedValue() as String?
    }

    private func emit(_ message: String) {
        if let onLog {
            onLog(message)
        } else {
            print(message)
        }
    }
}
