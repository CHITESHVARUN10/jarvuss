import XCTest
@testable import JarvisMacOS

/// Regression tests for the "stuck on Working" wedge: one handler that never
/// returns (the close-Terminal case — a child process blocked on a system
/// dialog) must not block the queue or the UI forever.
@MainActor
final class CommandQueueManagerTests: XCTestCase {

    func testRepeatedUserCommandsArePreservedButDuplicateDeliveryIsNot() async {
        let queue = CommandQueueManager()
        let firstStarted = expectation(description: "first command started")
        let bothRan = expectation(description: "both commands ran")
        bothRan.expectedFulfillmentCount = 2
        let id = UUID()
        XCTAssertTrue(queue.enqueue(text: "next song", priority: .high, deliveryID: id) {
            firstStarted.fulfill()
            try? await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(Task.isCancelled, "A repeated next must queue, not cancel the first next")
            bothRan.fulfill()
        })
        await fulfillment(of: [firstStarted], timeout: 1)
        XCTAssertFalse(queue.enqueue(text: "next song", priority: .high, deliveryID: id) { XCTFail("Duplicate delivery") })
        XCTAssertTrue(queue.enqueue(text: "next song", priority: .high) { bothRan.fulfill() })
        await fulfillment(of: [bothRan], timeout: 1)
    }

    func testWedgedHandlerIsReleasedByWatchdogAndNextCommandRuns() async throws {
        let previous = CommandQueueManager.executionWatchdogSeconds
        CommandQueueManager.executionWatchdogSeconds = 0.5
        defer { CommandQueueManager.executionWatchdogSeconds = previous }

        let queue = CommandQueueManager()
        var secondRan = false

        queue.enqueue(text: "close terminal") {
            // Simulates the hang: a handler that does not return in time.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(queue.isExecuting, "first command should be running")

        queue.enqueue(text: "open chrome") {
            secondRan = true
        }
        XCTAssertFalse(secondRan, "second command must wait behind the first")

        // Watchdog fires ~0.5 s after the first started.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(secondRan, "queue must release the wedged slot and drain")
        XCTAssertFalse(queue.isExecuting, "no command should still be marked executing")
        XCTAssertEqual(queue.currentCommandText, "", "stuck command text must be cleared")
    }

    func testNormalCompletionIsNotDisturbedByWatchdog() async throws {
        let previous = CommandQueueManager.executionWatchdogSeconds
        CommandQueueManager.executionWatchdogSeconds = 5
        defer { CommandQueueManager.executionWatchdogSeconds = previous }

        let queue = CommandQueueManager()
        var ran = false
        queue.enqueue(text: "what time is it") { ran = true }

        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(ran)
        XCTAssertFalse(queue.isExecuting)
        XCTAssertEqual(queue.currentCommandText, "")
    }
}
