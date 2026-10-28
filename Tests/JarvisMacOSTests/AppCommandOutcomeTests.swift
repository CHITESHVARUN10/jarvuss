import AVFoundation
import XCTest
@testable import JarvisMacOS

private struct SilentMicrophone: AudioCapturing {
    func startListeningWithPermission(onLevelUpdate: @escaping (Float) -> Void,
                                     onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?) async throws {
        XCTFail("Unit tests must not start the microphone")
    }
    func stopListening() {}
    func exportRecentAudioSample(durationSeconds: Double, targetSampleRate: Double?) throws -> URL {
        throw MicManagerError.insufficientAudio
    }
}

private struct FixedPlanner: ActionPlanning {
    let actions: [PlannedAction]
    func plan(from raw: String, requestID: UUID) async -> [PlannedAction] { actions }
}

private actor DeferredPlanner: ActionPlanning {
    let oldStarted: XCTestExpectation
    let newStarted: XCTestExpectation
    private var pending: [String: CheckedContinuation<[PlannedAction], Never>] = [:]
    init(oldStarted: XCTestExpectation, newStarted: XCTestExpectation) {
        self.oldStarted = oldStarted
        self.newStarted = newStarted
    }
    func plan(from raw: String, requestID: UUID) async -> [PlannedAction] {
        await withCheckedContinuation {
            pending[raw] = $0
            (raw == "old command" ? oldStarted : newStarted).fulfill()
        }
    }
    func resolve(_ command: String) {
        pending.removeValue(forKey: command)?.resume(returning: [.openApp(command)])
    }
}

private final class FailedExecutor: PlanExecuting {
    var onLog: ((String) -> Void)?
    var calls = 0
    func execute(plan: [PlannedAction],
                 onStepStart: @escaping @MainActor (PlannedAction) -> Void,
                 onStepComplete: @escaping @MainActor (ActionResult) -> Void) async -> [ActionResult] {
        calls += 1
        var results: [ActionResult] = []
        for action in plan {
            await onStepStart(action)
            let result = ActionResult(action: action, success: false, message: "deliberate failure")
            results.append(result)
            await onStepComplete(result)
        }
        return results
    }
}

@MainActor
final class AppCommandOutcomeTests: XCTestCase {
    private var directory: URL!
    private var stats: StatsRecorder!
    private var executor: FailedExecutor!
    private var app: AppState!

    override func setUpWithError() throws {
        TestSupport.pinRustPipelineOff()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stats = StatsRecorder(buffer: StatsBufferStore(fileURL: directory.appendingPathComponent("stats.json")), retryInterval: 0)
        executor = FailedExecutor()
        app = AppState(micManager: SilentMicrophone(), logger: Logger(logURL: directory.appendingPathComponent("commands.log")),
                       dbManager: DBManager(configuration: [:]), actionPlanner: FixedPlanner(actions: [.openApp("test")]),
                       actionExecutor: executor, statsRecorder: stats,
                       intentLog: IntentRouterLog(logURL: directory.appendingPathComponent("intent.jsonl")),
                       activateServices: false)
    }

    override func tearDownWithError() throws {
        app = nil
        stats = nil
        try FileManager.default.removeItem(at: directory)
        TestSupport.unpinRustPipeline()
    }

    private func commandEvents() throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("intent.jsonl"), encoding: .utf8)
            .split(separator: "\n").compactMap { line in
                let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
                return object?["event"] as? String == "execute_command" ? object : nil
            }
    }

    func testVerificationOffAllowsUnenrolledRepeatedWakeWordCommands() async {
        let previous = UserDefaults.standard.object(forKey: "jarvis.voiceModeRequiresVerify")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "jarvis.voiceModeRequiresVerify") }
            else { UserDefaults.standard.removeObject(forKey: "jarvis.voiceModeRequiresVerify") }
        }
        app.voiceModeRequiresVerify = false
        app.enrollmentCompleted = false
        app.backendEnrollmentSampleCount = 0
        XCTAssertTrue(app.canUseVoiceMode)
        app.voiceModeEnabled = true
        app.handleTranscript("Jarvis open Safari", isFinal: true)
        app.handleTranscript("Jarvis open Safari", isFinal: true)
        for _ in 0..<100 {
            if executor.calls == 2 { break }
            await Task.yield()
        }
        XCTAssertEqual(executor.calls, 2)
    }

    func testFailedStepsProduceOneFailureAndFailureTrainingOutcome() async throws {
        await app.runCommand("open test")
        XCTAssertEqual(stats.snapshot().commandsFailed, 1)
        XCTAssertEqual(stats.snapshot().commandsRun, 0)
        let event = try XCTUnwrap(commandEvents().first)
        XCTAssertEqual(event["success"] as? Bool, false)
        XCTAssertEqual(event["outcome"] as? String, "failure")
        XCTAssertEqual(app.assistantState, .idle)
        XCTAssertEqual(app.currentCommand, "")
    }

    func testNativeFileContentSearchDoesNotTriggerARoutineKeyword() async {
        app.automations = [VoiceAutomation(keyword: "elliptic", actions: [])]
        await app.runCommand("find the file that mentions elliptic curves")
        XCTAssertEqual(executor.calls, 1, "The planner/executor path must win over a keyword found inside document content")
    }

    func testBlockedCommandRecordsExactlyOneFailureWithoutExecution() async throws {
        await app.runCommand("sudo open test")
        XCTAssertEqual(executor.calls, 0)
        XCTAssertEqual(stats.snapshot().commandsFailed, 1)
        XCTAssertEqual(try commandEvents().count, 1)
    }

    func testQuickInformationIsRecordedAsSuccessfulWithoutExecutor() async throws {
        await app.runCommand("what time is it")
        XCTAssertEqual(executor.calls, 0)
        XCTAssertEqual(stats.snapshot().commandsRun, 1)
        XCTAssertEqual(stats.snapshot().commandsFailed, 0)
        XCTAssertEqual(try commandEvents().first?["outcome"] as? String, "success")
    }

    func testSupersededPlannerCannotExecuteOrResetReplacementState() async throws {
        let oldStarted = expectation(description: "old planner started")
        let newStarted = expectation(description: "replacement planner started")
        let planner = DeferredPlanner(oldStarted: oldStarted, newStarted: newStarted)
        app = AppState(micManager: SilentMicrophone(), logger: Logger(logURL: directory.appendingPathComponent("commands.log")),
                       dbManager: DBManager(configuration: [:]), actionPlanner: planner,
                       actionExecutor: executor, statsRecorder: stats,
                       intentLog: IntentRouterLog(logURL: directory.appendingPathComponent("intent.jsonl")),
                       activateServices: false)
        let old = Task { await app.runCommand("old command") }
        await fulfillment(of: [oldStarted], timeout: 1)
        app.invalidateActiveCommand()
        old.cancel()
        let replacement = Task { await app.runCommand("new command") }
        await fulfillment(of: [newStarted], timeout: 1)
        await planner.resolve("old command")
        await old.value
        XCTAssertEqual(app.currentCommand, "new command")
        XCTAssertEqual(app.assistantState, .processing)
        XCTAssertEqual(executor.calls, 0)
        await planner.resolve("new command")
        await replacement.value
        XCTAssertEqual(executor.calls, 1)
        let outcomes = try commandEvents().compactMap { $0["outcome"] as? String }
        XCTAssertEqual(outcomes, ["cancelled", "failure"])
    }
}
