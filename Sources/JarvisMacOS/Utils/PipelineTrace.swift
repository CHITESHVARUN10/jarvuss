import Foundation

/// One correlation ID survives speech, verification, planning and execution.
/// Default events contain timings and counts, never transcript content.
struct PipelineTrace: Sendable {
    @TaskLocal static var current: PipelineTrace?
    let id: UUID
    let source: String
    private let started: UInt64
    init(id: UUID = UUID(), source: String) {
        self.id = id; self.source = source; started = DispatchTime.now().uptimeNanoseconds
    }
    func event(_ stage: String, fields: [String: String] = [:], text: String? = nil) {
        var event = fields
        event["request_id"] = id.uuidString; event["stage"] = stage; event["source"] = source
        event["elapsed_ms"] = String((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        if UserDefaults.standard.bool(forKey: "jarvis.diagnostics.includeText"), let text { event["text"] = text }
        PipelineEventStore.shared.append(event)
    }
}

/// Bounded asynchronous diagnostics. Rotation is serialized with writes. Failures
/// never block command admission and diagnostics are never harvested for training.
final class PipelineEventStore: @unchecked Sendable {
    static let shared = PipelineEventStore()
    private let queue = DispatchQueue(label: "jarvis.pipeline-events", qos: .utility)
    private let admission = DispatchSemaphore(value: 256)
    private let directory: URL
    private let limit: Int
    init(directory: URL = RuntimeConfiguration.dataDirectory.appendingPathComponent("logs"), limit: Int = 2_000_000) {
        self.directory = directory; self.limit = limit
    }
    func append(_ fields: [String: String]) {
        guard admission.wait(timeout: .now()) == .success else { return }
        queue.async { [self] in
            defer { admission.signal() }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let url = directory.appendingPathComponent("pipeline.jsonl")
                let previous = directory.appendingPathComponent("pipeline.previous.jsonl")
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size >= limit {
                    if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                    try FileManager.default.moveItem(at: url, to: previous)
                }
                var payload = fields; payload["ts"] = ISO8601DateFormatter().string(from: Date())
                var data = try JSONEncoder().encode(payload); data.append(0x0a)
                if !FileManager.default.fileExists(atPath: url.path) {
                    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data)
            } catch { NSLog("[Pipeline] Could not persist diagnostic event: %@", error.localizedDescription) }
        }
    }
    func flush() { queue.sync {} }
}
