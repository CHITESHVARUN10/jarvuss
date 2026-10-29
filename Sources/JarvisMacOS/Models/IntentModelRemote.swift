import Foundation

protocol IntentModelRemote: Sendable {
    func latest() async throws -> RemoteIntentRelease
    func download(_ file: IntentModelRelease.File, release: RemoteIntentRelease, into directory: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws
}

/// Public, credential-free downloads. Resolve main once, then pin every file
/// to that commit so a simultaneous publication cannot mix model versions.
final class HuggingFaceIntentRemote: IntentModelRemote, @unchecked Sendable {
    static let repository = "chitesh12545/jarvis-intent-t5-small"
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 1800
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    func latest() async throws -> RemoteIntentRelease {
        let api = URL(string: "https://huggingface.co/api/models/\(Self.repository)/revision/main")!
        let (info, _) = try await data(api, limit: 2_000_000)
        let object = try JSONSerialization.jsonObject(with: info) as? [String: Any]
        guard let commit = object?["sha"] as? String,
              commit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw IntentModelError.message("Could not identify the latest published intent model.")
        }
        let (bytes, _) = try await data(fileURL("model-release.json", commit: commit), limit: 64_000)
        let manifest = try JSONDecoder().decode(IntentModelRelease.self, from: bytes)
        let release = RemoteIntentRelease(commit: commit, manifest: manifest, manifestData: bytes)
        try release.validate()
        return release
    }

    func download(_ file: IntentModelRelease.File, release: RemoteIntentRelease, into directory: URL,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try release.validate()
        guard release.manifest.files.contains(file) else { throw IntentModelError.message("Unexpected model download.") }
        let delegate = DownloadDelegate(expectedBytes: file.sizeBytes, progress: progress)
        let (temporary, response) = try await session.download(for: URLRequest(url: fileURL(file.name, commit: release.commit)), delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw IntentModelError.message("A model download was unavailable. Retry when the connection is ready.")
        }
        try Task.checkCancellation()
        let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
        guard size == file.sizeBytes else { throw IntentModelError.message("The model download is incomplete. Your current model is unchanged.") }
        try FileManager.default.moveItem(at: temporary, to: directory.appendingPathComponent(file.name))
        progress(file.sizeBytes)
    }

    private func fileURL(_ name: String, commit: String) -> URL {
        URL(string: "https://huggingface.co/\(Self.repository)/resolve/\(commit)/\(name)")!
    }
    private func data(_ url: URL, limit: Int) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: DownloadDelegate(expectedBytes: Int64(limit), progress: { _ in }))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= limit else {
            throw IntentModelError.message("The intent model release could not be checked. Your installed model remains available.")
        }
        return (data, response)
    }

    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expectedBytes: Int64
        let progress: @Sendable (Int64) -> Void
        private let lock = NSLock()
        private var lastReport = Date.distantPast
        init(expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
            self.expectedBytes = expectedBytes; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > expectedBytes { downloadTask.cancel() }
            else {
                let report = lock.withLock {
                    let now = Date()
                    if totalBytesWritten == expectedBytes || now.timeIntervalSince(lastReport) >= 0.1 {
                        lastReport = now; return true
                    }
                    return false
                }
                if report { progress(totalBytesWritten) }
            }
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let url = request.url, url.scheme == "https", let host = url.host,
                  host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co") else {
                completionHandler(nil); return
            }
            var clean = request
            clean.setValue(nil, forHTTPHeaderField: "Authorization")
            clean.setValue(nil, forHTTPHeaderField: "X-Jarvis-Token")
            completionHandler(clean)
        }
    }
}
