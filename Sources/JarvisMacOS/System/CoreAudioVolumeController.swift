import Foundation
import CoreAudio
import AudioToolbox

struct SystemAudioOutput: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let isAggregate: Bool
}

enum SystemAudioProperty: Hashable {
    case virtualVolume
    case volume(UInt32)
    case mute(UInt32)

    var address: AudioObjectPropertyAddress {
        let selector: AudioObjectPropertySelector
        let element: UInt32
        switch self {
        case .virtualVolume:
            selector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume; element = kAudioObjectPropertyElementMain
        case .volume(let channel): selector = kAudioDevicePropertyVolumeScalar; element = channel
        case .mute(let channel): selector = kAudioDevicePropertyMute; element = channel
        }
        return AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }
}

/// Injectable HAL boundary: regression tests never write to the user's audio devices.
protocol SystemAudioAccess {
    func defaultOutput() throws -> SystemAudioOutput
    func outputChannelCount(_ device: SystemAudioOutput) throws -> Int
    func isSettable(_ property: SystemAudioProperty, on device: SystemAudioOutput) -> Bool
    func read(_ property: SystemAudioProperty, on device: SystemAudioOutput) throws -> Float
    func write(_ value: Float, to property: SystemAudioProperty, on device: SystemAudioOutput) throws
}

struct SystemAudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Controls only the default media output. No device enumeration, BlackHole
/// requirement, microphone access, audio engine, or routing changes.
final class CoreAudioVolumeController: SystemAudioAccess {
    func defaultOutput() throws -> SystemAudioOutput {
        let id: UInt32 = try readValue(object: AudioObjectID(kAudioObjectSystemObject),
                                      selector: kAudioHardwarePropertyDefaultOutputDevice)
        guard id != kAudioObjectUnknown else { throw SystemAudioError(message: "No active audio output is available.") }
        let uid = try string(id, kAudioDevicePropertyDeviceUID)
        let name = (try? string(id, kAudioObjectPropertyName)) ?? "Audio output"
        let transport: UInt32 = try readValue(object: id, selector: kAudioDevicePropertyTransportType)
        let objectClass: UInt32 = try readValue(object: id, selector: kAudioObjectPropertyClass)
        return SystemAudioOutput(id: id, uid: uid, name: name,
                                 isAggregate: transport == kAudioDeviceTransportTypeAggregate || objectClass == kAudioAggregateDeviceClassID)
    }

    func isSettable(_ property: SystemAudioProperty, on device: SystemAudioOutput) -> Bool {
        var address = property.address
        guard AudioObjectHasProperty(device.id, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device.id, &address, &settable) == noErr && settable.boolValue
    }

    func read(_ property: SystemAudioProperty, on device: SystemAudioOutput) throws -> Float {
        var address = property.address
        guard AudioObjectHasProperty(device.id, &address) else {
            throw SystemAudioError(message: "The selected output does not expose this audio control.")
        }
        switch property {
        case .mute:
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &value), "Read output mute")
            guard value <= 1 else { throw SystemAudioError(message: "The output returned an invalid mute value.") }
            return Float(value)
        default:
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            try check(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, &value), "Read output volume")
            guard value.isFinite, (0...1).contains(value) else {
                throw SystemAudioError(message: "The output returned an invalid volume value.")
            }
            return value
        }
    }

    func write(_ value: Float, to property: SystemAudioProperty, on device: SystemAudioOutput) throws {
        guard value.isFinite, (0...1).contains(value), isSettable(property, on: device) else {
            throw SystemAudioError(message: "The selected output's audio control is unavailable or read-only.")
        }
        var address = property.address
        switch property {
        case .mute:
            var flag: UInt32 = value > 0 ? 1 : 0
            try check(AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag), "Set output mute")
        default:
            var scalar = value
            try check(AudioObjectSetPropertyData(device.id, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &scalar), "Set output volume")
        }
    }

    func outputChannelCount(_ device: SystemAudioOutput) throws -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device.id, &address, 0, nil, &size), "Read output channel layout")
        guard size >= MemoryLayout<AudioBufferList>.size, size < 65536 else {
            throw SystemAudioError(message: "The output has no usable channel layout.")
        }
        let capacity = Int(size)
        let data = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { data.deallocate() }
        try check(AudioObjectGetPropertyData(device.id, &address, 0, nil, &size, data), "Read output channels")
        let list = data.assumingMemoryBound(to: AudioBufferList.self)
        let header = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers)!
        guard Int(size) <= capacity, Int(size) >= header,
              Int(list.pointee.mNumberBuffers) <= (Int(size) - header) / MemoryLayout<AudioBuffer>.stride else {
            throw SystemAudioError(message: "The output returned an invalid channel layout.")
        }
        let count = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
        guard (1...64).contains(count) else { throw SystemAudioError(message: "This output's channel layout is unsupported.") }
        return count
    }

    private func readValue(object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Read audio output identity")
        return value
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "Read audio output name/UID")
        }
        let text = value as String
        guard !text.isEmpty else { throw SystemAudioError(message: "The output has no stable device identity.") }
        return text
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SystemAudioError(message: "\(operation) failed (Core Audio \(status)).") }
    }
}
