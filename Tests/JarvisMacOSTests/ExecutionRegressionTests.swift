import XCTest
@testable import JarvisMacOS

private actor ActionCalls {
    var actions: [PlannedAction] = []
    func record(_ action: PlannedAction) { actions.append(action) }
}

@MainActor
final class ExecutionRegressionTests: XCTestCase {
    override func setUp() { TestSupport.pinRustPipelineOff() }
    override func tearDown() { TestSupport.unpinRustPipeline() }

    func testCancellationStopsRemainingActions() async {
        let calls = ActionCalls()
        let executor = ActionExecutor(actionRunner: { action in
            await calls.record(action)
            return ActionResult(action: action, success: true, message: "done")
        })
        let task = Task {
            await executor.execute(plan: [.openApp("first"), .openApp("second")],
                onStepStart: { _ in }, onStepComplete: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        let results = await task.value
        let actions = await calls.actions
        XCTAssertEqual(actions, [.openApp("first")])
        XCTAssertEqual(results.count, 1)
    }

    func testCompletionCallbacksFinishBeforeExecuteReturns() async {
        let executor = ActionExecutor(actionRunner: {
            ActionResult(action: $0, success: true, message: $0.description)
        })
        let plan: [PlannedAction] = [.openApp("first"), .openApp("second")]
        var completed: [PlannedAction] = []
        let results = await executor.execute(plan: plan, onStepStart: { _ in },
                                             onStepComplete: { completed.append($0.action) })
        XCTAssertEqual(completed, plan)
        XCTAssertEqual(results.map(\.action), plan)
    }

    func testOutcomeUsesAllStepsAndRequiresCompletePlan() {
        let yes = ActionResult(action: .openApp("one"), success: true, message: "")
        let no = ActionResult(action: .openApp("two"), success: false, message: "")
        XCTAssertEqual(CommandOutcome.evaluate([yes, yes], expectedCount: 2, cancelled: false), .success)
        XCTAssertEqual(CommandOutcome.evaluate([yes, no], expectedCount: 2, cancelled: false), .partialFailure)
        XCTAssertEqual(CommandOutcome.evaluate([no, no], expectedCount: 2, cancelled: false), .failure)
        XCTAssertEqual(CommandOutcome.evaluate([yes], expectedCount: 2, cancelled: false), .failure)
        XCTAssertEqual(CommandOutcome.evaluate([], expectedCount: 0, cancelled: false), .failure)
        XCTAssertEqual(CommandOutcome.evaluate([yes], expectedCount: 1, cancelled: true), .cancelled)
    }

    func testWatchdogCancelsHandlerBeforeStartingReplacement() async throws {
        let previous = CommandQueueManager.executionWatchdogSeconds
        CommandQueueManager.executionWatchdogSeconds = 0.05
        defer { CommandQueueManager.executionWatchdogSeconds = previous }
        let queue = CommandQueueManager()
        let started = expectation(description: "first started")
        let cancelled = expectation(description: "first cancelled")
        let replacement = expectation(description: "replacement ran")
        var cancellationObserved = false
        queue.enqueue(text: "first") {
            started.fulfill()
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancellationObserved = true; cancelled.fulfill() }
        }
        await fulfillment(of: [started], timeout: 1)
        queue.enqueue(text: "second") { replacement.fulfill() }
        await fulfillment(of: [cancelled, replacement], timeout: 2)
        XCTAssertTrue(cancellationObserved)
    }
}

private actor SuspendedText {
    private var continuation: CheckedContinuation<String, Never>?
    func get(started: XCTestExpectation) async -> String {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func resolve(_ text: String) { continuation?.resume(returning: text); continuation = nil }
}

@MainActor
final class LatestResultTaskTests: XCTestCase {
    func testOldNonCooperatingWorkCannotReplaceNewSession() async {
        let latest = LatestResultTask<String>()
        let old = SuspendedText()
        let oldStarted = expectation(description: "old work started")
        let newFinished = expectation(description: "new result delivered")
        var delivered: [String] = []
        latest.start(operation: { await old.get(started: oldStarted) },
                     completion: { delivered.append($0) })
        await fulfillment(of: [oldStarted], timeout: 1)
        latest.start(operation: { "new" }, completion: {
            delivered.append($0)
            newFinished.fulfill()
        })
        await fulfillment(of: [newFinished], timeout: 1)
        await old.resolve("stale")
        // Drain the old completion task after resuming its non-cancellable work.
        await Task.yield()
        XCTAssertEqual(delivered, ["new"])
    }

    func testDismissalInvalidatesLateResult() async {
        let latest = LatestResultTask<String>()
        let work = SuspendedText()
        let started = expectation(description: "started")
        let unwanted = expectation(description: "dismissed result must not deliver")
        unwanted.isInverted = true
        latest.start(operation: { await work.get(started: started) }, completion: { _ in unwanted.fulfill() })
        await fulfillment(of: [started], timeout: 1)
        latest.invalidate()
        await work.resolve("stale")
        await fulfillment(of: [unwanted], timeout: 0.05)
    }
}
