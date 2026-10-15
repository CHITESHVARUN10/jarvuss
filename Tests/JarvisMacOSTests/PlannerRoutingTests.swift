import XCTest
@testable import JarvisMacOS

private final class CountingIntentRouter: IntentRouting {
    var calls = 0
    var answer: [PlannedAction]?
    func route(_ text: String, requestID: UUID) async -> [PlannedAction]? {
        calls += 1
        return answer
    }
}

private struct NoModel: LLMGenerating {
    func generate(prompt: String) async -> String {
        XCTFail("Unexpected model generation for a deterministic command")
        return ""
    }
}

final class PlannerRoutingTests: XCTestCase {
    override func setUp() { TestSupport.pinRustPipelineOff() }
    override func tearDown() { TestSupport.unpinRustPipeline() }

    func testSimpleCommandsSkipLearnedInference() async {
        let router = CountingIntentRouter()
        let planner = ActionPlanner(ollamaClient: NoModel(), intentModelRouter: router, intentLog: IntentRouterLog(enabled: false))
        let fixtures: [(String, [PlannedAction])] = [
            ("open spotify", [.openApp("Spotify")]),
            ("pause", [.mediaControl(.pause)]),
            ("mute", [.volumeControl(.mute)]),
            ("open youtube", [.openURL("https://www.youtube.com")]),
        ]
        for (command, expected) in fixtures {
            let plan = await planner.plan(from: command)
            XCTAssertEqual(plan, expected, command)
        }
        XCTAssertEqual(router.calls, 0)
    }

    func testCompoundCommandStillUsesLearnedRouterAndKeepsAllSteps() async {
        let router = CountingIntentRouter()
        router.answer = [.openApp("Spotify"), .openApp("Safari")]
        let planner = ActionPlanner(ollamaClient: NoModel(), intentModelRouter: router, intentLog: IntentRouterLog(enabled: false))
        let plan = await planner.plan(from: "open spotify and open safari")
        XCTAssertEqual(plan, router.answer)
        XCTAssertEqual(router.calls, 1)
    }

    func testCancelledPlanDoesNotStartInference() async {
        let router = CountingIntentRouter()
        let planner = ActionPlanner(ollamaClient: NoModel(), intentModelRouter: router, intentLog: IntentRouterLog(enabled: false))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await planner.plan(from: "open spotify and open safari")
        }
        let plan = await task.value
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(router.calls, 0)
    }
}
