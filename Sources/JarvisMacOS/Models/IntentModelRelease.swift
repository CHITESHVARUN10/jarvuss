import Foundation
import CryptoKit

struct IntentModelRelease: Codable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable {
        let name: String
        let sizeBytes: Int64
        let sha256: String
        enum CodingKeys: String, CodingKey { case name, sizeBytes = "size_bytes", sha256 }
    }
    let formatVersion: Int
    let runtime: String
    let license: String?
    let version: String
    let intentSchemaVersion: Int
    let maxSourceLen: Int
    let maxTargetLen: Int
    let files: [File]
    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version", runtime, license, version, files
        case intentSchemaVersion = "intent_schema_version", maxSourceLen = "max_source_len", maxTargetLen = "max_target_len"
    }
    static let allowedFiles: Set<String> = [
        "encoder_model_quantized.onnx", "decoder_model_merged_quantized.onnx", "config.json",
        "generation_config.json", "added_tokens.json", "spiece.model", "special_tokens_map.json",
        "tokenizer.json", "tokenizer_config.json", "model_meta.json", "LICENSE", "NOTICE"
    ]
    static let requiredFiles: Set<String> = [
        "encoder_model_quantized.onnx", "decoder_model_merged_quantized.onnx", "config.json", "added_tokens.json", "spiece.model", "model_meta.json"
    ]
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    func validate() throws {
        guard formatVersion == 1, runtime == "jarvis-t5-onnx-v1", (1...4).contains(intentSchemaVersion),
              maxSourceLen == 128, maxTargetLen == 448 else {
            throw IntentModelError.message("This model release needs a newer Jarvis build. Your existing model is unchanged.")
        }
        guard version.count <= 80, version.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?$"#, options: .regularExpression) != nil,
              (6...12).contains(files.count), Set(files.map(\.name)).count == files.count,
              Set(files.map(\.name)).isSubset(of: Self.allowedFiles), Self.requiredFiles.isSubset(of: Set(files.map(\.name))) else {
            throw IntentModelError.message("The model release has an invalid file list or version.")
        }
        if license == "apache-2.0", !Set(["LICENSE", "NOTICE"]).isSubset(of: Set(files.map(\.name))) {
            throw IntentModelError.message("The release is missing its license notices.")
        }
        for file in files {
            guard file.sizeBytes > 0, file.sizeBytes <= 256_000_000,
                  file.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw IntentModelError.message("The model release contains invalid sizes or checksums.")
            }
        }
        guard totalBytes <= 350_000_000 else { throw IntentModelError.message("This model release exceeds the supported download size.") }
    }
}

struct RemoteIntentRelease: Sendable {
    let commit: String
    let manifest: IntentModelRelease
    let manifestData: Data
    func validate() throws {
        guard commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw IntentModelError.message("The model server returned an invalid revision.")
        }
        try manifest.validate()
        guard try JSONDecoder().decode(IntentModelRelease.self, from: manifestData) == manifest else {
            throw IntentModelError.message("The model manifest changed during download.")
        }
    }
}

struct IntentModelReceipt: Codable, Equatable, Sendable {
    let commit: String
    let version: String
    let directory: String
    let manifestSHA256: String
    let generation: String
    enum CodingKeys: String, CodingKey { case commit, version, directory, generation; case manifestSHA256 = "manifest_sha256" }
}

enum IntentModelError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func intentSHA256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// All disk/hash work stays on this actor, off the main actor. Versions are
/// immutable directories; activation only replaces a small JSON pointer.
actor IntentModelStorage {
    struct Local: Sendable {
        let receipt: IntentModelReceipt?
        let bundled: Bool
        var installed: Bool { receipt != nil || bundled }
    }
    let root: URL
    let bundled: URL?
    init(root: URL, bundled: URL? = nil) { self.root = root; self.bundled = bundled }

    func inspect() -> Local {
        let receipt = try? readReceipt()
        let bundled = bundled.map { folder in
            IntentModelRelease.requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        } ?? false
        return Local(receipt: receipt, bundled: bundled)
    }

    private func readReceipt() throws -> IntentModelReceipt {
        let receipt = try JSONDecoder().decode(IntentModelReceipt.self, from: Data(contentsOf: root.appendingPathComponent("current.json")))
        guard receipt.commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              receipt.directory.range(of: #"^[0-9a-f]{40}-[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              receipt.directory.hasPrefix(receipt.commit + "-") else { throw IntentModelError.message("Invalid installed model receipt.") }
        let folder = root.appendingPathComponent("versions").appendingPathComponent(receipt.directory)
        let data = try Data(contentsOf: folder.appendingPathComponent("model-release.json"))
        guard intentSHA256(data) == receipt.manifestSHA256 else { throw IntentModelError.message("Installed model manifest is damaged.") }
        let manifest = try JSONDecoder().decode(IntentModelRelease.self, from: data)
        try manifest.validate()
        guard manifest.version == receipt.version else { throw IntentModelError.message("Installed model version is inconsistent.") }
        for file in manifest.files {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file.name).path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.sizeBytes,
                  attributes[.type] as? FileAttributeType == .typeRegular else { throw IntentModelError.message("Installed model files are incomplete.") }
        }
        return receipt
    }

    func createStaging() throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("download-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    func discard(_ staging: URL) {
        guard staging.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              staging.lastPathComponent.hasPrefix("download-") else { return }
        try? FileManager.default.removeItem(at: staging)
    }

    func activate(_ release: RemoteIntentRelease, staging: URL) throws -> IntentModelReceipt {
        try Task.checkCancellation()
        try release.validate()
        guard staging.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              staging.lastPathComponent.hasPrefix("download-") else { throw IntentModelError.message("Invalid model staging directory.") }
        for file in release.manifest.files {
            try Task.checkCancellation()
            let url = staging.appendingPathComponent(file.name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.sizeBytes else {
                throw IntentModelError.message("The download of \(file.name) is incomplete. Retry to keep using your existing model.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hash.update(data: chunk)
            }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
                throw IntentModelError.message("Checksum verification failed for \(file.name). Your existing model is unchanged.")
            }
        }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: staging.appendingPathComponent("config.json"))) as? [String: Any]
        guard config?["model_type"] as? String == "t5" else { throw IntentModelError.message("The model architecture is incompatible with this Jarvis build.") }
        try release.manifestData.write(to: staging.appendingPathComponent("model-release.json"), options: .atomic)
        let directory = release.commit + "-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let versions = root.appendingPathComponent("versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let destination = versions.appendingPathComponent(directory)
        try FileManager.default.moveItem(at: staging, to: destination)
        let receipt = IntentModelReceipt(commit: release.commit, version: release.manifest.version, directory: directory,
                                         manifestSHA256: intentSHA256(release.manifestData), generation: UUID().uuidString)
        do {
            try Task.checkCancellation()
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("current.json"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return receipt
    }
}
