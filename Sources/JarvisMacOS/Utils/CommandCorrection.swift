import Foundation

struct CommandCorrection: Codable {
    enum Cause: String, CaseIterable, Codable {
        case transcription, normalization, intent, arguments, execution, unknown
    }
    var id = UUID()
    var createdAt = Date()
    var requestID: UUID?
    var heard: String
    var intended: String
    var cause: Cause

    func save(directory: URL = RuntimeConfiguration.dataDirectory.appendingPathComponent("reviewed-corrections")) async throws {
        guard !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !intended.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              heard.count <= 4096, intended.count <= 4096 else { throw CorrectionError.invalid }
        let result: Result<Void, Error> = await RustPipeline.runBlocking { Result {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // One immutable file per reviewed correction avoids append races.
            let url = directory.appendingPathComponent(id.uuidString + ".json")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: url, options: [.withoutOverwriting])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } }
        try result.get()
    }
    enum CorrectionError: LocalizedError {
        case invalid
        var errorDescription: String? { "Enter the original command and your correction (up to 4,096 characters each)." }
    }
}
