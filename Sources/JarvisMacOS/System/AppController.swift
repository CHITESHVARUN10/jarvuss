import Foundation
import AppKit

final class AppController {
    /// Wait for the launched app itself, rather than sleeping after every
    /// action in a plan. Already-running apps return immediately.
    func openAndWaitForLaunch(appName: String) async -> (message: String, success: Bool) {
        guard !Task.isCancelled else { return ("App launch cancelled.", false) }
        let result = openResult(appName: appName)
        guard result.success else { return result }
        let name = AppAliasResolver.resolveSpoken(appName)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return ("App launch cancelled.", false) }
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
            if ready != false { return result }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return ("App launch cancelled.", false) }
        }
        return ("Opened \(name), but it did not finish launching within 10 seconds.", false)
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

enum AppAliasResolver {
    static func resolve(_ name: String) -> String {
        let value = normalize(name)
        guard !value.isEmpty else { return name }

        for (canonical, aliases) in aliasMap {
            if aliases.contains(value) {
                return canonical
            }
        }

        if let fuzzy = fuzzyResolve(value) {
            return fuzzy
        }

        return name
    }

    static func knownAppName(_ input: String) -> String? {
        let value = normalize(input)
        return aliasMap.first { $0.value.contains(value) }?.key
    }

    private static let aliasMap: [String: Set<String>] = [
        "Google Chrome": ["chrome", "google chrome", "googlechrom"],
        "Spotify": ["spotify"],
        "WhatsApp": ["whatsapp"],
        "Safari": ["safari", "apple safari"],
        "Photos": ["photos", "apple photos", "photo", "fotos"],
        "Brave Browser": ["brave", "brave browser", "browser", "web browser"],
        "Firefox": ["firefox", "mozilla firefox", "fox"],
        "Mail": ["mail", "apple mail", "email"],
        "Messages": ["messages", "imessage", "message"],
        "Calendar": ["calendar", "apple calendar"],
        "Notes": ["notes", "apple notes", "note"],
        "Music": ["music", "apple music"],
        "Maps": ["maps", "apple maps", "map"],
        "App Store": ["app store", "appstore"],
        "City": ["city"],
        "GitHub Desktop": [
            "github", "github desktop", "git hub", "git hub desktop", "githab desktop",
            "get her desktop", "getha desktop", "get desktop", "gate desktop", "get up desktop", "gita desktop"
        ],
        "System Settings": ["system settings", "settings", "system setting"],
        "Visual Studio Code": ["vscode", "vs code", "visual studio code", "visual code"],
        "Finder": ["finder"],
        "Terminal": ["terminal"]
    ]

    private static func fuzzyResolve(_ value: String) -> String? {
        var bestCanonical: String?
        var bestDistance = Int.max

        for (canonical, aliases) in aliasMap {
            for alias in aliases {
                let distance = StringDistance.levenshtein(value, alias)
                if distance < bestDistance {
                    bestDistance = distance
                    bestCanonical = canonical
                }
            }
        }

        guard let bestCanonical else { return nil }
        let maxAllowedDistance = max(1, value.count / 4)
        return bestDistance <= maxAllowedDistance ? bestCanonical : nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper appends sentence punctuation ("Open photos.", "Open city!").
    /// Strip it BEFORE resolve so "photos." hits the alias map.
    static func resolveSpoken(_ name: String) -> String {
        // Migration cut-over: the Rust core carries the same alias table.
        if JarvisFlags.useRustPipeline {
            return coreResolveApp(name: name)
        }
        let cleaned = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!,,;:"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return resolve(cleaned)
    }
}
