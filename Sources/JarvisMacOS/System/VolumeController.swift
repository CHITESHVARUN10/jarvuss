import Foundation
import CoreAudio

enum AudioDeviceType: CustomStringConvertible {
    case hdmi
    case nonHDMI
    case unknown

    var description: String {
        switch self {
        case .hdmi: return "HDMI"
        case .nonHDMI: return "Non-HDMI"
        case .unknown: return "Unknown"
        }
    }
}

final class VolumeController {
    private let coreAudio = CoreAudioVolumeController()
    private let monitorVolume = MonitorVolumeController()
    private let audioGain = AudioGainController()

    var onLog: ((String) -> Void)? {
        didSet {
            coreAudio.onLog = onLog
            monitorVolume.onLog = onLog
            audioGain.onLog = onLog
        }
    }

    private(set) var currentVolume: Float = 0.5
    private var preMuteVolume: Float = 0.5
    private var lastOperationSucceeded = false

    func increase(by percent: Float) {
        let delta = clamp01(percent / 100.0)
        let device = getCurrentOutputDevice()
        emit("[Volume][Debug] Requested change: +\(percent)")
        emit("[Volume][Debug] Previous volume: \(currentVolume)")
        if device == .hdmi {
            emit("[Volume][Debug] Using method: ddc")
            let step = max(1, Int(round(Double(delta * 100.0))))
            let before = currentVolume
            let ok = monitorVolume.setVolumeResult(monitorVolume.currentPercent + step)
            if ok {
                currentVolume = Float(monitorVolume.currentPercent) / 100.0
                lastOperationSucceeded = hasMeaningfulChange(before: before, after: currentVolume)
                return
            }
            emit("[Volume][Debug] DDC failed, falling back to audiogain")
            let gainBefore = audioGain.currentVolumeFactor()
            let gainApplied = audioGain.increase(by: step)
            if gainApplied {
                currentVolume = audioGain.currentVolumeFactor()
            }
            lastOperationSucceeded = gainApplied && hasMeaningfulChange(before: gainBefore, after: currentVolume)
            return
        }

        emit("[Volume][Debug] Using method: coreaudio")
        let before = coreAudio.getVolume().map { Float($0) }
        coreAudio.increase(by: delta)
        syncCurrentVolumeFromSystem()
        let after = coreAudio.getVolume().map { Float($0) }
        lastOperationSucceeded = hasMeaningfulChange(before: before, after: after)
    }

    func decrease(by percent: Float) {
        let delta = clamp01(percent / 100.0)
        let device = getCurrentOutputDevice()
        emit("[Volume][Debug] Requested change: +\(-percent)")
        emit("[Volume][Debug] Previous volume: \(currentVolume)")
        if device == .hdmi {
            emit("[Volume][Debug] Using method: ddc")
            let step = max(1, Int(round(Double(delta * 100.0))))
            let before = currentVolume
            let ok = monitorVolume.setVolumeResult(monitorVolume.currentPercent - step)
            if ok {
                currentVolume = Float(monitorVolume.currentPercent) / 100.0
                lastOperationSucceeded = hasMeaningfulChange(before: before, after: currentVolume)
                return
            }
            emit("[Volume][Debug] DDC failed, falling back to audiogain")
            let gainBefore = audioGain.currentVolumeFactor()
            let gainApplied = audioGain.decrease(by: step)
            if gainApplied {
                currentVolume = audioGain.currentVolumeFactor()
            }
            lastOperationSucceeded = gainApplied && hasMeaningfulChange(before: gainBefore, after: currentVolume)
            return
        }

        emit("[Volume][Debug] Using method: coreaudio")
        let before = coreAudio.getVolume().map { Float($0) }
        coreAudio.decrease(by: delta)
        syncCurrentVolumeFromSystem()
        let after = coreAudio.getVolume().map { Float($0) }
        lastOperationSucceeded = hasMeaningfulChange(before: before, after: after)
    }

    func setVolume(_ percent: Float) {
        let normalized = clamp01(percent / 100.0)
        let device = getCurrentOutputDevice()
        emit("[Volume][Debug] Requested change: +\(percent)")
        emit("[Volume][Debug] Previous volume: \(currentVolume)")
        if device == .hdmi {
            emit("[Volume][Debug] Using method: ddc")
            let target = Int(round(Double(normalized * 100.0)))
            let before = currentVolume
            let ok = monitorVolume.setVolumeResult(target)
            if ok {
                currentVolume = Float(monitorVolume.currentPercent) / 100.0
                lastOperationSucceeded = hasMeaningfulChange(before: before, after: currentVolume)
                return
            }
            emit("[Volume][Debug] DDC failed, falling back to audiogain")
            let gainBefore = audioGain.currentVolumeFactor()
            let gainApplied = audioGain.setVolume(target)
            if gainApplied {
                currentVolume = audioGain.currentVolumeFactor()
            }
            lastOperationSucceeded = gainApplied && hasMeaningfulChange(before: gainBefore, after: currentVolume)
            return
        }

        emit("[Volume][Debug] Using method: coreaudio")
        let before = coreAudio.getVolume().map { Float($0) }
        _ = coreAudio.setVolume(normalized)
        syncCurrentVolumeFromSystem()
        let after = coreAudio.getVolume().map { Float($0) }
        lastOperationSucceeded = hasMeaningfulChange(before: before, after: after)
    }

