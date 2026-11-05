import XCTest
@testable import JarvisMacOS

final class TranscriptSanitizerTests: XCTestCase {
    func testNormalizeCompact() {
        XCTAssertEqual(TranscriptSanitizer.normalizeCompact("Hello, World!"), "helloworld")
        XCTAssertEqual(TranscriptSanitizer.normalizeCompact("Thank you."), "thankyou")
    }

    func testHallucinatedSingletons() {
        XCTAssertTrue(TranscriptSanitizer.isHallucinatedSingleton("Thank you."))
        XCTAssertTrue(TranscriptSanitizer.isHallucinatedSingleton("thanks for watching"))
        XCTAssertFalse(TranscriptSanitizer.isHallucinatedSingleton("open chrome"))
    }

    func testContainsWakeWord() {
        XCTAssertTrue(TranscriptSanitizer.containsWakeWord("hey jarvis open chrome"))
        XCTAssertTrue(TranscriptSanitizer.containsWakeWord("Jarvis"))
        XCTAssertFalse(TranscriptSanitizer.containsWakeWord("open chrome"))
    }

    func testCollapseRepeatedWords() {
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedWords("the the dog"), "the dog")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedWords("open open chrome"), "open chrome")
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedWords("open chrome"), "open chrome")
    }

    func testCollapseRepeatedPhraseLoop() {
        let loop = "a little bit of a little bit of a little bit of a little bit of"
        XCTAssertEqual(TranscriptSanitizer.collapseRepeatedPhrases(loop), "a little bit of")
        XCTAssertEqual(
            TranscriptSanitizer.collapseRepeatedPhrases("please send it please send it please send it"),
            "please send it"
        )
    }

    func testTwoDeliberatePhraseRepeatsAreKept() {
        XCTAssertEqual(
            TranscriptSanitizer.collapseRepeatedPhrases("very good very good"),
            "very good very good"
        )
    }

    func testPhraseLoopComparisonIgnoresCase() {
        XCTAssertEqual(
            TranscriptSanitizer.collapseRepeatedPhrases("Little bit of little bit of LITTLE BIT OF"),
            "Little bit of"
        )
    }

    func testRemoveTrailingWakeWordFragment() {
        XCTAssertEqual(TranscriptSanitizer.removeTrailingWakeWordFragment(from: "open spotify jarv"), "open spotify")
        XCTAssertEqual(TranscriptSanitizer.removeTrailingWakeWordFragment(from: "open spotify"), "open spotify")
    }

    func testNormalizeMisheardTargets() {
        XCTAssertEqual(
            TranscriptSanitizer.normalizeMisheardTargets(in: "open get her desktop"),
            "open GitHub Desktop"
        )
        XCTAssertEqual(
            TranscriptSanitizer.normalizeMisheardTargets(in: "open chrome"),
            "open chrome"
        )
    }

    func testKnownMishearingsOnlyChangeCommandTargets() {
        let examples = [
            "open chant GPT": "open ChatGPT",
            "launch changpt": "launch ChatGPT",
            "close brief": "close Brave Browser",
            "open chat gpt in breif": "open ChatGPT in Brave Browser",
            "open a new tab in beave": "open a new tab in Brave Browser",
        ]
        for (raw, expected) in examples {
            XCTAssertEqual(TranscriptSanitizer.normalizeMisheardTargets(in: raw), expected)
        }
        for raw in ["search google for brief", "open my brief project in VS Code",
                    "open chant gpt project in Finder", "write a brief in the document",
                    "open \"brief\"", "open get her desktop and close spotify"] {
            XCTAssertEqual(TranscriptSanitizer.normalizeMisheardTargets(in: raw), raw)
        }
        XCTAssertEqual(TranscriptSanitizer.cleanVoiceSegment("um open chant GPT please"), "open ChatGPT")
    }

    func testCleanVoiceSegmentStripsFillers() {
        XCTAssertEqual(
            TranscriptSanitizer.cleanVoiceSegment("um open chrome please"),
            "open chrome"
        )
    }

    func testCleanVoiceSegmentRejectsEmpty() {
        XCTAssertNil(TranscriptSanitizer.cleanVoiceSegment(""))
        XCTAssertNil(TranscriptSanitizer.cleanVoiceSegment("   "))
    }

    func testSanitizeBatchPreservesRepeatedMediaAndVolumeActions() {
        XCTAssertEqual(TranscriptSanitizer.sanitizeBatch(["next song", "next song", "volume up"]),
                       ["next song", "next song", "volume up"])
    }

    func testSanitizeBatchDedupsLastWins() {
        var notices: [String] = []
        let out = TranscriptSanitizer.sanitizeBatch(
            ["open chrome", "open chrome"],
            onLog: { notices.append($0) }
        )
        XCTAssertEqual(out, ["open chrome"])
        XCTAssertTrue(notices.contains(where: { $0.contains("sanitized") }))
    }

    func testSanitizeBatchResolvesAppConflictLastWins() {
        var notices: [String] = []
        let out = TranscriptSanitizer.sanitizeBatch(
            ["open spotify", "close spotify"],
            onLog: { notices.append($0) }
        )
        XCTAssertEqual(out, ["close spotify"])
        XCTAssertTrue(notices.contains(where: { $0.contains("[Conflict]") }))
    }

    func testSanitizeBatchCapsToMax() {
        var notices: [String] = []
        let out = TranscriptSanitizer.sanitizeBatch(
            ["explain a", "explain b", "explain c", "explain d"],
            maxBatchSize: 3,
            onLog: { notices.append($0) }
        )
        XCTAssertEqual(out, ["explain b", "explain c", "explain d"])
        XCTAssertTrue(notices.contains(where: { $0.contains("capped") }))
    }

    func testSanitizeBatchPreservesOrder() {
        let out = TranscriptSanitizer.sanitizeBatch(["open chrome", "explain recursion"])
        XCTAssertEqual(out, ["open chrome", "explain recursion"])
    }
}
