import XCTest
@testable import JarvisMacOS

final class ProcessOutputTests: XCTestCase {
    func testLargeStdoutAndStderrAreDrainedBeforeWaiting() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; sys.stdout.write('o' * 200000); sys.stderr.write('e' * 200000)"]
        let result = try process.runCapturingOutput(timeout: 5)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 200_000)
        XCTAssertEqual(result.stderr.count, 200_000)
    }

    func testInputTravelsThroughStdinAndLargeOutputCanBeBounded() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import sys; value=sys.stdin.read(); sys.stdout.write('x'*200000+value); sys.stderr.write('e'*200000)"]
        let result = try process.runCapturingOutput(timeout: 5, input: Data("synthetic-secret".utf8), outputLimit: 1024)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, 1024)
        XCTAssertEqual(result.stderr.count, 1024)
        XCTAssertTrue(result.stdout.hasSuffix("synthetic-secret"))
        XCTAssertFalse(process.arguments!.contains("synthetic-secret"))
    }

    @MainActor
    func testAsyncProcessDoesNotBlockUIActorAndCancels() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let task = Task { try await process.runCapturingOutputAsync(timeout: 20) }
        try await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.stderr.contains("cancelled"))
    }

    func testCancelledProcessIsTerminated() async throws {
        let started = expectation(description: "child started")
        let task = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["10"]
            started.fulfill()
            return try process.runCapturingOutput(timeout: 20)
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(result.stderr.contains("cancelled"))
    }
}