    func mute() {
        preMuteVolume = currentVolume
        setVolume(0)
    }

    func unmute() {
        let restore = preMuteVolume > 0 ? preMuteVolume : 0.5
        let device = getCurrentOutputDevice()
        emit("[Volume][Debug] Requested change: +\(restore * 100.0)")
        emit("[Volume][Debug] Previous volume: \(currentVolume)")
        if device == .hdmi {
            emit("[Volume][Debug] Using method: ddc")
            let before = currentVolume
            let ok = monitorVolume.setVolumeResult(Int(round(Double(restore * 100.0))))
            if ok {
                currentVolume = Float(monitorVolume.currentPercent) / 100.0
                lastOperationSucceeded = hasMeaningfulChange(before: before, after: currentVolume)
                return
            }
            emit("[Volume][Debug] DDC failed, falling back to audiogain")
            let gainBefore = audioGain.currentVolumeFactor()
            let gainApplied = audioGain.setVolume(Int(round(Double(restore * 100.0))))
            if gainApplied {
                currentVolume = audioGain.currentVolumeFactor()
            }
            lastOperationSucceeded = gainApplied && hasMeaningfulChange(before: gainBefore, after: currentVolume)
            return
        }

        emit("[Volume][Debug] Using method: coreaudio")
        let before = coreAudio.getVolume().map { Float($0) }
        _ = coreAudio.setVolume(restore)
        syncCurrentVolumeFromSystem()
        let after = coreAudio.getVolume().map { Float($0) }
        lastOperationSucceeded = hasMeaningfulChange(before: before, after: after)
    }

    func execute(_ action: VolumeAction) -> String {
        emit("========== VOLUME DEBUG START ==========")

        let device = getCurrentOutputDevice()
        emit("[Volume][Debug] Detecting output device...")
        emit("[Volume][Debug] Device detected: \(device)")

        let beforeActual: Float?
        if device == .hdmi {
            beforeActual = currentVolume
        } else {
            beforeActual = coreAudio.getVolume().map { Float($0) }
        }
        if let beforeActual {
            currentVolume = beforeActual
        }

        let resultText: String
        switch action {
        case .increase(let by):
            increase(by: Float(by))
            resultText = "Volume increased by \(by)%"
        case .decrease(let by):
            decrease(by: Float(by))
            resultText = "Volume decreased by \(by)%"
        case .setLevel(let level):
            setVolume(Float(level))
            resultText = "Volume set to \(Int(currentVolume * 100))%"
        case .mute:
            mute()
            resultText = "Muted"
        case .unmute:
            unmute()
            resultText = "Unmuted"
        }

        let afterActual: Float?
        if device == .hdmi {
            afterActual = currentVolume
        } else {
            afterActual = coreAudio.getVolume().map { Float($0) }
        }
        if let afterActual {
            currentVolume = afterActual
        }

        let changed = lastOperationSucceeded && hasMeaningfulChange(before: beforeActual, after: afterActual)
        if !changed {
            if device == .hdmi {
                emit("[Volume][ERROR] Monitor does not support DDC volume and audio gain fallback is unavailable")
            }
            emit("[Volume][ERROR] Volume change had NO EFFECT")
        }

        emit("[Volume][Result] Final volume level: \(currentVolume)")
        emit("========== VOLUME DEBUG END ==========")

        if changed {
            return resultText
        }
        return "Volume command executed but no actual volume change was detected"
    }

    private func syncCurrentVolumeFromSystem() {
        if let value = coreAudio.getVolume() {
            currentVolume = Float(value)
        }
    }

    private func clamp01(_ value: Float) -> Float {
        min(max(value, 0.0), 1.0)
    }

    private func hasMeaningfulChange(before: Float?, after: Float?) -> Bool {
        guard let before, let after else { return false }
        return abs(before - after) > 0.001
    }

    private func emit(_ message: String) {
        if let onLog {
            onLog(message)
        } else {
            print(message)
        }
    }

    private func getCurrentOutputDevice() -> AudioDeviceType {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let deviceStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard deviceStatus == noErr else { return .unknown }

        var transportType: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let typeStatus = AudioObjectGetPropertyData(
            deviceID,
            &transportAddress,
            0,
            nil,
            &transportSize,
            &transportType
        )

        guard typeStatus == noErr else { return .unknown }
        switch transportType {
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .hdmi
        default:
            return .nonHDMI
        }
    }
}
