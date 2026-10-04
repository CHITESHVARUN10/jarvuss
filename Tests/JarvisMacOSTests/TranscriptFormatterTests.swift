import XCTest
@testable import JarvisMacOS

final class TranscriptFormatterTests: XCTestCase {

    // MARK: - Pass A/B: whitespace + duplicate collapse

    func testDuplicateWordCollapse() {
        let out = TranscriptFormatter.format("the the dog barks")
        XCTAssertEqual(out.text, "The dog barks.")
        XCTAssertGreaterThan(out.fillerRemovals, 0) // duplicates count as cleanups
    }

    func testDuplicateCollapseSkipsAcrossSentenceBoundary() {
        let out = TranscriptFormatter.format("do it. do it again")
        // The two "do it" sentences are not a stutter.
        XCTAssertEqual(out.text, "Do it. Do it again.")
    }

    // MARK: - Pass D: fillers

    /// THE hostile case from the plan: "like" as a verb must survive.
    func testVerbLikeIsKept() {
        let out = TranscriptFormatter.format("I like it")
        XCTAssertEqual(out.text, "I like it.")
    }

    func testHardFillersRemovedOnSight() {
        let out = TranscriptFormatter.format("um so we should uh go then")
        XCTAssertEqual(out.text, "So we should go then.")
    }

    func testCommaDelimitedSoftFillerRemoved() {
        let out = TranscriptFormatter.format("so, like, go now")
        XCTAssertEqual(out.text, "So go now.")
    }

    func testCommaDelimitedPhraseFillerRemoved() {
        let out = TranscriptFormatter.format("the plan was, you know, ambitious, basically unworkable")
        XCTAssertEqual(out.text, "The plan was ambitious, unworkable.")
    }

    func testCommalessLikeIsNotTouched() {
        let out = TranscriptFormatter.format("wait, it is like this")
        XCTAssertEqual(out.text, "Wait, it is like this.")
    }

    // MARK: - Pass C: self-corrections

    func testRetractionWithoutCommaIsLeftToLLM() {
        // No clause punctuation before the marker means the retracted span
        // is unknown to rules — the text is preserved, never half-fixed.
        let out = TranscriptFormatter.format("meet tuesday no wait wednesday")
        XCTAssertEqual(out.text, "Meet Tuesday no wait Wednesday.")
        XCTAssertEqual(out.unboundedCorrections, 1)
        XCTAssertTrue(TranscriptFormatter.shouldUseLLM(out))
    }

    func testRetractionWithComma() {
        let out = TranscriptFormatter.format("push the release tuesday, no wait wednesday")
        XCTAssertEqual(out.text, "Push the release Wednesday.")
        XCTAssertEqual(out.correctionResolves, 1)
    }

    func testRetractionInsideSecondSentence() {
        let out = TranscriptFormatter.format("lovely weather. buy apples, or rather pears")
        XCTAssertEqual(out.text, "Lovely weather. Buy pears.")
    }

    func testRetractionWithNoCorrectionKeepsText() {
        // Trailing-off: a marker with nothing after it is not a correction.
        let out = TranscriptFormatter.format("meet tuesday, scratch that")
        XCTAssertEqual(out.text, "Meet Tuesday, scratch that.")
    }

    func testIMeanIsASoftFillerNotARetraction() {
        let out = TranscriptFormatter.format("use the blue one, i mean, the dark one")
        // "I mean" removed as a comma-delimited filler; the apposition's
        // comma structure is simplified (comma fixing is the LLM pass's job).
        XCTAssertEqual(out.text, "Use the blue one the dark one.")
    }

    // MARK: - Pass E: numbers / units

    func testSpelledPercent() {
        let out = TranscriptFormatter.format("raise the limit twenty five percent")
        XCTAssertEqual(out.text, "Raise the limit 25%.")
    }

    func testSpelledTimeOfDay() {
        let out = TranscriptFormatter.format("call me three pm")
        XCTAssertEqual(out.text, "Call me 3pm.")
    }

    /// Bare spelled counts stay words — they are amounts, addresses, titles.
    func testBareSpelledNumberStaysWords() {
        let out = TranscriptFormatter.format("we printed five thousand pages")
        XCTAssertEqual(out.text, "We printed five thousand pages.")
    }

