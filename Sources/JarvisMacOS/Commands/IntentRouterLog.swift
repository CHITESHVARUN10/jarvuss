import Foundation

/// Append-only JSONL log for the learned intent router.
///
/// Every request that reaches the model — hit, miss, fallback branch, and
/// per-step execution outcome — is recorded here as one JSON line:
///   (utterance, model output, confidence, branch, outcome)
/// This is the corpus for future RL training on real usage.
final class IntentRouterLog {

    static let shared = IntentRouterLog()

    private let logURL: URL
    private let lock = NSLock()

    private init() {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        logURL = support.appendingPathComponent("intent_router.jsonl")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
    }

    func append(_ event: [String: Any]) {
        // Migration cut-over: Rust owns the append (same path, ts, sorted keys).
        if JarvisFlags.useRustPipeline {
            guard JSONSerialization.isValidJSONObject(event),
                  let data = try? JSONSerialization.data(withJSONObject: event),
                  let json = String(data: data, encoding: .utf8) else { return }
            _ = coreRlAppend(eventJson: json)
            return
        }

        var payload = event
        payload["ts"] = ISO8601DateFormatter().string(from: Date())
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0A)

        lock.lock()
        defer { lock.unlock() }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}
