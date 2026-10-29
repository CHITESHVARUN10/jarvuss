import Foundation

/// Observed hardware state and capabilities; nil levels are never replaced by
/// a guessed percentage in the System pane.
struct SystemVolumeSnapshot: Sendable {
    let output: SystemAudioOutput?
    let level: Float?
    let isMuted: Bool?
    let canSetVolume: Bool
    let canMute: Bool
    let canUnmute: Bool
    let detail: String?
}

/// One serialized transaction per command. The output ID and UID are pinned
/// for its entire lifetime; later commands resolve the default output afresh.
// The worker owns the injected HAL access and mute bookmarks. Only the log
// callback crosses that boundary; its storage is protected by a separate lock.
final class VolumeController: @unchecked Sendable {
    static let shared = VolumeController()

    private struct Value {
        let property: SystemAudioProperty
        let value: Float
    }

    private let logLock = NSLock()
    private var logHandler: ((String) -> Void)?
    var onLog: ((String) -> Void)? {
        get { logLock.withLock { logHandler } }
        set { logLock.withLock { logHandler = newValue } }
    }
    private let audio: SystemAudioAccess
    private let waitForReadback: () -> Void
    private let queue = DispatchQueue(label: "com.jarvis.system-volume", qos: .userInitiated)
    // Only fallback mute needs a bookmark. Never restore another device's gain
    // or invent a 50% volume on a fresh launch.
    private var mutedVolumes: [String: [Value]] = [:]

