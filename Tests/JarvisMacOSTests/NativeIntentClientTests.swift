import XCTest
@testable import JarvisMacOS

final class NativeIntentClientTests: XCTestCase {
    func testNativeResponseUsesExistingMappingWithoutBackendProbe() async throws {
        var probes = 0
        let client = IntentModelClient(backendIsRunning: { probes += 1; return false }, nativeParse: { text in
            XCTAssertEqual(text, "open Notes")
            return #"{"actions":[{"name":"app.open","args":{"name":"Notes"}}],"confidence":0.98,"parse_ok":true,"raw":"native output","latency_ms":12}"#
        })
        let previous = BackendServiceManager.mode
        BackendServiceManager.mode = .automatic
        defer { BackendServiceManager.mode = previous }
        let result = try await client.parse(text: "open Notes")
        XCTAssertEqual(probes, 0)
        XCTAssertEqual(result.actions.first?["name"] as? String, "app.open")
        XCTAssertEqual(result.confidence, 0.98)
        XCTAssertTrue(result.parseOK)
        XCTAssertEqual(result.latencyMs, 12)
    }

    @MainActor func testNativeOffAndCancellationDoNotInvokeInference() async {
        let previous = BackendServiceManager.mode
        defer { BackendServiceManager.mode = previous }
        var calls = 0
        let client = IntentModelClient(nativeParse: { _ in calls += 1; return "{}" })
        BackendServiceManager.mode = .off
        do { _ = try await client.parse(text: "pause"); XCTFail("Off must reject inference") }
        catch IntentModelClient.ClientError.unavailable {} catch { XCTFail("\(error)") }
        XCTAssertEqual(calls, 0)
        BackendServiceManager.mode = .automatic
        let task = Task { try Task.checkCancellation(); return try await client.parse(text: "pause") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled request must fail") }
        catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertEqual(calls, 0)
    }

    func testNativeFailureAndUnparseableResponseRemainMisses() async throws {
        let previous = BackendServiceManager.mode
        BackendServiceManager.mode = .automatic
        defer { BackendServiceManager.mode = previous }
        let client = IntentModelClient(nativeParse: { _ in
            #"{"actions":null,"parse_ok":false,"confidence":0,"raw":"","latency_ms":0,"reason":"input_too_long"}"#
        })
        let result = try await client.parse(text: "a long input")
        XCTAssertFalse(result.parseOK)
        XCTAssertTrue(result.actions.isEmpty)
        let failed = IntentModelClient(nativeParse: { _ in throw IntentModelClient.ClientError.unavailable })
        do { _ = try await failed.parse(text: "pause"); XCTFail("Native failures must propagate to the existing rule fallback") }
        catch IntentModelClient.ClientError.unavailable {}
    }
}
