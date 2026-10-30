import AppKit
import Foundation

/// Player writes go to Spotify's local scripting interface, never its Web API.
struct NativeSpotifyController {
    typealias Runner = ([String]) async throws -> ProcessOutput
    var resolve: (String, String, Bool) async throws -> SpotifyClient.NativeTarget = {
        try await SpotifyClient().nativeTarget(kind: $0, name: $1, shuffle: $2)
    }
    var run: Runner = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        return try await process.runCapturingOutputAsync(timeout: 12)
    }
    var prepare: () async throws -> Void = {
        try await launchSpotify()
    }

    func execute(_ action: MediaAction) async -> ControllerResult {
        do {
            try Task.checkCancellation()
            var uri = "", expectedTrack = "", shuffle = "keep", command = "play"
            switch action {
            case .play: break
            case .pause: command = "pause"
            case .nextTrack: command = "next"
            case .previousTrack: command = "previous"
            case .setShuffle(let enabled): command = "shuffle"; shuffle = String(enabled)
            case .playSong(let name):
                let target = try await resolve("song", name, false)
                uri = target.uri; expectedTrack = target.trackURI ?? target.uri; command = "target"
            case .playPlaylist(let name), .playPlaylistWithShuffle(let name, _):
                if case .playPlaylistWithShuffle(_, let enabled) = action { shuffle = String(enabled) }
                let target = try await resolve("playlist", name, shuffle == "true")
                uri = target.uri; expectedTrack = target.trackURI ?? ""; command = "target"
            case .playLikedSongs, .playLikedWithShuffle:
                if case .playLikedWithShuffle(let enabled) = action { shuffle = String(enabled) }
                let target = try await resolve("liked", "", shuffle == "true")
                uri = target.uri; expectedTrack = target.trackURI ?? ""; command = "target"
            }
            // All text is passed as argv; names/URIs never become script source.
            if command == "target" {
                guard uri.hasPrefix("spotify:"), !uri.contains("\n"), !uri.contains("\t") else {
                    return ControllerResult(message: "Spotify returned an invalid music identifier.", success: false)
                }
            }
            try Task.checkCancellation()
            if command == "play" || command == "target" { try await prepare() }
            try Task.checkCancellation()
            let output = try await run([command, uri, expectedTrack, shuffle])
            guard output.status == 0, output.stdout == "confirmed" else {
                let detail = output.stderr
                if detail.contains("-1743") {
                    return ControllerResult(message: "Allow Jarvis to control Spotify in System Settings → Privacy & Security → Automation, then try again.", success: false)
                }
                return ControllerResult(message: detail.isEmpty ? "Spotify did not confirm the requested action. Open Spotify and try again." : "Spotify: \(detail)", success: false)
            }
            return ControllerResult(message: "Spotify: \(action.description) confirmed on this Mac.", success: true)
        } catch is CancellationError {
            return ControllerResult(message: "Spotify command cancelled.", success: false)
        } catch {
            return ControllerResult(message: error.localizedDescription, success: false)
        }
    }

    @MainActor private static func launchSpotify() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            throw SpotifyClientError.saveFailed("Install Spotify on this Mac to control playback.")
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    static let script = #"""
    on run argv
        set operation to item 1 of argv
        set targetURI to item 2 of argv
        set expectedTrack to item 3 of argv
        set shuffleMode to item 4 of argv
        if application id "com.spotify.client" is not running then error "Open Spotify before controlling playback."
        tell application id "com.spotify.client"
            set oldTrack to ""
            try
                set oldTrack to id of current track
            end try
            if operation is "play" then
                play
            else if operation is "target" then
                if expectedTrack is not "" and targetURI is not expectedTrack then
                    play track expectedTrack in context targetURI
                else
                    play track targetURI
                end if
            else if operation is "pause" then
                pause
            else if operation is "next" then
                next track
            else if operation is "previous" then
                previous track
            end if
            repeat 40 times
                set currentID to ""
                try
                    set currentID to id of current track
                end try
                set ready to false
                if operation is "pause" then
                    set ready to player state is not playing
                else if operation is "shuffle" then
                    set ready to true
                else if operation is "next" then
                    set ready to currentID is not "" and currentID is not oldTrack
                else if operation is "previous" then
                    -- Previous can restart the same track, as in Spotify itself.
                    set ready to currentID is not "" and (currentID is not oldTrack or player position < 3)
                else
                    set ready to player state is playing and currentID is not ""
                    if expectedTrack is not "" then set ready to ready and currentID is expectedTrack
                end if
                if ready then
                    if (operation is "play" or operation is "target") and sound volume is 0 then error "Spotify volume is zero. Raise its volume and try again."
                    if shuffleMode is not "keep" then
                        if not shuffling enabled then error "Shuffle is unavailable in this Spotify context."
                        set shuffling to (shuffleMode is "true")
                        repeat 30 times
                            if shuffling is (shuffleMode is "true") then return "confirmed"
                            delay 0.1
                        end repeat
                        if operation is "target" then error "Playback started, but Spotify did not confirm shuffle."
                        error "Spotify did not confirm shuffle."
                    end if
                    return "confirmed"
                end if
                delay 0.1
            end repeat
            error "Spotify did not confirm the requested playback state. Open Spotify and try again."
        end tell
    end run
    """#
}