    init(audio: SystemAudioAccess = CoreAudioVolumeController(),
         waitForReadback: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.025) }) {
        self.audio = audio
        self.waitForReadback = waitForReadback
    }

    /// nil is a read-only volume query. No HAL operations run on the UI thread.
    func perform(_ action: VolumeAction?, expectedOutput: SystemAudioOutput? = nil) async -> ControllerResult {
        guard !Task.isCancelled else { return ControllerResult(message: "Volume command cancelled.", success: false) }
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.result(for: action, expectedOutput: expectedOutput)) }
        }
    }

    func snapshot() async -> SystemVolumeSnapshot {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.inspectOutput()) }
        }
    }

    /// Synchronous entry points also share the same serialization boundary.
    func executeResult(_ action: VolumeAction) -> ControllerResult { queue.sync { result(for: action) } }
    func readResult() -> ControllerResult { queue.sync { result(for: nil) } }

    private func result(for action: VolumeAction?, expectedOutput: SystemAudioOutput? = nil) -> ControllerResult {
        var wrote = false
        do {
            let device = try audio.defaultOutput()
            if let expectedOutput, device.id != expectedOutput.id || device.uid != expectedOutput.uid {
                throw SystemAudioError(message: "The selected audio output changed. Review the new output and try again.")
            }
            onLog?("[Volume] Active output: \(device.name) (\(device.id)); request: \(action?.description ?? "read")")
            guard !device.isAggregate else {
                throw SystemAudioError(message: "\(device.name) is an aggregate or multi-output device. Select a single output in Sound settings to control its volume.")
            }
            guard let action else {
                let levels = try? volumeControls(device, writable: false)
                let mute = try muteControls(device)
                try requireSameOutput(device)
                let muted = mute.contains { $0.value > 0 }
                if let level = levels?.map(\.value).max() {
                    return ControllerResult(message: "\(device.name): \(percent(level))%\(muted ? " (muted)" : "")", success: true)
                }
                if !mute.isEmpty {
                    return ControllerResult(message: "\(device.name): \(muted ? "muted" : "not muted"); volume reading unavailable.", success: true)
                }
                throw unsupported(device)
            }

            switch action {
            case .mute, .unmute:
                let shouldMute = action == .mute
                let hardware = try muteControls(device)
                if !hardware.isEmpty {
                    let changes = hardware.map { Value(property: $0.property, value: shouldMute ? 1 : 0) }
                    try apply(changes, on: device, wrote: &wrote)
                } else {
                    let current = try volumeControls(device, writable: true)
                    let level = current.map(\.value).max() ?? 0
                    if shouldMute {
                        // Repeated mute must not overwrite the original level with zero.
                        if level > 0 { mutedVolumes[device.uid] = current }
                        try apply(current.map { Value(property: $0.property, value: 0) }, on: device, wrote: &wrote)
                    } else if level == 0 {
                        guard let saved = mutedVolumes[device.uid], saved.contains(where: { $0.value > 0 }),
                              saved.map(\.property) == current.map(\.property) else {
                            throw SystemAudioError(message: "\(device.name) is at 0%. No saved mute level is available; say ‘set volume to 20 percent’ to choose a level.")
                        }
                        try apply(saved, on: device, wrote: &wrote)
                        mutedVolumes.removeValue(forKey: device.uid)
                    } else {
                        mutedVolumes.removeValue(forKey: device.uid)
                    }
                }
                try requireSameOutput(device)
                return ControllerResult(message: "\(shouldMute ? "Muted" : "Unmuted") \(device.name).", success: true)

            case .increase(let amount), .decrease(let amount), .setLevel(let amount):
                guard (0...100).contains(amount) else {
                    throw SystemAudioError(message: "Volume amounts must be between 0 and 100 percent.")
                }
                let current = try volumeControls(device, writable: true)
                let before = current.map(\.value).max() ?? 0
                let target: Float
                switch action {
                case .increase: target = min(1, before + Float(amount) / 100)
                case .decrease: target = max(0, before - Float(amount) / 100)
                default: target = Float(amount) / 100
                }
                let muted = try muteControls(device).filter { $0.value > 0 }
                let shouldUnmute: Bool
                if case .setLevel = action { shouldUnmute = target > 0 }
                else { shouldUnmute = target > 0 && amount > 0 }
                // Preflight unmute before changing gain, so read-only mute
                // doesn't leave a silently changed volume behind.
                if shouldUnmute, muted.contains(where: { !audio.isSettable($0.property, on: device) }) {
                    throw SystemAudioError(message: "\(device.name) is muted and its mute control is read-only. Unmute it using its own controls first.")
                }
                let changes = current.map {
                    Value(property: $0.property, value: before > 0 ? min(1, $0.value * target / before) : target)
                }
                try apply(changes, on: device, wrote: &wrote)
                if shouldUnmute {
                    try apply(muted.map { Value(property: $0.property, value: 0) }, on: device, wrote: &wrote)
                    mutedVolumes.removeValue(forKey: device.uid)
                }
                let actual = try volumeControls(device, writable: true).map(\.value).max() ?? 0
                try requireSameOutput(device)
                return ControllerResult(message: "\(device.name): volume \(percent(actual))%.", success: true)
            }
        } catch {
            let partial = wrote ? " Some audio controls may have changed; check the output before retrying." : ""
            let message = error.localizedDescription + partial
            onLog?("[Volume] Failed: \(message)")
            return ControllerResult(message: message, success: false)
        }
    }

    private func inspectOutput() -> SystemVolumeSnapshot {
        var output: SystemAudioOutput?
        do {
            let device = try audio.defaultOutput()
            output = device
            guard !device.isAggregate else {
                throw SystemAudioError(message: "Select a single output in macOS Sound settings. Aggregate and multi-output volume control is unavailable.")
            }
            let levels = try? volumeControls(device, writable: false)
            let level = levels?.map(\.value).max()
            let writable = (try? volumeControls(device, writable: true)) != nil
            let hardware = try muteControls(device)
            let canMute: Bool
            let canUnmute: Bool
            let muted: Bool?
            if hardware.isEmpty {
                canMute = writable
                let saved = mutedVolumes[device.uid]
                canUnmute = writable && ((level ?? 0) > 0 || saved?.contains(where: { $0.value > 0 }) == true)
                muted = level.map { $0 == 0 }
            } else {
                muted = hardware.contains { $0.value > 0 }
                canMute = hardware.allSatisfy { $0.value == 1 || audio.isSettable($0.property, on: device) }
                canUnmute = hardware.allSatisfy { $0.value == 0 || audio.isSettable($0.property, on: device) }
            }
            try requireSameOutput(device)
            let detail: String?
            if !writable {
                detail = level == nil ? "This output does not expose native volume control. Use its own controls or a configured audio controller."
                    : "This output reports its volume but does not expose a writable native volume control."
            } else if muted == true && !canUnmute {
                detail = "No saved mute level is available. Choose a volume with the slider to restore sound."
            } else { detail = nil }
            return SystemVolumeSnapshot(output: device, level: level, isMuted: muted,
                                        canSetVolume: writable, canMute: canMute, canUnmute: canUnmute, detail: detail)
        } catch {
            return SystemVolumeSnapshot(output: output, level: nil, isMuted: nil,
                                        canSetVolume: false, canMute: false, canUnmute: false, detail: error.localizedDescription)
        }
    }

    /// Prefer the native virtual main control: macOS maintains channel balance.
    /// Some drivers expose only scalar main or individual channel controls.
    private func volumeControls(_ device: SystemAudioOutput, writable: Bool) throws -> [Value] {
        for property in [SystemAudioProperty.virtualVolume, .volume(0)] {
            if (!writable || audio.isSettable(property, on: device)), let value = try? read(property, on: device) {
                return [Value(property: property, value: value)]
            }
        }
        let count = try audio.outputChannelCount(device)
        guard (1...64).contains(count) else { throw unsupported(device) }
        let channels = (1...count).map { SystemAudioProperty.volume(UInt32($0)) }
        guard !writable || channels.allSatisfy({ audio.isSettable($0, on: device) }) else { throw unsupported(device) }
        do { return try channels.map { Value(property: $0, value: try read($0, on: device)) } }
        catch { throw unsupported(device) }
    }

    private func muteControls(_ device: SystemAudioOutput) throws -> [Value] {
        if let value = try? read(.mute(0), on: device) { return [Value(property: .mute(0), value: value)] }
        guard let count = try? audio.outputChannelCount(device), (1...64).contains(count) else { return [] }
        let values = (1...count).compactMap { channel -> Value? in
            let property = SystemAudioProperty.mute(UInt32(channel))
            return (try? read(property, on: device)).map { Value(property: property, value: $0) }
        }
        guard values.isEmpty || values.count == count else {
            throw SystemAudioError(message: "\(device.name) exposes mute state for only some output channels. Use its own audio controls.")
        }
        return values
    }

    private func apply(_ changes: [Value], on device: SystemAudioOutput, wrote: inout Bool) throws {
        // Validate every channel before writing any channel.
        for change in changes {
            guard audio.isSettable(change.property, on: device) else {
                // A readable, already correct mute is an idempotent success.
                if try read(change.property, on: device) == change.value { continue }
                throw SystemAudioError(message: "\(device.name)'s requested audio control is read-only.")
            }
        }
        for change in changes {
            try requireSameOutput(device)
            let before = try read(change.property, on: device)
            if abs(before - change.value) < 0.0001 { continue }
            try audio.write(change.value, to: change.property, on: device)
            wrote = true
            // Bluetooth and some USB drivers acknowledge before publishing
            // their new value. Bound the wait on this worker, never the UI.
            func confirmed(_ observed: Float) -> Bool {
                abs(observed - change.value) <= 0.02 && (change.value - before) * (observed - before) > 0
            }
            var observed = try read(change.property, on: device)
            for _ in 0..<4 where !confirmed(observed) {
                waitForReadback()
                try requireSameOutput(device)
                observed = try read(change.property, on: device)
            }
            guard confirmed(observed) else {
                throw SystemAudioError(message: "\(device.name) did not confirm the requested audio change (requested \(percent(change.value))%, read \(percent(observed))%).")
            }
            onLog?("[Volume] Confirmed \(change.property): \(percent(observed))% on \(device.name)")
        }
        try requireSameOutput(device)
    }

    private func read(_ property: SystemAudioProperty, on device: SystemAudioOutput) throws -> Float {
        let value = try audio.read(property, on: device)
        guard value.isFinite, (0...1).contains(value) else {
            throw SystemAudioError(message: "\(device.name) returned an invalid audio level.")
        }
        return value
    }

    private func requireSameOutput(_ device: SystemAudioOutput) throws {
        let current = try audio.defaultOutput()
        guard current.id == device.id, current.uid == device.uid, !current.isAggregate else {
            throw SystemAudioError(message: "The active audio output changed. Please repeat the volume command for the newly selected output.")
        }
    }

    private func unsupported(_ device: SystemAudioOutput) -> SystemAudioError {
        SystemAudioError(message: "\(device.name) does not expose usable native volume controls. Use its hardware controls or a separately configured monitor/software audio controller. Jarvis has not changed audio routing.")
    }

    private func percent(_ value: Float) -> Int { Int((value * 100).rounded()) }
}
