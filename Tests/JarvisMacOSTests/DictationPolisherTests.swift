import XCTest
@testable import JarvisMacOS

final class DictationPolisherTests: XCTestCase {

    private static let reference = "We should push the release to Wednesday."

    func testCleanOutputPasses() {
        let (text, reasons) = DictationPolisher.sanitize(
            "we should push the release to Wednesday.", referenceText: Self.reference)
        XCTAssertEqual(text, "we should push the release to Wednesday.")
        XCTAssertTrue(reasons.isEmpty, reasons.description)
    }

    func testEmptyOutputRejected() {
        let (text, reasons) = DictationPolisher.sanitize("   ", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.contains("empty"))
    }

    func testMetaPrefixRejected() {
        // "Here is" — the model answered instead of cleaning; also make sure
        // it would have failed the length gate anyway if the wrapper hid it.
        let (text, reasons) = DictationPolisher.sanitize(
            "Here is the cleaned text: We should push the release to Wednesday.",
            referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.contains(where: { $0.hasPrefix("meta:") }))
    }

    func testApologyRejected() {
        let (text, reasons) = DictationPolisher.sanitize(
            "I'm sorry, I cannot rewrite text.", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.first?.hasPrefix("meta:") ?? false)
    }

    func testLengthDriftRejected() {
        // 2.4x shorter than the reference — the contract is cleanup, not
        // summary; this catches silent summarisation.
        let (text, reasons) = DictationPolisher.sanitize(
            "Push Wednesday.", referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertTrue(reasons.contains(where: { $0.hasPrefix("length-drift") }))
    }

    func testCodeFenceStripped() {
        let (text, reasons) = DictationPolisher.sanitize(
            "```text\nWe should push the release to Wednesday.\n```",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("fence-stripped"))
    }

    func testQuoteWrapStripped() {
        let (text, reasons) = DictationPolisher.sanitize(
            "\"We should push the release to Wednesday.\"", referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("quote-unwrap"))
    }

    func testThinkWrapperStripped() {
        // Qwen-family thinking tags are built by ASCII code so this test and
        // the formatter share the exact characters without transcription risk.
        let open = String(decoding: [0x3C, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let close = String(decoding: [0x3C, 0x2F, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let (text, reasons) = DictationPolisher.sanitize(
            open + "step by step" + close + "\nWe should push the release to Wednesday.",
            referenceText: Self.reference)
        XCTAssertEqual(text, "We should push the release to Wednesday.")
        XCTAssertTrue(reasons.contains("think-stripped"))
    }

    func testThinkOnlyOutputRejected() {
        let open = String(decoding: [0x3C, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let close = String(decoding: [0x3C, 0x2F, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E], as: UTF8.self)
        let (text, reasons) = DictationPolisher.sanitize(
            open + "the user said something" + close, referenceText: Self.reference)
        XCTAssertNil(text)
        XCTAssertEqual(reasons, ["think-only"])
    }

    func testUnwrappedQuoteKeptWhenQuoteAppearsInBody() {
        // A quote character INSIDE the body means it is a real quotation, not
        // a wrapper — never strip those.
        let (text, _) = DictationPolisher.sanitize(
            "\"He told me to 'push it' fast.\"", referenceText: Self.reference)
        XCTAssertNotNil(text)
    }
}
