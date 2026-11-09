import XCTest
@testable import JarvisMacOS

final class NativeSpotifyControllerTests: XCTestCase {
    func testRepeatedLikedPlaybackDoesNotPressPauseOrUseGenericPlayerControls() {
        XCTAssertEqual(NativeSpotifyLookup.likedControlNeedsPress(["Play Liked Songs"]), true)
        XCTAssertEqual(NativeSpotifyLookup.likedControlNeedsPress(["Pause Liked Songs"]), false)
        XCTAssertNil(NativeSpotifyLookup.likedControlNeedsPress(["Play", "Pause"]))
    }
    func testLocalSearchOnlyAcceptsExactNamesAndMatchingSpotifyTypes() {
        let links = [NativeSpotifyLookup.SearchLink(label: "Gym", url: "https://open.spotify.com/playlist/abc123"),
                     NativeSpotifyLookup.SearchLink(label: "Gym mix", url: "spotify:track:wrong"),
                     NativeSpotifyLookup.SearchLink(label: "Gym", url: "https://evil.example/track/abc123")]
        XCTAssertEqual(NativeSpotifyLookup.selectTarget(kind: "playlist", name: "gym", links: links)?.uri, "spotify:playlist:abc123")
        XCTAssertNil(NativeSpotifyLookup.selectTarget(kind: "song", name: "Gym", links: links))
        XCTAssertNil(NativeSpotifyLookup.selectTarget(kind: "playlist", name: "Gym mix", links: links))
        XCTAssertNil(NativeSpotifyLookup.targetURI("spotify:track:abc\nplay", kind: "song"))
        XCTAssertNil(NativeSpotifyLookup.targetURI("https://open.spotify.com.evil.example/track/abc", kind: "song"))
        XCTAssertEqual(NativeSpotifyLookup.targetURI("https://xpui.app.spotify.com/track/abc123", kind: "song"), "spotify:track:abc123")
        let nativeLink = NativeSpotifyLookup.SearchLink(label: "Today’s Top Hits", url: "https://xpui.app.spotify.com/playlist/abc123")
        XCTAssertEqual(NativeSpotifyLookup.selectTarget(kind: "playlist", name: "Today's Top Hits", links: [nativeLink])?.uri, "spotify:playlist:abc123")
    }
    func testTransportAndShuffleNeverResolveMetadata() async {
        let controller = NativeSpotifyController(resolve: { _, _, _ in
            XCTFail("Native transport must work without the helper or Spotify Web API")
            throw NativeSpotifyError.unavailable("Synthetic failure")
        }, run: { arguments in
            XCTAssertEqual(arguments.count, 4)
            return ProcessOutput(status: 0, stdout: "confirmed", stderr: "")
        }, prepare: {})
        for action: MediaAction in [.play, .pause, .nextTrack, .previousTrack, .setShuffle(true), .setShuffle(false)] {
            let result = await controller.execute(action)
            XCTAssertTrue(result.success, result.message)
        }
    }

    func testCollectionRequestsResolveOnlyThenControlNativePlayer() async {
        for action: MediaAction in [.playSong("a \"quote\" $(text)"), .playPlaylist("Gym"), .playLikedSongs, .playLikedWithShuffle(true), .playPlaylistWithShuffle(name: "Gym", enabled: false)] {
            let controller = NativeSpotifyController(resolve: { kind, name, _ in
                if kind == "song" { XCTAssertEqual(name, "a \"quote\" $(text)") }
                return NativeSpotifyLookup.NativeTarget(uri: "spotify:track:test", trackURI: "spotify:track:test")
            }, run: { arguments in
                if case .playLikedSongs = action { XCTAssertEqual(arguments[0], "liked") }
                else if case .playLikedWithShuffle = action { XCTAssertEqual(arguments[0], "liked") }
                else { XCTAssertEqual(arguments[0], "target") }
                XCTAssertEqual(arguments[1], "spotify:track:test")
                if case .playLikedWithShuffle = action { XCTAssertEqual(arguments[3], "true") }
                if case .playPlaylistWithShuffle = action { XCTAssertEqual(arguments[3], "false") }
                return ProcessOutput(status: 0, stdout: "confirmed", stderr: "")
            }, prepare: {})
            let result = await controller.execute(action)
            XCTAssertTrue(result.success, result.message)
        }
    }

    func testAcknowledgementPermissionDenialAndTimeoutAreFailures() async {
        for output in [ProcessOutput(status: 0, stdout: "", stderr: ""),
                       ProcessOutput(status: 1, stdout: "", stderr: "Not authorized (-1743)"),
                       ProcessOutput(status: -1, stdout: "", stderr: "Process timed out")] {
            let controller = NativeSpotifyController(run: { _ in output }, prepare: {})
            let result = await controller.execute(.play)
            XCTAssertFalse(result.success)
            if output.stderr.contains("-1743") { XCTAssertTrue(result.message.contains("Automation")) }
        }
    }

    func testFailedLookupNeverStartsPlayback() async {
        let controller = NativeSpotifyController(resolve: { _, _, _ in throw NativeSpotifyError.unavailable("Synthetic failure") },
            run: { _ in XCTFail("Failed lookup must not start unrelated music"); return ProcessOutput(status: 0, stdout: "confirmed", stderr: "") }, prepare: {})
        let result = await controller.execute(.playLikedSongs)
        XCTAssertFalse(result.success)
    }
}
