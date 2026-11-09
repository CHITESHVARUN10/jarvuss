import Foundation
import AppKit

final class AppController {
    /// Wait for the launched app itself, rather than sleeping after every
    /// action in a plan. Already-running apps return immediately.
    func openAndWaitForLaunch(appName: String) async -> ControllerResult {
        guard !Task.isCancelled else { return ControllerResult(message: "App launch cancelled.", success: false) }
        let result = openResult(appName: appName)
        guard result.success else { return ControllerResult(message: result.message, success: false) }
        let name = AppAliasResolver.resolveSpoken(appName)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return ControllerResult(message: "App launch cancelled.", success: false) }
            let ready: Bool? = await MainActor.run {
                let app = NSWorkspace.shared.runningApplications.first { app in
                    let names = [app.localizedName, app.bundleURL?.deletingPathExtension().lastPathComponent]
                    return names.compactMap { $0 }.contains {
                        $0.caseInsensitiveCompare(name) == .orderedSame
                    }
                }
                return app?.isFinishedLaunching
            }
            // LaunchServices also accepts names differing from an app's
            // localized/process name. Preserve its successful acknowledgement
            // when no exact process can be identified, rather than inventing
            // a ten-second launch failure for a working app.
            if ready == true { return ControllerResult(message: result.message, success: true, verification: .verified) }
            if ready == nil { return ControllerResult(message: "Sent an open request for \(name); its launch could not be read back.", success: true, verification: .unavailable) }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return ControllerResult(message: "App launch cancelled.", success: false) }
        }
        return ControllerResult(message: "Opened \(name), but it did not finish launching within 10 seconds.", success: false)
    }
    /// Structured result: success comes from the process exit, not from
    /// sniffing the message text (an app named "ErrorLog" must not read
    /// as a failure). The String wrappers below preserve the old API.
    func openResult(appName: String) -> (message: String, success: Bool) {
        let normalized = AppAliasResolver.resolveSpoken(appName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", normalized]

        do {
            try process.run()
            let exited = process.waitUntilExit(timeout: 10)
            if !exited {
                return ("Failed to open \(normalized) — it is taking too long.", false)
            }
            if process.terminationStatus == 0 {
                return ("Opened \(normalized).", true)
            }
            return ("Failed to open \(normalized).", false)
        } catch {
            return ("Error opening app: \(error.localizedDescription)", false)
        }
    }

    func closeResult(appName: String) -> (message: String, success: Bool) {
        let normalized = AppAliasResolver.resolveSpoken(appName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.quitArguments(appName: normalized)

        do {
            try process.run()
            // 8 s deadline: quitting an app that has running processes pops a
            // confirmation dialog and the AppleScript waits on it FOREVER —
            // that hang used to wedge the whole command queue on "Working".
            let exited = process.waitUntilExit(timeout: 8)
            if !exited {
                // "Failed" keeps the executor's success heuristic honest.
                return ("Failed to close \(normalized) — it may be showing a confirmation dialog. Answer it on screen, or quit it manually.", false)
            }
            if process.terminationStatus == 0 {
                return ("Closed \(normalized).", true)
            }
            return ("Failed to close \(normalized).", false)
        } catch {
            return ("Error closing app: \(error.localizedDescription)", false)
        }
    }

    static func quitArguments(appName: String) -> [String] {
        ["-e", "on run argv\n tell application (item 1 of argv) to quit\nend run", "--", appName]
    }

    func open(appName: String) -> String {
        openResult(appName: appName).message
    }

    func close(appName: String) -> String {
        closeResult(appName: appName).message
    }
}

/// Rust owns the alias table and fuzzy policy in both pipeline modes.
/// Swift retains only the native application-launch adapter.
enum AppAliasResolver {
    static func resolve(_ name: String) -> String { coreResolveAppName(name: name) }
    static func knownAppName(_ input: String) -> String? { coreKnownAppName(name: input) }
    static func resolveSpoken(_ name: String) -> String { coreResolveApp(name: name) }
}
