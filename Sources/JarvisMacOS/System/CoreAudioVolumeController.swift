import Foundation
import CoreAudio
import AudioToolbox

final class CoreAudioVolumeController {
    var onLog: ((String) -> Void)?

    func getOutputDeviceID() -> AudioDeviceID? {
        validateRoutingConfiguration()

        guard let deviceID = findBlackHoleDevice() else {
            emit("[Volume][ERROR] Cannot control volume without BlackHole")
            emit("[Volume][ERROR] System not routed through BlackHole")
            return nil
        }

        let name = getDeviceName(deviceID) ?? "Unknown"
        emit("[Volume] Using device: \(name) (ID: \(deviceID))")
        return deviceID
    }

    func getVolume() -> Float32? {
        guard let deviceID = getOutputDeviceID() else { return nil }

        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            emit("[Volume][ERROR] Device does NOT support volume control")
            return nil
        }

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &volume
        )

        if status != noErr {
            emit("[Volume][ERROR] Cannot read volume")
            return nil
        }

        emit("[Volume][CoreAudio] Current volume: \(volume)")
        return volume
    }

    func setVolume(_ value: Float32) -> Bool {
        guard let deviceID = getOutputDeviceID() else { return false }

        var newVolume = min(max(value, 0.0), 1.0)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if !AudioObjectHasProperty(deviceID, &address) {
            emit("[Volume][ERROR] Device does NOT support volume control")
            return false
        }

        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Float32>.size),
            &newVolume
        )

        if status != noErr {
            emit("[Volume][ERROR] Failed to set volume")
            return false
        }

        emit("[Volume][CoreAudio] New volume: \(newVolume)")
        return true
    }

    func increase(by delta: Float32) {
        if let current = getVolume() {
            _ = setVolume(current + delta)
        }
    }

    func decrease(by delta: Float32) {
        if let current = getVolume() {
            _ = setVolume(current - delta)
        }
    }

    private func findBlackHoleDevice() -> AudioDeviceID? {
        let devices = getAllAudioDevices()
        for device in devices {
            let name = getDeviceName(device) ?? "Unknown"
            if name.lowercased().contains("blackhole") {
                emit("[Volume] BlackHole found: \(name)")
                return device
            }
        }

        emit("[Volume][ERROR] BlackHole not found")
        return nil
    }

    private func getAllAudioDevices() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(0), count: count)
        let dataStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        )
        guard dataStatus == noErr else { return [] }
        return devices
    }

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef)
        guard status == noErr else { return nil }
        return nameRef?.takeUnretainedValue() as String?
    }

    private func validateRoutingConfiguration() {
        guard let defaultOutputName = defaultOutputDeviceName() else {
            emit("[Volume][ERROR] Invalid audio routing configuration")
            return
        }

        let lowered = defaultOutputName.lowercased()
        let looksValid = lowered.contains("multi-output") || lowered.contains("blackhole")
        if !looksValid {
            emit("[Volume][ERROR] Invalid audio routing configuration")
            emit("[Volume][ERROR] System not routed through BlackHole")
        }
    }

    private func defaultOutputDeviceName() -> String? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
        return getDeviceName(deviceID)
    }

    private func emit(_ message: String) {
        if let onLog {
            onLog(message)
        } else {
            print(message)
        }
    }
}
