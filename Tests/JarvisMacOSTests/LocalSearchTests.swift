import XCTest
@testable import JarvisMacOS

final class LocalSearchParsingTests: XCTestCase {
    func testUserExamplesKeepNamesScopesTypesAndFilters() {
        XCTAssertEqual(LocalSearchParser.route("open Bluetooth settings"), .openSettings(.bluetooth))
        XCTAssertEqual(LocalSearchParser.search("find the SLA stage 2 document"), LocalSearchRequest(query: "SLA stage 2"))
        XCTAssertEqual(LocalSearchParser.search("find the file that mentions elliptic curves"), LocalSearchRequest(query: "elliptic curves", mode: .content))
        XCTAssertEqual(LocalSearchParser.search("PDFs from last week"), LocalSearchRequest(kind: .pdf, date: .lastWeek))
        XCTAssertEqual(LocalSearchParser.search("presentations bigger than 20 MB"), LocalSearchRequest(kind: .presentation, minimumBytes: 20_000_000))
        XCTAssertEqual(LocalSearchParser.search("find a PPT in my downloads or my documents or d drive"), LocalSearchRequest(kind: .presentation, scopes: ["downloads", "documents", "d drive"]))
        XCTAssertEqual(LocalSearchParser.search("find a PPT that may be in my downloads or documents"), LocalSearchRequest(kind: .presentation, scopes: ["downloads", "documents"]))
        XCTAssertEqual(LocalSearchParser.search("find presentations maybe in either downloads or d drive"), LocalSearchRequest(kind: .presentation, scopes: ["downloads", "d drive"]))
        XCTAssertEqual(LocalSearchParser.search("find PDFs containing elliptic curves in documents"), LocalSearchRequest(query: "elliptic curves", mode: .content, kind: .pdf, scopes: ["documents"]))
        XCTAssertEqual(LocalSearchParser.search("find PDFs in downloads that mention elliptic curves"), LocalSearchRequest(query: "elliptic curves", mode: .content, kind: .pdf, scopes: ["downloads"]))
    }

