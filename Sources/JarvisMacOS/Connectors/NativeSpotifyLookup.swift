import AppKit
import ApplicationServices
import Foundation

/// No HTTP client, API credentials or OAuth. Lookup reads Spotify's local UI.
enum NativeSpotifyError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? { if case .unavailable(let text) = self { return text }; return nil }
}

enum NativeSpotifyLookup {
    struct NativeTarget {
        let uri: String
        let trackURI: String?
    }

    struct SearchLink {
        let label: String
        let url: String
    }

    /// Return whether to press the specifically named control. An already
    /// playing collection must not be paused by a repeated play request.
    static func likedControlNeedsPress(_ labels: [String]) -> Bool? {
        for label in labels {
            if label.lowercased() == "play liked songs" { return true }
            if label.lowercased() == "pause liked songs" { return false }
        }
        return nil
    }

    /// Only Spotify-owned track/playlist identifiers can enter AppleScript.
    static func targetURI(_ raw: String, kind: String) -> String? {
        let type = kind == "song" ? "track" : "playlist"
        let id: String
        if raw.hasPrefix("spotify:\(type):") {
            id = String(raw.dropFirst("spotify:\(type):".count))
        } else if let parts = URLComponents(string: raw), parts.scheme == "https",
                  ["open.spotify.com", "xpui.app.spotify.com"].contains(parts.host ?? ""),
                  parts.user == nil, parts.password == nil {
            let segments = parts.path.split(separator: "/")
            guard segments.count == 2, segments[0] == type else { return nil }
            id = String(segments[1])
        } else { return nil }
        guard !id.isEmpty, id.count <= 64,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else { return nil }
        return "spotify:\(type):\(id)"
    }

    static func selectTarget(kind: String, name: String, links: [SearchLink]) -> NativeTarget? {
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .replacingOccurrences(of: "’", with: "'")
                .replacingOccurrences(of: "‘", with: "'")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        // Exact names only: do not play a merely similar result or a playlist
        // returned for a song. More specific queries can be selected in Spotify.
        guard let link = links.first(where: { normalized($0.label) == key && targetURI($0.url, kind: kind) != nil }),
              let uri = targetURI(link.url, kind: kind) else { return nil }
        return NativeTarget(uri: uri, trackURI: kind == "song" ? uri : nil)
    }

    @MainActor
    static func nativeTarget(kind: String, name: String, shuffle: Bool) async throws -> NativeTarget {
        guard ["song", "playlist", "liked"].contains(kind), name.count <= 512 else {
            throw NativeSpotifyError.unavailable("Invalid Spotify lookup.")
        }
        // URI input works without browsing the catalog.
        if let uri = targetURI(name, kind: kind), kind != "liked" {
            return NativeTarget(uri: uri, trackURI: kind == "song" ? uri : nil)
        }
        guard AXIsProcessTrusted() else {
            throw NativeSpotifyError.unavailable("Allow Jarvis in Privacy & Security → Accessibility for native song and library lookup.")
        }
        let destination: URL
        if kind == "liked" {
            destination = URL(string: "spotify:collection:tracks")!
        } else {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "spotify:search:\(encoded)") else {
                throw NativeSpotifyError.unavailable("Name the song or playlist to find in Spotify.")
            }
            destination = url
        }
        guard NSWorkspace.shared.open(destination) else {
            throw NativeSpotifyError.unavailable("Install Spotify and sign in on this Mac.")
        }
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first?.processIdentifier else { continue }
            let scan = await RustPipeline.runBlocking { scanSpotify(pid: pid, liked: kind == "liked") }
            if kind == "liked", scan.playedLiked {
                // A specifically labelled Liked Songs play control was pressed.
                return NativeTarget(uri: "spotify:collection:tracks", trackURI: nil)
            }
            if let target = selectTarget(kind: kind, name: name, links: scan.links) { return target }
        }
        throw NativeSpotifyError.unavailable("Spotify did not expose an exact \(kind == "liked" ? "Liked Songs play control" : "match for ‘\(name)’"). Open it in Spotify and try again. No API keys are required.")
    }

    private static func scanSpotify(pid: pid_t, liked: Bool) -> (links: [SearchLink], playedLiked: Bool) {
        func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
            return value
        }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        // Chromium-based Spotify builds may expose web content only after
        // an assistive client requests the enhanced accessibility tree.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        var pending = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        var cursor = 0, links: [SearchLink] = []
        var visited = Set<CFHashCode>()
        var diagnostic: [[String: String]] = []
        let diagnosticsEnabled = ProcessInfo.processInfo.environment["JARVIS_SPOTIFY_DIAGNOSTICS"] == "1"
        defer {
            if diagnosticsEnabled, let data = try? JSONSerialization.data(withJSONObject: diagnostic) {
                let folder = RuntimeConfiguration.dataDirectory
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("spotify-native-ui.json")
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        let deadline = Date().addingTimeInterval(0.6)
        while cursor < pending.count && cursor < 4000 && Date() < deadline {
            let element = pending[cursor]; cursor += 1
            guard visited.insert(CFHash(element)).inserted else { continue }
            let title = attribute(element, kAXTitleAttribute as CFString) as? String ?? ""
            let description = attribute(element, kAXDescriptionAttribute as CFString) as? String ?? ""
            let role = attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
            if diagnosticsEnabled {
                var actions: CFArray?
                AXUIElementCopyActionNames(element, &actions)
                diagnostic.append(["role": role, "title": title, "description": description,
                    "url": String(describing: attribute(element, kAXURLAttribute as CFString)),
                    "actions": String(describing: actions)])
            }
            if liked && role == kAXButtonRole as String,
               let press = likedControlNeedsPress([title, description]) {
                return (links, !press || AXUIElementPerformAction(element, kAXPressAction as CFString) == .success)
            }
            if let value = attribute(element, kAXURLAttribute as CFString) {
                let url = (value as? URL)?.absoluteString ?? (value as? String) ?? ""
                if !url.isEmpty {
                    for label in [title, description] where !label.isEmpty { links.append(SearchLink(label: label, url: url)) }
                }
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(max(0, 4000 - pending.count)))
            }
        }
        return (links, false)
    }
}
