import XCTest
@testable import JarvisMacOS

/// The app decides when the model may typeset a list, and sends the
/// directive itself. These tests pin that decision.
final class ListDirectiveTests: XCTestCase {

    func testOrdinalMarkersRequestNumberedList() {
        XCTAssertEqual(
            TranscriptFormatter.listDirective(
                for: "things to buy first milk second eggs third bread"),
            .numbered)
        XCTAssertEqual(
            TranscriptFormatter.listDirective(
                for: "first point is this is broken second point is this third point"),
            .numbered)
        XCTAssertEqual(
            TranscriptFormatter.listDirective(
                for: "there are three updates firstly the build is green finally staging is down"),
            .numbered)
    }

    func testPointOneTwoRequestNumberedList() {
        XCTAssertEqual(
            TranscriptFormatter.listDirective(
                for: "three updates point one the build is green point two staging is down"),
            .numbered)
        XCTAssertEqual(
            TranscriptFormatter.listDirective(
                for: "recap point 1 ship friday point 2 reviews done"),
            .numbered)
    }

    func testSpokenBulletRequestWinsOverOrdinals() {
        XCTAssertEqual(
            TranscriptFormatter.listDirective(for: "give this to me as bullet points milk eggs bread"),
            .bullets)
        XCTAssertEqual(
            TranscriptFormatter.listDirective(for: "bullet point list first one second one"),
            .bullets)
    }

    func testExplicitNumberedListRequest() {
        XCTAssertEqual(
            TranscriptFormatter.listDirective(for: "put this in a numbered list buy milk book room"),
            .numbered)
    }

    func testPlainProseGetsNoDirective() {
        XCTAssertNil(TranscriptFormatter.listDirective(for: "i need milk eggs and bread"))
        XCTAssertNil(TranscriptFormatter.listDirective(for: "we should meet on monday"))
        XCTAssertNil(TranscriptFormatter.listDirective(for: "the grace period ends friday"))
        // A single ordinal alone is not a list.
        XCTAssertNil(TranscriptFormatter.listDirective(for: "first snow of the year today"))
    }

    func testParagraphIntentIsNeverForcedIntoAList() {
        // "first paragraph … second paragraph …" carries two ordinals, but
        // paragraph intent beats list intent — a forced list would mangle it.
        XCTAssertNil(TranscriptFormatter.listDirective(
            for: "first paragraph we need to ship by friday second paragraph the designs are not final"))
    }

    func testDirectiveForcesTheLLMPass() {
        let rules = TranscriptFormatter.format("hi")
        XCTAssertFalse(TranscriptFormatter.shouldUseLLM(rules),
                       "clean short text needs no model by itself")
        XCTAssertTrue(TranscriptFormatter.shouldUseLLM(rules, directive: .bullets),
                      "an app directive always earns the model pass")
    }
}
