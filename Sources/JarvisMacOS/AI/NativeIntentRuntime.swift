import Foundation

/// In-process inference. Every heavy operation runs off the UI executor; the
/// Python transport remains selectable for rollback and custom backend URLs.
enum NativeIntentRuntime {
    private static let idleTimer: DispatchSourceTimer = {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        // Check often enough that the 120 s idle threshold is not delayed by
        // a full minute. The model is ~700 MB resident, so releasing it
        // promptly matters more than the negligible timer cost.
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler {
            guard BackendServiceManager.mode != .always else { return }
            _ = coreNativeIntentUnloadIfIdle(seconds: BackendServiceManager.mode == .off ? 0 : 120)
        }
        timer.resume()
        return timer
    }()
    static var enabled: Bool {
        (ProcessInfo.processInfo.environment["JARVIS_INTENT_RUNTIME"] ?? "native").lowercased() == "native"
    }

    static func parse(_ text: String) async throws -> String {
        try Task.checkCancellation()
        _ = idleTimer
        let resources = Bundle.main.resourceURL
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let model = resources?.appendingPathComponent("backend/models/intent-t5-small")
            ?? root.appendingPathComponent("backend/models/intent-t5-small")
        let library = resources?.appendingPathComponent("native/libonnxruntime.1.31.0.dylib")
            ?? root.appendingPathComponent(".build/native/libonnxruntime.1.31.0.dylib")
        let dataDirectory = RuntimeConfiguration.dataDirectory.path
        let cancellation = CoreInferenceCancellation()
        PipelineTrace.current?.event("intent_started")
        let result: Result<String, Error> = try await InferenceBudget.shared.run {
            await withTaskCancellationHandler {
                await RustPipeline.runBlocking {
                    Result { try coreNativeIntentParseCancellable(text: text, bundledDirectory: model.path,
                        dataDirectory: dataDirectory, runtimeLibrary: library.path, cancellation: cancellation) }
                }
            } onCancel: { cancellation.cancel() }
        }
        PipelineTrace.current?.event("intent_finished")
        try Task.checkCancellation()
        return try result.get()
    }

    static func updateWarning() async -> String? {
        let raw = await RustPipeline.runBlocking { coreNativeIntentStatus() }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["update_error"] as? String
    }
}
