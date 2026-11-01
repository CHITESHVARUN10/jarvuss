import XCTest
@testable import JarvisMacOS

final class WorkspaceCommandTests: XCTestCase {
    func testTrainingAndHeldoutResolveExactFields() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["dataset/train-072-workspace.jsonl", "training/eval_workspace.jsonl"] {
            for line in try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n") {
                let data = Data(line.utf8)
                let row = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let text = row["text"] as! String
                if row["workspace_negative"] as? Bool == true { XCTAssertNil(WorkspaceCommandParser.plan(text), text); continue }
                let expectedData = try JSONSerialization.data(withJSONObject: row["resolved_args"]!)
                let commands = try JSONDecoder().decode([WorkspaceCommand].self, from: expectedData)
                let actions = commands.map(PlannedAction.workspace)
                XCTAssertEqual(WorkspaceCommandParser.plan(text), actions, text)
                XCTAssertEqual(IntentActionMapper.map(row["intents"] as! [[String: Any]], sourceText: text), actions, text)
            }
        }
    }
    func testAppBeforeWindowAndQuotedProjectNames() {
        XCTAssertEqual(WorkspaceCommandParser.parse("open a new Chrome window"), WorkspaceCommand(operation: .newWindow, app: .chrome))
        XCTAssertEqual(WorkspaceCommandParser.parse("open \"Research and Design\" project in Finder")?.project, "Research and Design")
    }
    func testNewFamiliesRejectModelInventedArgumentsAndWrongFamily() {
        let text = "open portfolio project in VS Code"
        XCTAssertNil(IntentActionMapper.map([["name": "project.open", "args": ["path": "/private/other"]]], sourceText: text))
        XCTAssertNil(IntentActionMapper.map([["name": "app.new_tab", "args": [:]]], sourceText: text))
        XCTAssertNil(IntentActionMapper.map([["name": "project.open", "args": [:]]]))
    }
    func testMixedCompoundRetainsAppLaunch() {
        let text = "open chrome and open a new tab in Chrome"
        let expected: [PlannedAction] = [.openApp("Google Chrome"), .workspace(.init(operation: .newTab, app: .chrome))]
        XCTAssertEqual(WorkspaceCommandParser.plan(text), expected)
        XCTAssertEqual(IntentActionMapper.map([["name": "app.open", "args": ["name": "Google Chrome"]], ["name": "app.new_tab", "args": [:]]], sourceText: text), expected)
    }
    func testNativeRoutingPrecedesGenericAppAndModelInBothModes() async {
        let previous = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        defer { if let previous { setenv("JARVIS_RUST_PIPELINE", previous, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") } }
        for mode in ["0", "1"] {
            setenv("JARVIS_RUST_PIPELINE", mode, 1)
            let planner = ActionPlanner(ollamaClient: WorkspaceNoLLM(), intentModelRouter: WorkspaceNoModel(), intentLog: IntentRouterLog(enabled: false))
            for text in ["open my portfolio project in VS Code", "open a new tab in Brave", "open a new window in Chrome and open a new tab in VS Code"] {
                let actions = await planner.plan(from: text)
                XCTAssertEqual(actions, WorkspaceCommandParser.plan(text), text)
            }
        }
    }
    func testNativeAdapterKeepsPathsInArguments() async throws {
        let folder = URL(fileURLWithPath: "/tmp/fixture projects/A 'quote' $(text)")
        var received: [String] = []
        let controller = NativeWorkspaceController(locate: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") }, run: { _, args in
            received = args
            if args.count == 5 { try (args[3] + "\n").write(toFile: args[4], atomically: true, encoding: .utf8) }
            return ProcessOutput(status: 0, stdout: "confirmed", stderr: "")
        })
        _ = try await controller.perform(.init(operation: .openProject, app: .vscode), folder: folder)
        XCTAssertEqual(received, ["--new-window", folder.path])
        _ = try await controller.perform(.init(operation: .openProject, app: .terminal), folder: folder)
        XCTAssertEqual(received[3], folder.path)
        XCTAssertFalse(received[1].contains(folder.path))
        XCTAssertTrue(received[1].contains("quoted form"))
    }
    func testNativeAdapterRequiresConfirmationAndReportsPermissions() async {
        let controller = NativeWorkspaceController(locate: { _ in URL(fileURLWithPath: "/Applications/Fixture.app") }, run: { _, _ in
            ProcessOutput(status: 1, stdout: "", stderr: "Not authorized (-1743)")
        })
        do { _ = try await controller.perform(.init(operation: .newTab, app: .chrome)); XCTFail("Must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Automation")) }
    }
}
private struct WorkspaceNoLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("Native workspace command called LLM"); return "" }
}
private struct WorkspaceNoModel: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("Native workspace command called model"); return nil }
}
