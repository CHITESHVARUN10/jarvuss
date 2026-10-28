import XCTest
@testable import JarvisMacOS

final class SpotifyShuffleTests: XCTestCase {
    func testAuthoredShuffleCorpusResolvesExactModeAndPlaylistNames() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["dataset/train-070-spotify-shuffle.jsonl", "training/eval_spotify_shuffle.jsonl"] {
            for line in try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8).split(separator: "\n") {
                let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                let fields = row["resolved_args"] as! [String: Any]
                let enabled = fields["enabled"] as! Bool
                let expected: MediaAction
                switch fields["target"] as! String {
                case "liked": expected = .playLikedWithShuffle(enabled)
                case "playlist": expected = .playPlaylistWithShuffle(name: fields["name"] as! String, enabled: enabled)
                default: expected = .setShuffle(enabled)
                }
                let text = row["text"] as! String
                XCTAssertEqual(SpotifyShuffleParser.parse(text), expected, text)
                XCTAssertNotNil(CommandValidator.validate(text), text)
                XCTAssertEqual(IntentActionMapper.map(row["intents"] as! [[String: Any]], sourceText: text), [.mediaControl(expected)], text)
            }
        }
    }

    func testShuffleCannotConsumeUnrelatedActionsOrOrdinaryTitles() {
        for text in ["don't shuffle my playlist Gym", "play my liked songs on shuffle and open Safari",
                     "shuffle my gym playlist and play Bohemian Rhapsody", "shuffle my gym playlist and shuffle my Focus playlist",
                     "play Shuffle song", "play my Shuffle Hits playlist", "explain shuffle algorithms"] {
            XCTAssertNil(SpotifyShuffleParser.parse(text), text)
        }
        XCTAssertNil(IntentActionMapper.map([["name": "media.shuffle", "args": [:]]], sourceText: "open Spotify"))
        XCTAssertNil(IntentActionMapper.map([["name": "media.shuffle", "args": ["enabled": true]]], sourceText: "shuffle off"))
    }

    func testShuffleRoutesLocallyInBothPipelineModesWithoutLosingTheModifier() async {
        let original = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        defer { if let original { setenv("JARVIS_RUST_PIPELINE", original, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") } }
        for flag in ["0", "1"] {
            setenv("JARVIS_RUST_PIPELINE", flag, 1)
            let planner = ActionPlanner(ollamaClient: NoShuffleLLM(), intentModelRouter: NoShuffleModel(), intentLog: IntentRouterLog(enabled: false))
            for text in ["play a song from my light songs shuffle it", "shuffle my gym playlist", "turn shuffle off"] {
                let plan = await planner.plan(from: text)
                XCTAssertEqual(plan, [.mediaControl(SpotifyShuffleParser.parse(text)!)])
            }
        }
    }
}

private struct NoShuffleLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("Shuffle must route locally"); return "" }
}
private struct NoShuffleModel: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("Shuffle must not wait for learned routing"); return nil }
}