    func testAllNewDatasetLabelsAndHeldOutPhrasesRouteLocally() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["dataset/train-066-native-search.jsonl", "dataset/train-067-settings-panes.jsonl", "dataset/train-068-result-selection.jsonl", "dataset/train-069-native-navigation.jsonl", "training/eval_native_search.jsonl"] {
            for line in try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).split(separator: "\n") {
                let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let intents = row["intents"] as! [[String: Any]]
                let expected = IntentActionMapper.map([["name": intents[0]["name"]!, "args": row["resolved_args"]!]])
                XCTAssertNotNil(expected, String(line))
                XCTAssertEqual(IntentActionMapper.map(intents, sourceText: row["text"] as? String), expected)
                XCTAssertEqual(LocalSearchParser.route(row["text"] as! String).map { [$0] }, expected, row["text"] as! String)
            }
        }
    }

    func testOrdinalsAreWholeUtterancesAndRequireRuntimeContext() {
        XCTAssertEqual(LocalSearchParser.selection("the second one"), FileResultSelection(operation: .open, index: 2))
        XCTAssertEqual(LocalSearchParser.selection("preview it"), FileResultSelection(operation: .preview, index: 0))
        XCTAssertEqual(LocalSearchParser.selection("open result 14"), FileResultSelection(operation: .open, index: 14))
        XCTAssertNil(LocalSearchParser.selection("don't open the first one"))
        XCTAssertNil(LocalSearchParser.selection("open the first one and run terminal"))
        XCTAssertNil(LocalSearchParser.selection("open result 101"))
        XCTAssertNil(LocalSearchParser.selection("preview the file named first one"))
    }

    func testQuotedSearchTextCannotBecomeAnUnrequestedFolderOrDate() {
        XCTAssertEqual(LocalSearchParser.search("find files containing \"yesterday in Downloads\""),
            LocalSearchRequest(query: "yesterday in Downloads", mode: .content))
        XCTAssertEqual(LocalSearchParser.search("find the file named \"meeting notes\" in documents"),
            LocalSearchRequest(query: "meeting notes", scopes: ["documents"]))
    }

    func testSearchDoesNotStealWebCountsOrCompoundActions() {
        XCTAssertNil(LocalSearchParser.route("search google for elliptic curves"))
        XCTAssertNil(LocalSearchParser.route("how many PDFs are in downloads"))
        XCTAssertNil(LocalSearchParser.route("find PDFs and open Spotify"))
        XCTAssertNil(LocalSearchParser.route("don't find my documents"))
        XCTAssertNil(LocalSearchParser.route("what is Bluetooth"))
        XCTAssertNil(SystemSettingsPane.parse("open arbitrary custom settings"))
        XCTAssertNil(IntentActionMapper.map([["name": "files.result", "args": [:]]], sourceText: "play a song"))
        XCTAssertNil(IntentActionMapper.map([["name": "files.search", "args": [:]]]))
        XCTAssertNil(IntentActionMapper.map([["name": "files.result", "args": ["action": "open", "index": 2]]], sourceText: "preview the first one"))
    }

    func testStructuredSearchRejectsInvalidFiltersAndBindsPredicateValues() {
        let request = LocalSearchRequest(query: "x' OR TRUEPREDICATE OR name = '", kind: .pdf, minimumBytes: 100, maximumBytes: 200)
        let predicate = request.predicate()
        XCTAssertFalse(predicate.evaluate(with: ["kMDItemFSName": "invoice.pdf", "kMDItemContentTypeTree": ["com.adobe.pdf"], "kMDItemContentType": "com.adobe.pdf", "kMDItemFSSize": 150]))
        var args = request.arguments
        args["min_bytes"] = -1
        XCTAssertNil(LocalSearchRequest(arguments: args))
        args["min_bytes"] = true
        XCTAssertNil(LocalSearchRequest(arguments: args))
        args["min_bytes"] = 201
        XCTAssertNil(LocalSearchRequest(arguments: args))
        args["min_bytes"] = 0; args["kind"] = "execute"
        XCTAssertNil(LocalSearchRequest(arguments: args))
        for index: Any in [true, -1, 101, 1.5] {
            XCTAssertNil(IntentActionMapper.map([["name": "files.result", "args": ["action": "open", "index": index]]]))
        }
    }

    func testPreviousWeekUsesCalendarBoundariesAndHalfOpenDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!; calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        let interval = LocalSearchDate.lastWeek.interval(now: now, calendar: calendar)!
        XCTAssertEqual(calendar.component(.day, from: interval.start), 19)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 26)
        let predicate = LocalSearchRequest(date: .lastWeek).predicate(now: now, calendar: calendar)
        XCTAssertTrue(predicate.evaluate(with: ["kMDItemFSContentChangeDate": interval.start, "kMDItemContentType": "public.text"]))
        XCTAssertFalse(predicate.evaluate(with: ["kMDItemFSContentChangeDate": interval.end, "kMDItemContentType": "public.text"]))
    }

    func testNameAndContentPredicatesUseDifferentFieldsAndAllTokens() {
        let item: [String: Any] = ["kMDItemFSName": "SLA-stage-2.pdf", "kMDItemTextContent": "Research about elliptic curves", "kMDItemContentType": "com.adobe.pdf"]
        XCTAssertTrue(LocalSearchRequest(query: "SLA stage 2").predicate().evaluate(with: item))
        XCTAssertTrue(LocalSearchRequest(query: "elliptic curves", mode: .content).predicate().evaluate(with: item))
        XCTAssertFalse(LocalSearchRequest(query: "elliptic curves").predicate().evaluate(with: item))
    }

    func testNativeCommandsSkipBothModelsInEitherPipelineMode() async {
        let original = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        defer { if let original { setenv("JARVIS_RUST_PIPELINE", original, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") } }
        for flag in ["0", "1"] {
            setenv("JARVIS_RUST_PIPELINE", flag, 1)
            let planner = ActionPlanner(ollamaClient: SearchNoLLM(), intentModelRouter: SearchNoIntent(), intentLog: IntentRouterLog(enabled: false))
            for text in ["open Bluetooth settings", "find PDFs from last week in downloads or documents", "preview the second one", "2"] {
                XCTAssertNotNil(CommandValidator.validate(text), text)
                let plan = await planner.plan(from: text)
                XCTAssertEqual(plan, [LocalSearchParser.route(text)!], text)
            }
        }
    }
}

private struct SearchNoLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("Native search must not wake the LLM"); return "" }
}
private struct SearchNoIntent: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("Native search must not wait for the learned model"); return nil }
}

@MainActor
private struct FixedFileSearch: FileSearching {
    let results: [FileSearchResult]
    func search(_ request: LocalSearchRequest, roots: [URL]) async throws -> FileSearchSnapshot {
        FileSearchSnapshot(results: results, limited: false, timedOut: false)
    }
}

@MainActor
private final class DeferredFileSearch: FileSearching {
    var pending: [String: CheckedContinuation<FileSearchSnapshot, Error>] = [:]
    func search(_ request: LocalSearchRequest, roots: [URL]) async throws -> FileSearchSnapshot {
        try await withCheckedThrowingContinuation { pending[request.query] = $0 }
    }
}

