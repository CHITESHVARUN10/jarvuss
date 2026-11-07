import XCTest
@testable import JarvisMacOS

/// Stable contract checks run in CI without local migration snapshots or OS actions.
final class RustPurePolicyTests: XCTestCase {
    func testVolumeNumbersAndWhitespaceKeepTheExistingBoundaries() {
        for n in 0...100 { XCTAssertEqual(SystemVolumeParser.number(String(n)), n) }
        for s in ["-1", "101", "1000", "1.5", "twenty ten", "ninety zero", "nineteen\n", "nineteen\u{85}"] {
            XCTAssertNil(SystemVolumeParser.number(s), s)
        }
        XCTAssertEqual(SystemVolumeParser.number("\u{200b}nineteen\u{200b}"), 19)
        XCTAssertEqual(SystemVolumeParser.route("raise output volume to nineteen"), .volumeControl(.setLevel(19)))
        XCTAssertEqual(SystemVolumeParser.route("raise output volume by nineteen"), .volumeControl(.increase(by: 19)))
        XCTAssertNil(SystemVolumeParser.route("raise Spotify volume by nineteen"))
    }

    func testWorkspaceAndShufflePreserveLiteralUnicodeNames() {
        let name = "Café 🧑🏽‍💻 and Research"
        XCTAssertEqual(WorkspaceCommandParser.parse("open \"\(name)\" project from \"Drive A\" in VS Code"),
                       WorkspaceCommand(operation: .openProject, app: .vscode, project: name, root: "Drive A"))
        XCTAssertEqual(SpotifyShuffleParser.parse("play playlist called \"\(name)\" with shuffle off"),
                       .playPlaylistWithShuffle(name: name, enabled: false))
        XCTAssertNil(SpotifyShuffleParser.parse("shuffle Research playlist and open Notes"))
        XCTAssertEqual(SpotifyShuffleParser.parse("play my liked songs with shuffle on"), .playLikedWithShuffle(true))
    }

    func testSearchLiteralsScopesAndSizeLimitsAreIndependent() {
        let request = LocalSearchParser.search("search for files called \"yesterday in Downloads\"")
        XCTAssertEqual(request?.query, "yesterday in Downloads")
        XCTAssertEqual(request?.date, .any)
        XCTAssertEqual(request?.scopes, [])
        let filtered = LocalSearchParser.search("find PDFs mentioning curves in Downloads under 1.5 MB")
        XCTAssertEqual(filtered?.query, "curves")
        XCTAssertEqual(filtered?.scopes, ["Downloads"])
        XCTAssertEqual(filtered?.kind, .pdf)
        XCTAssertEqual(filtered?.maximumBytes, 1_500_000)
        XCTAssertNil(LocalSearchParser.search("find documents under 9223372036854775808 bytes"))
        XCTAssertEqual(LocalSearchParser.selection("preview the second file"), FileResultSelection(operation: .preview, index: 2))
        XCTAssertNil(LocalSearchParser.selection("101st file"))
    }

    func testTranscriptFoundationCompatibilityAndLiteralTargets() {
        XCTAssertEqual(TranscriptSanitizer.normalizeMisheardTargets(in: "open chant gpt\n"), "open ChatGPT")
        for suffix in ["\r", "\r\n", "\u{000b}", "\u{000c}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertEqual(TranscriptSanitizer.normalizeMisheardTargets(in: "open chant gpt" + suffix), "open ChatGPT")
        }
        XCTAssertEqual(TranscriptSanitizer.sanitizeSpokenCommand("\u{200b}open Notes\u{200b}"), "open Notes")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedWords("cafe\u{301} café cafe\u{301}"), "cafe\u{301}")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedPhrases("go now GO NOW go now"), "go now")
        XCTAssertEqual(TranscriptSanitizer.normalizeMisheardTargets(in: "open Brief project in Finder"), "open Brief project in Finder")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedPhrases("a b a b a b", minRepeats: 0), "a b a b a b")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedPhrases(" a b a b a b ", maxPhraseWords: 1), "a b a b a b")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedPhrases(" a b   c d ", minRepeats: 1), "a b c d")
    }

    func testRoutineValidationAndBatchKeepExecutionSemantics() {
        XCTAssertNil(AutomationAction(type: .playSong, value: "Blue Monday").validationMessage)
        XCTAssertNotNil(AutomationAction(type: .playSong, value: " ").validationMessage)
        XCTAssertNotNil(AutomationAction(type: .openWebsiteChrome, value: "file:///tmp/a").validationMessage)
        XCTAssertEqual(AutomationAction(type: .openWebsiteChrome, value: "example.com").websiteURL, "https://example.com")
        XCTAssertEqual(AutomationAction(type: .openWebsiteChrome, value: "HTTP://example.com").websiteURL, "HTTP://example.com")
        XCTAssertEqual(TranscriptSanitizer.sanitizeBatch(["open Notes", "close Notes", "next", "next"]), ["close Notes", "next", "next"])
        XCTAssertEqual(TranscriptSanitizer.sanitizeBatch(["next"], maxBatchSize: 0), [])
        var logs: [String] = []
        XCTAssertEqual(TranscriptSanitizer.sanitizeBatch(["open café", "close cafe\u{301}"], onLog: { logs.append($0) }), ["close cafe\u{301}"])
        XCTAssertEqual(Array(logs[0].utf8), Array("[Conflict] resolved: cafe\u{301} open → close (last wins)".utf8))
    }
}