    // MARK: - Pass F: capitalization

    func testCapitalizesStandaloneI() {
        let out = TranscriptFormatter.format("what am i doing here")
        XCTAssertEqual(out.text, "What am I doing here.")
    }

    func testCapitalizesProperNouns() {
        let out = TranscriptFormatter.format("please open chrome and spotify")
        XCTAssertEqual(out.text, "Please open Chrome and Spotify.")
    }

    // MARK: - Pass G: terminal punctuation

    func testTrailingCommaBecomesPeriod() {
        let out = TranscriptFormatter.format("open the window,")
        XCTAssertEqual(out.text, "Open the window.")
    }

    func testQuotedEndKeepsSentencesCloser() {
        let out = TranscriptFormatter.format("he said stop")
        XCTAssertEqual(out.text, "He said stop.")
    }

    func testPureFillersProduceEmptyText() {
        let out = TranscriptFormatter.format("um uh you know")
        XCTAssertEqual(out.text, "")
    }

    // MARK: - LLM trigger

    func testShouldUseLLMTriggersOnEnumeration() {
        let rules = TranscriptFormatter.format(
            "first buy milk second buy coffee third clean the kitchen")
        XCTAssertTrue(rules.hasEnumeration)
        XCTAssertTrue(TranscriptFormatter.shouldUseLLM(rules))
    }

    func testShouldUseLLMNotForSimpleDictation() {
        let rules = TranscriptFormatter.format("um send the invoice tomorrow please")
        XCTAssertFalse(rules.hasEnumeration)
        XCTAssertFalse(TranscriptFormatter.shouldUseLLM(rules))
    }

    func testShouldUseLLMForLongDisfluentDictation() {
        let rules = TranscriptFormatter.format("um uh meet tuesday, no wait wednesday")
        XCTAssertLessThan(rules.inputWords, 25)
        XCTAssertGreaterThanOrEqual(rules.fillerRemovals, 2)
        XCTAssertGreaterThan(rules.correctionResolves, 0)
        XCTAssertTrue(TranscriptFormatter.shouldUseLLM(rules))
    }

    // MARK: - README read-aloud examples (keep the docs honest)

    func testReadmeLine1FillersAndTime() {
        let out = TranscriptFormatter.format(
            "um so, basically, we should, you know, move the the standup to ten am")
        XCTAssertEqual(out.text, "So we should move the standup to 10am.")
        XCTAssertFalse(TranscriptFormatter.shouldUseLLM(out), "should stay on the fast rules path")
    }

    func testReadmeLine2CommaBoundedCorrection() {
        let out = TranscriptFormatter.format("push the release friday, no wait monday")
        XCTAssertEqual(out.text, "Push the release Monday.")
    }

    func testReadmeLine3LikeVerbAndPercent() {
        let out = TranscriptFormatter.format(
            "i, actually, like the slower version and the new theme is twenty five percent faster")
        XCTAssertEqual(out.text, "I like the slower version and the new theme is 25% faster.")
    }

    func testReadmeLine4UnboundedCorrectionGoesToPolish() {
        let out = TranscriptFormatter.format("also meet thursday no wait friday to review it")
        // Rules deliberately do not guess; the polish pass resolves it.
        XCTAssertEqual(out.text, "Also meet Thursday no wait Friday to review it.")
        XCTAssertTrue(TranscriptFormatter.shouldUseLLM(out))
    }

    func testReadmeLine5EnumerationGoesToPolish() {
        let out = TranscriptFormatter.format(
            "first draft the email second book the room third send the invites")
        XCTAssertTrue(out.hasEnumeration)
        XCTAssertTrue(TranscriptFormatter.shouldUseLLM(out))
    }

    func testReadmeShortChecks() {
        XCTAssertEqual(TranscriptFormatter.format("i like it").text, "I like it.")
        // "chrome" is a known proper noun (the browser) — capitalized on purpose.
        XCTAssertEqual(TranscriptFormatter.format("um open chrome please").text, "Open Chrome please.")
        XCTAssertEqual(TranscriptFormatter.format("the the dog").text, "The dog.")
    }
}