@MainActor
final class FileSearchSessionTests: XCTestCase {
    func testLateResultsFromCancelledSearchCannotReplaceTheVisibleList() async throws {
        let engine = DeferredFileSearch()
        let controller = FileSearchController(engine: engine, presentsUI: false)
        let old = Task { await controller.search(LocalSearchRequest(query: "old")) }
        for _ in 0..<100 where engine.pending["old"] == nil { await Task.yield() }
        let next = Task { await controller.search(LocalSearchRequest(query: "new")) }
        for _ in 0..<100 where engine.pending["new"] == nil { await Task.yield() }
        let oldContinuation = try XCTUnwrap(engine.pending["old"])
        let newContinuation = try XCTUnwrap(engine.pending["new"])
        let expected = FileSearchResult(url: URL(fileURLWithPath: "/tmp/new.txt"), name: "new.txt", size: 1, modified: .now, isDirectory: false)
        newContinuation.resume(returning: FileSearchSnapshot(results: [expected], limited: false, timedOut: false))
        _ = await next.value
        oldContinuation.resume(returning: FileSearchSnapshot(results: [], limited: false, timedOut: false))
        _ = await old.value
        XCTAssertEqual(controller.results, [expected])
        XCTAssertEqual(controller.selectedID, expected.id)
        XCTAssertFalse(controller.searching)
    }

    func testOrdinalAndPreviewUseFrozenResultsThenCloseInvalidatesTheContext() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("one.txt"), second = folder.appendingPathComponent("two.txt")
        try Data("one".utf8).write(to: first); try Data("two".utf8).write(to: second)
        let values = [first, second].map { FileSearchResult(url: $0, name: $0.lastPathComponent, size: 3, modified: .now, isDirectory: false) }
        var opened: [URL] = [], revealed: [URL] = []
        let controller = FileSearchController(engine: FixedFileSearch(results: values), presentsUI: false,
            openFile: { opened.append($0); return true }, revealFile: { revealed.append($0) })
        XCTAssertFalse(controller.act(FileResultSelection(operation: .open, index: 1)).success)
        let search = await controller.search(LocalSearchRequest(query: "test"))
        XCTAssertTrue(search.success)
        XCTAssertFalse(controller.act(FileResultSelection(operation: .open, index: 3)).success)
        XCTAssertTrue(controller.act(FileResultSelection(operation: .open, index: 2)).success)
        XCTAssertEqual(opened, [second])
        XCTAssertTrue(controller.act(FileResultSelection(operation: .preview, index: 0)).success)
        XCTAssertEqual(controller.preview?.url, second)
        XCTAssertEqual(opened, [second], "Preview must not open the document")
        XCTAssertTrue(controller.act(FileResultSelection(operation: .reveal, index: 1)).success)
        XCTAssertEqual(revealed, [first])
        controller.close()
        XCTAssertFalse(controller.act(FileResultSelection(operation: .open, index: 2)).success)
        XCTAssertTrue(controller.results.isEmpty)
    }

    func testExpiredResultsAndDeletedFilesCannotOpenSomethingElse() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("fixture".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var clock = Date()
        let item = FileSearchResult(url: url, name: url.lastPathComponent, size: 7, modified: clock, isDirectory: false)
        let controller = FileSearchController(engine: FixedFileSearch(results: [item]), presentsUI: false,
            openFile: { _ in XCTFail("Expired or missing results must not open"); return true }, now: { clock })
        await controller.search(LocalSearchRequest())
        clock = clock.addingTimeInterval(601)
        XCTAssertFalse(controller.act(FileResultSelection(operation: .open, index: 1)).success)
        await controller.search(LocalSearchRequest())
        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(controller.act(FileResultSelection(operation: .open, index: 1)).success)
    }

    func testLocationsResolveActualDirectoriesAndRejectAmbiguousAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("D-drive"), second = root.appendingPathComponent("other/D drive")
        for url in [first, second] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try FileSearchLocationStore.resolve(["d drive"], saved: [], home: root, discovered: [first]).map(\.path), [first.path])
        XCTAssertEqual(try FileSearchLocationStore.resolve(["d drive"], saved: [FileSearchLocation(name: "D drive", path: first.path)], home: root, discovered: [first]).map(\.path), [first.path])
        XCTAssertThrowsError(try FileSearchLocationStore.resolve(["d drive"], saved: [], home: root, discovered: [first, second]))
        XCTAssertThrowsError(try FileSearchLocationStore.resolve(["unknown"], saved: [], home: root, discovered: []))
        XCTAssertFalse(SpotlightSearchSession.isWithinRoots(root.appendingPathComponent("D-drive-other/test"), roots: [first]))
        XCTAssertTrue(SpotlightSearchSession.isWithinRoots(first.appendingPathComponent("subdir/test"), roots: [first]))
    }

    func testStableRankingDeduplicatesAndPrefersExactFilename() {
        let root = URL(fileURLWithPath: "/tmp")
        let exact = FileSearchResult(url: root.appendingPathComponent("SLA.pdf"), name: "SLA.pdf", size: 1, modified: .distantPast, isDirectory: false)
        let newer = FileSearchResult(url: root.appendingPathComponent("SLA-stage-2.pdf"), name: "SLA-stage-2.pdf", size: 1, modified: .now, isDirectory: false)
        XCTAssertEqual(SpotlightSearchSession.rank([newer, exact, exact], query: "SLA"), [exact, newer])
    }
}
