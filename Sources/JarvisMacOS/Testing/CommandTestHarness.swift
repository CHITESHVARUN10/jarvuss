import AppKit
import Foundation

@MainActor
final class CommandTestHarness: ObservableObject {
    static let shared = CommandTestHarness()
    @Published private(set) var isRunning = false
    @Published private(set) var message = "Test mode is off."
    @Published private(set) var runs: [CommandTestRun] = []
    private(set) var port: UInt16 = 0
    private(set) var token = ""
    private weak var app: AppState?
    private var server: CommandTestServer?
    private var task: Task<Void, Never>?
    private var activeID: UUID?
    let directory: URL
    var sessionURL: URL { directory.appendingPathComponent("session.json") }
    private var logURL: URL { directory.appendingPathComponent("runs.jsonl") }

    init(directory: URL = RuntimeConfiguration.dataDirectory.appendingPathComponent("testing")) { self.directory = directory }

    func start(app: AppState, openBrowser: Bool = true) async {
        if isRunning { if openBrowser { openRunner() }; return }
        guard server == nil else { return }
        self.app = app
        token = UUID().uuidString + UUID().uuidString
        do {
            let server = try CommandTestServer { [weak self] request in
                guard let self else { return .json(503, ["error": "Test mode unavailable"] ) }
                return await self.handle(request)
            }
            self.server = server
            port = try await server.start()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try writePrivate(Self.encode(["port": port, "token": token, "pid": getpid(), "origin": origin]), to: sessionURL)
            isRunning = true
            message = "Local test mode is on at 127.0.0.1:\(port)."
            CrashDiagnostics.shared.record("command_test_mode_started", fields: ["port": String(port)])
            if openBrowser { openRunner() }
        } catch {
            stop()
            message = "Could not start test mode: \(error.localizedDescription)"
        }
    }

    var origin: String { "http://127.0.0.1:\(port)" }
    func openRunner() {
        guard isRunning, let url = URL(string: origin + "/#" + token) else { return }
        NSWorkspace.shared.open(url)
    }
    func cancelActive() {
        task?.cancel()
        if let activeID { app?.commandQueue.cancelDelivery(activeID) }
    }
    func stop() {
        cancelActive()
        server?.stop(); server = nil
        isRunning = false; port = 0; token = ""
        try? FileManager.default.removeItem(at: sessionURL)
        message = "Test mode is off."
    }

    func submit(command: String, mode: String) throws -> CommandTestRun {
        guard isRunning, app != nil else { throw TestError("Test mode is off") }
        guard task == nil else { throw TestError("Another test is running; wait or cancel it") }
        guard ["execute", "plan", "intent", "dictation"].contains(mode) else { throw TestError("Unknown test mode") }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              command.utf8.count <= (mode == "dictation" ? 32000 : 4096) else { throw TestError("Empty input or input exceeds the test limit") }
        let run = CommandTestRun(id: UUID(), command: command, mode: mode, startedAt: Date(), revision: DiagnosticBuild.current.revision, rustPipeline: JarvisFlags.useRustPipeline)
        try append(run, event: "started")
        if runs.count >= 100 { runs.removeFirst() }
        runs.append(run); activeID = run.id
        task = Task { [weak self] in
            guard let self else { return }
            var completed = run
            do {
                try Task.checkCancellation()
                completed = try await self.perform(run)
                try Task.checkCancellation()
            } catch {
                completed.outcome = Task.isCancelled ? "cancelled" : "failure"
                completed.output = error.localizedDescription
                completed.events.append(CommandTestEvent(stage: "error", message: error.localizedDescription))
            }
            completed.state = "finished"
            completed.elapsedMs = Int(Date().timeIntervalSince(run.startedAt) * 1000)
            if let index = self.runs.firstIndex(where: { $0.id == run.id }) {
                completed.review = self.runs[index].review; completed.notes = self.runs[index].notes
                self.runs[index] = completed
            }
            do { try self.append(completed, event: "finished") }
            catch { self.message = "Test completed, but its log could not be saved: \(error.localizedDescription)" }
            self.activeID = nil; self.task = nil
        }
        return run
    }

    func waitForIdle() async { await task?.value }

