import XCTest
@testable import JarvisMacOS

final class FileSearchReliabilityTests: XCTestCase {
    func testFilenameLiteralsSurviveValidationAndPlanningInBothModes() async throws {
        let previous = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        defer { if let previous { setenv("JARVIS_RUST_PIPELINE", previous, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") } }
        for flag in ["0", "1"] {
            setenv("JARVIS_RUST_PIPELINE", flag, 1)
            let planner = ActionPlanner(ollamaClient: ReliabilityNoLLM(), intentModelRouter: ReliabilityNoIntent(), intentLog: IntentRouterLog(enabled: false))
            for name in ["Jarvis-release-notes.json", "Jarvis_ recording card.html", "Report Format (2).docx", "delete report.pdf", "okay now.pdf"] {
                let command = "find files named \"\(name)\" in Downloads"
                let validated = try XCTUnwrap(CommandValidator.validate(command))
                guard case .allowed = SafetyGuard.validate(rawCommand: validated) else { return XCTFail("Read-only filename search was blocked") }
                let plan = await planner.plan(from: validated)
                XCTAssertEqual(plan, [.searchFiles(LocalSearchRequest(query: name, scopes: ["Downloads"]))])
            }
        }
        for command in ["delete files in Downloads", "format Downloads", "find PDFs and delete Documents", "find PDFs then open Terminal"] {
            XCTAssertNil(LocalSearchParser.search(command))
        }
        guard case .blocked = SafetyGuard.validate(rawCommand: "find PDFs and delete Documents") else {
            return XCTFail("Destructive compound must remain blocked")
        }
        guard case .blocked = SafetyGuard.validate(rawCommand: "find files in /etc") else {
            return XCTFail("Protected explicit scopes must retain the Rust safety policy")
        }
    }

    func testCaseInsensitiveScopeConjunctionsAndContentScopes() {
        XCTAssertEqual(LocalSearchParser.search("Okay Jarvis, find PDFs in Downloads please.")?.scopes, ["Downloads"])
        XCTAssertEqual(LocalSearchParser.search("find files named \"Please\"")?.query, "Please")
        XCTAssertEqual(LocalSearchParser.search("find PDFs in Downloads AND Documents")?.scopes, ["Downloads", "Documents"])
        XCTAssertEqual(LocalSearchParser.search("find PDFs in Downloads OR Documents, Work")?.scopes, ["Downloads", "Documents", "Work"])
        XCTAssertEqual(LocalSearchParser.search("find PDFs in Downloads AND Documents mentioning geometry")?.scopes, ["Downloads", "Documents"])
    }

    func testSpokenSmallNumbersMatchFilenamesWithoutChangingContentSearch() {
        let name = LocalSearchRequest(query: "Module one", kind: .presentation)
        XCTAssertTrue(name.matchesName("Module 1.pptx"))
        XCTAssertTrue(name.matchesName("Module One.pptx"))
        XCTAssertFalse(name.matchesName("Module 2.pptx"))
        // Foundation's dictionary evaluator uses a scalar here; Spotlight
        // itself interprets equality against the metadata type tree.
        XCTAssertTrue(name.predicate().evaluate(with: ["kMDItemFSName": "Module 1.pptx", "kMDItemContentTypeTree": "public.presentation", "kMDItemContentType": "public.presentation"]))
        XCTAssertFalse(LocalSearchRequest(query: "one", mode: .content).predicate().evaluate(with: ["kMDItemTextContent": "1", "kMDItemContentType": "public.text"]))
    }

    @MainActor
    func testSingularAliasesResolveOnlyWhenUnambiguousAndExactNamesWin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plural = root.appendingPathComponent("library"), exact = root.appendingPathComponent("other")
        for url in [plural, exact] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = [FileSearchLocation(name: "Reports", path: plural.path)]
        XCTAssertEqual(try FileSearchLocationStore.resolve(["report"], saved: saved, home: root, discovered: []).first?.path, plural.path)
        XCTAssertEqual(try FileSearchLocationStore.resolve(["report"], saved: saved + [FileSearchLocation(name: "Report", path: exact.path)], home: root, discovered: []).first?.path, exact.path)
        XCTAssertThrowsError(try FileSearchLocationStore.resolve(["report"], saved: saved + [FileSearchLocation(name: "Reports", path: exact.path)], home: root, discovered: []))
    }

    func testDirectFolderChecksRespectTypeNameDateSizeAndVisibilityWithoutIndexing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Module 1.pdf")
        for name in ["Module 1.pdf", "Module 1.txt", ".hidden.pdf", "~$locked.pdf"] {
            try Data(repeating: 65, count: 128).write(to: root.appendingPathComponent(name))
        }
        let folder = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("Nested.pdf"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Alias.pdf"), withDestinationURL: pdf)
        let request = LocalSearchRequest(query: "Module one", kind: .pdf, minimumBytes: 100, maximumBytes: 200)
        XCTAssertEqual(SpotlightSearchSession.directChildren(request: request, roots: [root]).results.map(\.url.path), [pdf.path])
        XCTAssertTrue(SpotlightSearchSession.directChildren(request: LocalSearchRequest(kind: .pdf, minimumBytes: 200), roots: [root]).results.isEmpty)
        XCTAssertTrue(SpotlightSearchSession.directChildren(request: LocalSearchRequest(query: "Module", mode: .content), roots: [root]).results.isEmpty)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: pdf.path)
        XCTAssertTrue(SpotlightSearchSession.directChildren(request: LocalSearchRequest(kind: .pdf, date: .today), roots: [root]).results.isEmpty)
    }

    func testDirectFolderFilesRemainVisibleAheadOfNewerSDKDescendants() {
        let root = URL(fileURLWithPath: "/tmp/search-fixture")
        let direct = FileSearchResult(url: root.appendingPathComponent("Report.pdf"), name: "Report.pdf", size: 1, modified: .distantPast, isDirectory: false)
        let nested = (0..<500).map { index in
            FileSearchResult(url: root.appendingPathComponent("sdk/\(index).txt"), name: "\(index).txt", size: 1, modified: .now, isDirectory: false)
        }
        XCTAssertEqual(SpotlightSearchSession.rank(nested + [direct], query: "", roots: [root]).first, direct)
        let number = FileSearchResult(url: root.appendingPathComponent("Module 1.pptx"), name: "Module 1.pptx", size: 1, modified: .distantPast, isDirectory: false)
        XCTAssertEqual(SpotlightSearchSession.rank(nested + [number], query: "Module one", roots: [root]).first, number)
    }
}

private struct ReliabilityNoLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("Native file search must not reach the LLM"); return "" }
}
private struct ReliabilityNoIntent: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("Native file search must not reach the model"); return nil }
}
