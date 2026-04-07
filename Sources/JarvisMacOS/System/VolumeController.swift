import Foundation

/// Executes system-level volume changes via AppleScript.
///
/// macOS 'set volume output volume N' always targets the *current* default
/// output device — the one selected in System Settings → Sound → Output.
/// This includes external monitors, USB DACs, Bluetooth speakers, etc.
/// No additional device detection is required; we log the active device
/// name for debugging purposes only.
final class VolumeController {

    // MARK: - Public API

    func execute(_ action: VolumeAction) -> String {
        logCurrentOutputDevice()
        switch action {
        case .increase(let by):
            return adjustRelative(delta: by)
        case .decrease(let by):
            return adjustRelative(delta: -by)
        case .mute:
            let err = runScript("set volume with output muted")
            return err ?? "Muted"
        case .unmute:
            let err = runScript("set volume without output muted")
            return err ?? "Unmuted"
        case .setLevel(let level):
            let safe = clamp(level)
            let err = runScript("set volume output volume \(safe)")
            return err ?? "Volume set to \(safe)%"
        }
    }

    // MARK: - Relative adjustment

    private func adjustRelative(delta: Int) -> String {
        let current = currentVolume() ?? 50
        let target  = clamp(current + delta)
        let direction = delta >= 0 ? "increased" : "decreased"
        // 'set volume output volume' targets the active output device specifically
        // (not input gain), ensuring external speakers/monitors are controlled.
        _ = runScript("set volume output volume \(target)")
        NSLog("[Volume] %@ to %d%% (was %d%%)", direction, target, current)
        return "Volume \(direction) to \(target)%"
    }

    // MARK: - Current volume reader

    private func currentVolume() -> Int? {
        let result = runScriptWithOutput("output volume of (get volume settings)")
        return result.flatMap { Int($0) }
    }

    // MARK: - Active output device logger (debug only)

    private func logCurrentOutputDevice() {
        // CoreAudio GetDefaultAudioOutputDevice via osascript is not trivially
        // scriptable; we use the `SwitchAudioSource` info if available, else skip.
        // This is a best-effort debug log — does NOT affect volume execution.
        let script = """
        set deviceName to ""
        try
            tell application "System Events"
                tell its sound preferences
                    set deviceName to name of current sound output
                end tell
            end tell
        end try
        return deviceName
        """
        if let device = runScriptWithOutput(script), !device.isEmpty {
            NSLog("[Volume] Active output device: %@", device)
        }
    }

    // MARK: - AppleScript runners

    /// Run a script, returning nil on success or an error string on failure.
    @discardableResult
    private func runScript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardError = errPipe
        // Suppress stdout (we don't need the output for set-volume commands)
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return nil }   // success
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg  = String(data: errData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Volume control failed: \(errMsg ?? "unknown error")"
        } catch {
            return "Volume control error: \(error.localizedDescription)"
        }
    }

    /// Run a script and return its stdout output string.
    private func runScriptWithOutput(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = Pipe()   // suppress stderr

        do {
            try process.run()
            process.waitUntilExit()
            let data   = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                           .trimmingCharacters(in: .whitespacesAndNewlines)
            return output.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func clamp(_ value: Int) -> Int {
        min(100, max(0, value))
    }
}
