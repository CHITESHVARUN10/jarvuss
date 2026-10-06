import XCTest
@testable import JarvisMacOS

/// Regression tests for the failures observed in log.txt on 2026-10-01:
/// long compound commands silently rejected, garbage song titles, and the
/// file-exploration questions the user asked for.
final class CompoundAndFileQueryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestSupport.pinRustPipelineOff()
    }

    override func tearDown() {
        TestSupport.unpinRustPipeline()
        super.tearDown()
    }

    // MARK: - Validator gate

    func testLongCompoundCommandIsAccepted() {
        let spoken = "open spotify, open whatsapp and also open youtube and in spotify play a song"
        XCTAssertEqual(CommandValidator.validate(spoken), spoken,
                       "multi-intent speech must survive the validator")
    }

    func testCompoundWithPolitenessIsCleanedNotRejected() {
        let spoken = "Open Chrome and in Chrome open YouTube and in that search for iPhone. Thank you."
        let cleaned = CommandValidator.validate(spoken)
        XCTAssertNotNil(cleaned)
        XCTAssertFalse(cleaned!.lowercased().contains("thank"))
    }

    func testSingleVerbRunOnIsStillRejected() {
        XCTAssertNil(CommandValidator.validate(
            "open the thing i was telling you about yesterday afternoon mate"))
    }

    // MARK: - Compound splitting

    func testCompoundSplitsIntoOrderedIntentParts() {
        let planner = ActionPlanner()
        let parts = planner.debugSplitByConjunction(
            "open spotify, open whatsapp and also open youtube and in spotify play a song")

        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "open spotify")
        XCTAssertEqual(parts[1], "open whatsapp")
        XCTAssertEqual(parts[2], "open youtube", "'also' is a connector, not an action")
        XCTAssertEqual(parts[3], "play a song",
                       "the 'in spotify' preamble is stripped — it is context, not the action")
    }

    func testCommaInsideAQueryIsNotASplit() {
        let planner = ActionPlanner()
        let parts = planner.debugSplitByConjunction("search for iphone 18 pro, blue colour")
        XCTAssertEqual(parts, ["search for iphone 18 pro, blue colour"])
    }

    // MARK: - Media titles

    func testGenericPlaySongDoesNotBecomeATitle() {
        let planner = ActionPlanner()
        XCTAssertEqual(planner.debugMediaCommand("in spotify, could you play a song for me?"),
                       .mediaControl(.play))
        XCTAssertEqual(planner.debugMediaCommand("play a song from spotify"),
                       .mediaControl(.play))
        XCTAssertEqual(planner.debugMediaCommand("please play some music"),
                       .mediaControl(.play))
    }

    func testRealTitlesSurvive() {
        let planner = ActionPlanner()
        XCTAssertEqual(planner.debugMediaCommand("play wonderwall on spotify"),
                       .mediaControl(.playSong("wonderwall")))
        XCTAssertEqual(planner.debugMediaCommand("play shape of you"),
                       .mediaControl(.playSong("shape of you")))
        XCTAssertEqual(planner.debugMediaCommand("play blinding lights"),
                       .mediaControl(.playSong("blinding lights")))
    }

    // MARK: - File queries

    func testFileQuestionParsing() {
        let planner = ActionPlanner()
        XCTAssertEqual(planner.debugFileQuery("how many files are there in my downloads folder"),
                       .fileQuery(FileQuery(op: .count, folder: "downloads")))
        XCTAssertEqual(planner.debugFileQuery("how many folders are in my downloads folder"),
                       .fileQuery(FileQuery(op: .countFolders, folder: "downloads")))
        XCTAssertEqual(planner.debugFileQuery("what is the latest ppt i have"),
                       .fileQuery(FileQuery(op: .newest, folder: "downloads", ext: "pptx")))
        XCTAssertEqual(planner.debugFileQuery("what is the oldest pdf i have"),
                       .fileQuery(FileQuery(op: .oldest, folder: "downloads", ext: "pdf")))
        XCTAssertEqual(planner.debugFileQuery("open the recent pdf in downloads"),
                       .fileQuery(FileQuery(op: .openNewest, folder: "downloads", ext: "pdf")))
        XCTAssertEqual(planner.debugFileQuery("list all the files in my documents folder"),
                       .fileQuery(FileQuery(op: .list, folder: "documents")))
    }

    func testNonFileQuestionsAreNotSwallowed() {
        let planner = ActionPlanner()
        XCTAssertNil(planner.debugFileQuery("open spotify"))
        XCTAssertNil(planner.debugFileQuery("what is the time"))
    }

    /// The exact ⌘⇧A utterance that reached Qwen — and then a raw Ollama
    /// transport error — when the Rust cut-over flag was on. The rule layer
    /// must answer it locally, with no model in the loop, and the default
    /// folder must be the one that gets NAMED in the answer (Downloads).
    func testFolderlessCountsDefaultToDownloads() {
        let planner = ActionPlanner()
        XCTAssertEqual(planner.debugFileQuery("how many folders do i have"),
                       .fileQuery(FileQuery(op: .countFolders, folder: "downloads")))
        XCTAssertEqual(planner.debugFileQuery("how many files do i have"),
                       .fileQuery(FileQuery(op: .count, folder: "downloads")))
    }

    /// End-to-end: the phrase routes locally BEFORE the learned model is
    /// consulted, so it can never depend on Ollama being up — that dependency
    /// is exactly what produced a raw transport error instead of an answer.
    func testFolderQuestionRoutesLocallyEndToEnd() async {
        let planner = ActionPlanner()
        let plan = await planner.plan(from: "how many folders do I have")
        XCTAssertEqual(plan, [.fileQuery(FileQuery(op: .countFolders, folder: "downloads"))])
    }

    // MARK: - End-to-end rule plan (the whole point of the fix)

    func testCompoundProducesAllFourOrderedActions() {
        let planner = ActionPlanner()
        let plan = planner.rulePlanForTesting(
            "open spotify, open whatsapp and also open youtube and in spotify play a song")

        XCTAssertEqual(plan?.count, 4, "got \(String(describing: plan))")
        XCTAssertEqual(plan?[0], .openApp("Spotify"))
        XCTAssertEqual(plan?[1], .openApp("WhatsApp"))
        XCTAssertEqual(plan?[2], .openURL("https://www.youtube.com"),
                       "YouTube is a website — it opens in the browser")
        XCTAssertEqual(plan?[3], .mediaControl(.play),
                       "a generic 'play a song' must not invent a title")
    }

    func testChromeCompoundPlanKeepsTheSearchQuery() {
        let planner = ActionPlanner()
        let plan = planner.rulePlanForTesting(
            "open chrome and in chrome open youtube and in that search for iphone 18 pro")
        XCTAssertEqual(plan?.count, 3, "got \(String(describing: plan))")
        XCTAssertEqual(plan?[0], .openApp("Google Chrome"))
        XCTAssertEqual(plan?[1], .openURL("https://www.youtube.com"))
        // "in that" refers to YouTube; the rules resolve the clause literally
        // (Google search) — the learned model is what resolves the reference
        // to a single web.search(YouTube, …), as the compound dataset teaches.
        if case .searchWeb(_, let query)? = plan?[2] {
            XCTAssertTrue(query.contains("iphone"), query)
        } else {
            XCTFail("expected a web search, got \(String(describing: plan))")
        }
    }

    func testAppPlusBrightnessCompound() {
        let planner = ActionPlanner()
        let plan = planner.rulePlanForTesting("open spotify and also increase the brightness by 5 percent")
        XCTAssertEqual(plan?.count, 2, "got \(String(describing: plan))")
        XCTAssertEqual(plan?[0], .openApp("Spotify"))
        XCTAssertEqual(plan?[1], .displayControl(.increaseBrightness(by: 5)))
    }

    func testAppAndVolumeCompound() {
        let planner = ActionPlanner()
        let plan = planner.rulePlanForTesting("open notes and increase the volume by 20 percent")
        XCTAssertEqual(plan?.count, 2, "got \(String(describing: plan))")
        XCTAssertEqual(plan?[0], .openApp("Notes"))
        XCTAssertEqual(plan?[1], .volumeControl(.increase(by: 20)))
    }

    func testFileQuestionPlanViaRules() {
        let planner = ActionPlanner()
        XCTAssertEqual(planner.rulePlanForTesting("how many files are there in my downloads folder"),
                       [.fileQuery(FileQuery(op: .count, folder: "downloads"))])
        XCTAssertEqual(planner.rulePlanForTesting("what is the latest ppt i have"),
                       [.fileQuery(FileQuery(op: .newest, folder: "downloads", ext: "pptx"))])
    }

    // MARK: - FileExplorer against a real temporary folder

    func testFileExplorerCountsAndSorts() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis-files-test-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let older = tmp.appendingPathComponent("old.pdf")
        let newer = tmp.appendingPathComponent("new.pdf")
        let deck = tmp.appendingPathComponent("deck.pptx")
        try Data(repeating: 0x41, count: 1024).write(to: older)
        try Data(repeating: 0x42, count: 4096).write(to: newer)
        try Data(repeating: 0x43, count: 2048).write(to: deck)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("nested"),
                                                withIntermediateDirectories: true)
        // Deterministic timestamps: deck newest, old.pdf oldest.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: older.path)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(60)],
                                              ofItemAtPath: deck.path)
        try FileManager.default.setAttributes([.modificationDate: base.addingTimeInterval(120)],
                                              ofItemAtPath: newer.path)

        let countAll = FileExplorer.answer(op: .count, folder: tmp, ext: "")
        XCTAssertTrue(countAll.message.contains("3 file"), countAll.message)

        let countPdf = FileExplorer.answer(op: .count, folder: tmp, ext: "pdf")
        XCTAssertTrue(countPdf.message.contains("2 PDF"), countPdf.message)

        let folders = FileExplorer.answer(op: .countFolders, folder: tmp, ext: "")
        XCTAssertTrue(folders.message.contains("1 folder"), folders.message)

        let oldest = FileExplorer.answer(op: .oldest, folder: tmp, ext: "pdf")
        XCTAssertTrue(oldest.message.contains("old.pdf"), oldest.message)

        let newest = FileExplorer.answer(op: .newest, folder: tmp, ext: "pdf")
        XCTAssertTrue(newest.message.contains("new.pdf"), newest.message)

        let largest = FileExplorer.answer(op: .largest, folder: tmp, ext: "")
        XCTAssertTrue(largest.message.contains("new.pdf"), largest.message)

        let opened = FileExplorer.answer(op: .openNewest, folder: tmp, ext: "pptx")
        XCTAssertEqual(opened.open?.lastPathComponent, "deck.pptx")

        // The model says "ppt" and "jpeg"; the files on disk say "pptx"/"jpg".
        XCTAssertEqual(FileExplorer.canonicalExtension("ppt"), "pptx")
        XCTAssertEqual(FileExplorer.canonicalExtension("JPEG"), "jpg")
        let spokenPpt = FileExplorer.answer(op: .count, folder: tmp, ext: "ppt")
        XCTAssertTrue(spokenPpt.message.contains("1 PPTX"), spokenPpt.message)
    }
}
