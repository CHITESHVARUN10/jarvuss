import XCTest
@testable import JarvisMacOS

final class DictationPolisherTests: XCTestCase {

    private static let reference = "We should push the release to Wednesday."

    func testCleanOutputPasses() {
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>we should push the release to Wednesday.</cleaned>",
            referenceText: Self.reference)
        XCTAssertEqual(text, "we should push the release to Wednesday.")
        XCTAssertTrue(reasons.isEmpty, reasons.description)
    }

    func testEmptyOutputRejected() {
        let (text, reasons) = DictationPolisher.sanitize("   ", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.contains("empty"))
    }

    func testMissingCleanedTagRejected() {
        // The prompt contract is <cleaned>…</cleaned>; unwrapped output means
        // the contract failed — the rules text must win.
        let (text, reasons) = DictationPolisher.sanitize(
            "We should push the release to Wednesday.", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertEqual(reasons, ["no-cleaned-tag"])
    }

    func testMalformedCloserRecovered() {
        // Live qwen2.5:1.5b glitch: it closed the tag with " />" instead of
        // "</cleaned>". The body is still recovered and guarded.
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>We should push the release to Wednesday. />",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("cleaned-malformed"))
    }

    func testLastCleanedBlockWins() {
        // Some models echo the example format first; the last block is the answer.
        let (text, _) = DictationPolisher.sanitize(
            "<cleaned>Things to buy</cleaned>\n<cleaned>We should push the release to Wednesday.</cleaned>",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
    }

    func testMetaPrefixRejected() {
        // "Here is" — the model answered instead of cleaning; also make sure
        // it would have failed the length gate anyway if the wrapper hid it.
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>Here is the cleaned text: We should push the release to Wednesday.</cleaned>",
            referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.contains(where: { $0.hasPrefix("meta:") }))
    }

    func testApologyRejected() {
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>I'm sorry, I cannot rewrite text.</cleaned>", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.first?.hasPrefix("meta:") ?? false)
    }

    func testLengthDriftRejected() {
        // 2.4x shorter than the reference — the contract is cleanup, not
        // summary; this catches silent summarisation.
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>Push Wednesday.</cleaned>", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.contains(where: { $0.hasPrefix("length-drift") }))
    }

    func testCodeFenceStripped() {
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>```text\nWe should push the release to Wednesday.\n```</cleaned>",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("fence-stripped"))
    }

    func testQuoteWrapStripped() {
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>\"We should push the release to Wednesday.\"</cleaned>",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("quote-unwrap"))
    }

    func testThinkWrapperStripped() {
        // Qwen-family thinking tags are built by ASCII code so this test and
        // the formatter share the exact characters without transcription risk.
        let open = String(decoding: [0x3C, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let close = String(decoding: [0x3C, 0x2F, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>" + open + "step by step" + close + "\nWe should push the release to Wednesday.</cleaned>",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("think-stripped"))
    }

    func testThinkOnlyOutputRejected() {
        let open = String(decoding: [0x3C, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let close = String(decoding: [0x3C, 0x2F, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>" + open + "the user said something" + close + "</cleaned>",
            referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertEqual(reasons, ["think-only"])
    }

    func testUnwrappedQuoteKeptWhenQuoteAppearsInBody() {
        // A quote character INSIDE the body means it is a real quotation, not
        // a wrapper — never strip those.
        let (text, _) = DictationPolisher.sanitize(
            "<cleaned>\"He told me to 'push it' fast.\"</cleaned>", referenceText: Self.reference)
        XCTAssertNotNil(text)
    }

    func testListExampleSurvivesFormatting() {
        // The prompt's list example, end to end: tags unwrap, the list keeps
        // its line structure, and no period is appended after the last item.
        let (text, reasons) = DictationPolisher.sanitize(
            "<cleaned>Things to buy:\n1. Milk\n2. Eggs\n3. Bread</cleaned>",
            referenceText: "things to buy first milk second eggs third bread")
        XCTAssertNotNil(text, reasons.description)
        XCTAssertEqual(
            TranscriptFormatter.recapitalize(text!),
            "Things to buy:\n1. Milk\n2. Eggs\n3. Bread")
    }
}
