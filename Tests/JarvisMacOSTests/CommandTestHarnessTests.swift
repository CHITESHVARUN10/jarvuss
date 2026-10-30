import XCTest
import AVFoundation
@testable import JarvisMacOS

@MainActor
final class CommandTestHarnessTests: XCTestCase {
    private var directory: URL!
    private var app: AppState!
    private var harness: CommandTestHarness!
    private var executor: HarnessExecutor!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-harness-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executor = HarnessExecutor()
        app = AppState(micManager: HarnessMic(), logger: Logger(logURL: directory.appendingPathComponent("commands.log")),
            dbManager: DBManager(configuration: [:]), actionPlanner: HarnessPlanner(), actionExecutor: executor,
            statsRecorder: StatsRecorder(buffer: StatsBufferStore(fileURL: directory.appendingPathComponent("stats.json")), retryInterval: 0),
            intentLog: IntentRouterLog(logURL: directory.appendingPathComponent("intent.jsonl")), activateServices: false)
        harness = CommandTestHarness(directory: directory.appendingPathComponent("testing"))
    }
    override func tearDownWithError() throws {
        harness.stop(); app.commandQueue.cancelAll(); harness = nil; app = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func start() async throws {
        await harness.start(app: app, openBrowser: false)
        XCTAssertTrue(harness.isRunning, harness.message)
        let attributes = try FileManager.default.attributesOfItem(atPath: harness.sessionURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    private func request(_ path: String, body: [String: Any]? = nil, token: String? = nil, origin: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: harness.origin + path)!)
        request.setValue(token ?? harness.token, forHTTPHeaderField: "X-Jarvis-Test-Token")
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data,response) = try await URLSession.shared.data(for: request)
        return (data,(response as! HTTPURLResponse).statusCode)
    }
    func testLoopbackAPIRequiresSessionTokenAndRejectsForeignOrigin() async throws {
        try await start()
        let (_, denied) = try await request("/api/state", token: "wrong")
        XCTAssertEqual(denied, 403)
        let (_, foreign) = try await request("/api/state", origin: "https://example.com")
        XCTAssertEqual(foreign, 403)
        let (_, valid) = try await request("/api/state")
        XCTAssertEqual(valid, 200)
        let (html,status) = try await request("/")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("Command tests"))
        XCTAssertFalse(String(decoding: html, as: UTF8.self).contains(harness.token))
    }
    func testExecuteTracesRealQueueAndSeparatesHumanReviewFromAppResult() async throws {
        try await start()
        let (accepted,status) = try await request("/api/run", body: ["command": "open Notes", "mode": "execute"])
        XCTAssertEqual(status, 202)
        let id = try XCTUnwrap((JSONSerialization.jsonObject(with: accepted) as? [String:String])?["id"])
        await harness.waitForIdle()
        let run = try XCTUnwrap(harness.runs.first)
        XCTAssertEqual(run.outcome, "success"); XCTAssertEqual(run.steps.count, 1)
        XCTAssertNotNil(run.requestID); XCTAssertEqual(executor.calls, 1)
        let (_,saved) = try await request("/api/review", body: ["id": id, "verdict": "fail", "notes": "API reported success but behavior was wrong"])
        XCTAssertEqual(saved,200); XCTAssertEqual(harness.runs[0].review,"fail")
        XCTAssertEqual(harness.runs[0].outcome,"success")
        let log = try String(contentsOf: directory.appendingPathComponent("testing/runs.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains("API reported success"))
        let intents = try String(contentsOf: directory.appendingPathComponent("intent.jsonl"), encoding: .utf8)
        XCTAssertTrue(intents.contains("test_execute_command"))
        XCTAssertFalse(intents.contains("\"event\":\"execute_command\""))
    }
    func testPlanDictationAndSafetyFailuresNeverExecuteActions() async throws {
        try await start()
        _ = try harness.submit(command: "open Notes", mode: "plan"); await harness.waitForIdle()
        XCTAssertEqual(harness.runs.last?.outcome,"planned"); XCTAssertEqual(executor.calls,0)
        _ = try harness.submit(command: "hello world", mode: "dictation"); await harness.waitForIdle()
        XCTAssertEqual(harness.runs.last?.outcome,"formatted"); XCTAssertEqual(executor.calls,0)
        _ = try harness.submit(command: "delete all files", mode: "execute"); await harness.waitForIdle()
        XCTAssertEqual(harness.runs.last?.outcome,"failure"); XCTAssertEqual(executor.calls,0)
    }
    func testStopDisablesTransportAndRemovesDiscovery() async throws {
        try await start(); let session=harness.sessionURL
        harness.stop()
        XCTAssertFalse(harness.isRunning); XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertThrowsError(try harness.submit(command:"open Notes",mode:"execute"))
    }
    func testHTTPFramingRejectsDuplicateHeadersChunkingAndLargePayloads() throws {
        XCTAssertNil(try CommandTestRequest.parse(Data("POST /api/run HTTP/1.1\r\nContent-Length: 4\r\n\r\n{}".utf8)))
        for text in ["GET /api/state HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n", "POST /api/run HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", "POST /api/run HTTP/1.1\r\nContent-Length: 100000\r\n\r\n"] {
            XCTAssertThrowsError(try CommandTestRequest.parse(Data(text.utf8)))
        }
    }
    func testCancellationTargetsOnlyItsOwnDelivery() async {
        let queue=CommandQueueManager(), id=UUID()
        let began=expectation(description:"active")
        queue.enqueue(text:"user command",deliveryID:id) { began.fulfill(); try? await Task.sleep(for:.seconds(2)) }
        await fulfillment(of:[began],timeout:1)
        queue.cancelDelivery(UUID())
        XCTAssertTrue(queue.isExecuting)
        queue.cancelDelivery(id)
        XCTAssertFalse(queue.isExecuting)
    }
    func testCancellingAnActiveHarnessRunRecordsCancellation() async throws {
        try await start()
        executor.delay = .seconds(30)
        _ = try harness.submit(command: "open Notes", mode: "execute")
        for _ in 0..<100 {
            if executor.calls > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(executor.calls, 1)
        harness.cancelActive()
        await harness.waitForIdle()
        XCTAssertEqual(harness.runs.last?.state, "finished")
        XCTAssertEqual(harness.runs.last?.outcome, "cancelled")
        XCTAssertFalse(app.commandQueue.isExecuting)
    }
    func testOptionalBrowserFixture() async throws {
        guard let value=ProcessInfo.processInfo.environment["JARVIS_TEST_REVIEW_SECONDS"],let seconds=Double(value),seconds>0 else { throw XCTSkip("Optional manual browser review") }
        try await start()
        let discovery=URL(fileURLWithPath:"/private/tmp/jarvis-command-test-review-session.json")
        try FileManager.default.copyItem(at:harness.sessionURL,to:discovery)
        defer { try? FileManager.default.removeItem(at:discovery) }
        print("TEST FIXTURE READY: local simulated executor; session file in /private/tmp")
        try await Task.sleep(for:.seconds(seconds))
    }
}

private struct HarnessMic: AudioCapturing {
    @MainActor func startListeningWithPermission(onLevelUpdate:@escaping(Float)->Void,onAudioBuffer:((AVAudioPCMBuffer)->Void)?) async throws { XCTFail("Test harness must not record audio") }
    @MainActor func stopListening() {}
    func exportRecentAudioSample(durationSeconds:Double,targetSampleRate:Double?) throws -> URL { throw MicManagerError.insufficientAudio }
}
private struct HarnessPlanner: ActionPlanning {
    func plan(from raw:String,requestID:UUID) async -> [PlannedAction] { [.openApp("Notes")] }
}
private final class HarnessExecutor: PlanExecuting {
    var onLog:((String)->Void)?
    var calls=0
    var delay: Duration?
    func execute(plan:[PlannedAction],onStepStart:@escaping @MainActor(PlannedAction)->Void,onStepComplete:@escaping @MainActor(ActionResult)->Void) async -> [ActionResult] {
        calls+=1;var results:[ActionResult]=[]
        if let delay {
            do { try await Task.sleep(for: delay) }
            catch { return [] }
        }
        for action in plan {
            await onStepStart(action)
            let result=ActionResult(action:action,success:true,message:"Simulated fixture action completed")
            await onStepComplete(result);results.append(result)
        }
        return results
    }
}
