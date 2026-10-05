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
