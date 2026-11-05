import XCTest
@testable import JarvisMacOS

final class RegressionShardTests: XCTestCase {
    func testRetentionRowsMatchNativeParsers() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("dataset/train-073-regression-retention.jsonl"), encoding: .utf8)
        for line in text.split(separator: "\n") {
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let command = row["text"] as! String
            let intents = row["intents"] as! [[String: Any]]
            switch row["regression_family"] as! String {
            case "workspace_retention":
                let fields = try JSONSerialization.data(withJSONObject: row["resolved_args"]!)
                let expected = try JSONDecoder().decode([WorkspaceCommand].self, from: fields).map(PlannedAction.workspace)
                XCTAssertEqual(WorkspaceCommandParser.plan(command), expected, command)
                XCTAssertEqual(IntentActionMapper.map(intents, sourceText: command), expected, command)
            case "shuffle_retention":
                let fields = row["resolved_args"] as! [String: Any]
                let enabled = fields["enabled"] as! Bool
                let expected: MediaAction
                switch fields["target"] as! String {
                case "liked": expected = .playLikedWithShuffle(enabled)
                case "playlist": expected = .playPlaylistWithShuffle(name: fields["name"] as! String, enabled: enabled)
                default: expected = .setShuffle(enabled)
                }
                XCTAssertEqual(SpotifyShuffleParser.parse(command), expected, command)
            case "native_retention":
                let expected = IntentActionMapper.map([["name": "files.search", "args": row["resolved_args"]!]])
                XCTAssertEqual(LocalSearchParser.route(command).map { [$0] }, expected, command)
            case "volume":
                XCTAssertEqual(SystemVolumeParser.route(command).map { [$0] }, IntentActionMapper.map(intents), command)
            default: break
            }
        }
    }
}