    func review(id: UUID, verdict: String, notes: String) throws {
        guard ["pass", "fail", "unreviewed"].contains(verdict), notes.utf8.count <= 16000,
              let index = runs.firstIndex(where: { $0.id == id }) else { throw TestError("Invalid review or run ID") }
        runs[index].review = verdict; runs[index].notes = notes
        try append(runs[index], event: "review")
    }

    private func perform(_ run: CommandTestRun) async throws -> CommandTestRun {
        guard let app else { throw TestError("Jarvis is unavailable") }
        var result = run
        if run.mode == "dictation" {
            let rules = TranscriptFormatter.format(run.command)
            let directive = TranscriptFormatter.listDirective(for: run.command)
            if TranscriptFormatter.shouldUseLLM(rules, directive: directive) {
                let polished = await DictationPolisher.polish(rulesOutput: rules, directive: directive)
                result.output = polished.text
                result.events.append(CommandTestEvent(stage: "polish", message: polished.outcome.rawValue))
            } else {
                result.output = rules.text
                result.events.append(CommandTestEvent(stage: "format", message: "Rules only; no model needed"))
            }
            result.outcome = "formatted"
            return result
        }
        if run.mode == "intent" {
            guard await BackendServiceManager.ensureRunningForFeature() else { throw TestError("Intent testing requires the Python helper; check the backend setting") }
            // Deliberately bypass fast paths to inspect the learned model.
            let response = try await IntentModelClient(timeout: 30).parse(text: run.command)
            result.output = response.raw
            result.outcome = response.parseOK ? "parsed" : "failure"
            result.events.append(CommandTestEvent(stage: "intent_model", message: "Confidence \(response.confidence), model latency \(response.latencyMs) ms. No actions executed."))
            result.plan = IntentActionMapper.map(response.actions, sourceText: run.command)?.map(\.description) ?? []
            return result
        }
        guard let command = CommandValidator.validate(run.command) else { throw TestError("The command validator rejected this input") }
        result.events.append(CommandTestEvent(stage: "validated", message: command))
        if run.mode == "plan" {
            switch SafetyGuard.validate(rawCommand: command) {
            case .allowed: break
            case .blocked(let reason): result.outcome = "blocked"; result.output = reason; return result
            case .installPreview(let cmd, let source): result.outcome = "blocked"; result.output = "Install preview only: \(cmd). \(source)"; return result
            }
            let plan = await app.actionPlanner.plan(from: command, requestID: run.id)
            result.plan = plan.map(\.description); result.output = result.plan.joined(separator: "\n")
            result.outcome = plan.isEmpty ? "failure" : "planned"
            result.events.append(CommandTestEvent(stage: "plan", message: "No actions executed. Saved routine/quick-info execution is evaluated only in Execute mode."))
            return result
        }
        guard !app.commandQueue.isExecuting else { throw TestError("Jarvis is busy with another command") }
        let trace = CommandTestTrace()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let accepted = app.commandQueue.enqueue(text: command, priority: .normal, deliveryID: run.id) {
                    if Task.isCancelled { trace.outcome = "cancelled" }
                    else { await app.runCommand(command, testTrace: trace) }
                    continuation.resume()
                }
                if !accepted { trace.record("queue", "Command queue rejected the test"); continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor in app.commandQueue.cancelDelivery(run.id) }
        }
        result.requestID = trace.requestID; result.plan = trace.plan; result.steps = trace.steps
        result.events += trace.events; result.outcome = Task.isCancelled ? "cancelled" : trace.outcome
        result.output = trace.steps.map(\.message).joined(separator: "\n")
        if result.output.isEmpty { result.output = trace.events.filter { $0.stage != "finished" }.map(\.message).joined(separator: "\n") }
        return result
    }

    private func append(_ run: CommandTestRun, event: String) throws {
        let object = try JSONSerialization.jsonObject(with: Self.encode(run))
        let data = try Self.encode(["event": event, "run": object]) + Data([10])
        if !FileManager.default.fileExists(atPath: logURL.path) {
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw TestError("Could not create the test log") }
        }
        let handle = try FileHandle(forWritingTo: logURL); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.synchronize()
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw TestError("Could not write the test session") }
    }
    static func encode(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    struct TestError: LocalizedError { let text: String; init(_ text: String) { self.text = text }; var errorDescription: String? { text } }
}
