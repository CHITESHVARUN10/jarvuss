import XCTest
@testable import JarvisMacOS

final class GeneralizationDataTests: XCTestCase {
    func testAuthoredNativeLabelsHaveExecutableParses() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["dataset/train-074-generalization.jsonl", "dataset/train-075-slot-transfer.jsonl", "dataset/train-076-boundary-copy.jsonl", "dataset/train-077-status-file-retention.jsonl", "dataset/train-078-context-literals.jsonl", "dataset/train-079-paraphrase-composition.jsonl", "training/benchmarks/generalization-v2/development.jsonl", "training/benchmarks/generalization-v2/audit.jsonl", "training/benchmarks/generalization-v3/development.jsonl", "training/benchmarks/generalization-v3/audit.jsonl", "training/benchmarks/rotating-20261106/audit.jsonl", "training/benchmarks/rotating-v3-20261106/audit.jsonl", "training/benchmarks/stress-20261106/audit.jsonl"]
        for path in paths {
            let content = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            for line in content.split(separator: "\n") {
                let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let text = row["text"] as! String
                let intents = row["intents"] as! [[String: Any]]
                let family = row["family"] as! String
                switch family {
                case "workspace":
                    if let fields = row["resolved_args"] {
                        let data = try JSONSerialization.data(withJSONObject: fields)
                        let expected = try JSONDecoder().decode([WorkspaceCommand].self, from: data).map(PlannedAction.workspace)
                        XCTAssertEqual(WorkspaceCommandParser.plan(text), expected, text)
                        XCTAssertEqual(IntentActionMapper.map(intents, sourceText: text), expected, text)
                    } else { XCTAssertNotNil(IntentActionMapper.map(intents, sourceText: text), text) }
                case "native_search" where row["resolved_args"] != nil:
                    let expected = IntentActionMapper.map([["name": "files.search", "args": row["resolved_args"]!]])
                    XCTAssertEqual(LocalSearchParser.route(text).map { [$0] }, expected, text)
                case "shuffle", "native_search", "settings", "results", "positive_control":
                    XCTAssertNotNil(IntentActionMapper.map(intents, sourceText: text), text)
                case "volume":
                    XCTAssertEqual(SystemVolumeParser.route(text).map { [$0] }, IntentActionMapper.map(intents), text)
                case "compound" where intents.contains(where: { ["project.open", "app.new_window", "app.new_tab"].contains($0["name"] as! String) }):
                    XCTAssertNotNil(IntentActionMapper.map(intents, sourceText: text), text)
                default: XCTAssertNotNil(IntentActionMapper.map(intents), text)
                }
            }
        }
    }
}
