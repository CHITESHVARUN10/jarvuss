import XCTest
@testable import JarvisMacOS

final class SpotifyPlaybackRecoveryTests: XCTestCase {
    func testGenericSpotifyPlayRequestsDoNotBecomeTrackTitlesInEitherMode() async {
        let previous = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"]
        defer { if let previous { setenv("JARVIS_RUST_PIPELINE", previous, 1) } else { unsetenv("JARVIS_RUST_PIPELINE") } }
        for mode in ["0", "1"] {
            setenv("JARVIS_RUST_PIPELINE", mode, 1)
            let planner = ActionPlanner(ollamaClient: NoPlaybackLLM(), intentModelRouter: NoPlaybackModel(), intentLog: IntentRouterLog(enabled: false))
            for command in ["play song", "play song in spotify", "play music on Spotify", "play a song for me"] {
                let plan = await planner.plan(from: command)
                XCTAssertEqual(plan, [.mediaControl(.play)], command)
            }
        }
    }

    func testSpotifyFailuresHaveReadableRecoveryInstructions() {
        let noDevice = ActionExecutor.spotifyFailureMessage(status: 400, message: #"{"detail":"No active Spotify device"}"#)
        XCTAssertTrue(noDevice.contains("device menu"))
        XCTAssertFalse(noDevice.contains("{\""))
        XCTAssertTrue(ActionExecutor.spotifyFailureMessage(status: 401, message: "unauthorized").contains("connect again"))
        XCTAssertTrue(ActionExecutor.spotifyFailureMessage(status: 403, message: "Premium required").contains("Premium"))
    }

    @MainActor
    func testRepeatedFailuresPublishDistinctMessagesAndRetainFailureState() {
        let action = PlannedAction.mediaControl(.play)
        let result = ActionResult(action: action, success: false, message: "Spotify isn’t ready.")
        let engine = ResponseEngine.shared
        engine.respond(action: action, result: result, speak: false)
        let firstID = engine.latestMessage?.id
        engine.respond(action: action, result: result, speak: false)
        XCTAssertNotEqual(firstID, engine.latestMessage?.id)
        XCTAssertEqual(engine.latestMessage?.succeeded, false)
        let feed = AssistantFeed()
        feed.addAssistant(engine.latestMessage!.text, succeeded: engine.latestMessage?.succeeded)
        XCTAssertEqual(feed.items.first?.succeeded, false)
    }
}

private struct NoPlaybackLLM: LLMGenerating {
    func generate(prompt: String) async -> String { XCTFail("Generic playback must not call the LLM"); return "" }
}
private struct NoPlaybackModel: IntentRouting {
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? { XCTFail("Generic playback must not call the model"); return nil }
}
