import Foundation
import CDDCShim

struct FileSearchResult: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
    let isDirectory: Bool
}

struct FileSearchSnapshot {
    let results: [FileSearchResult]
    let limited: Bool
    let timedOut: Bool
}

@MainActor
protocol FileSearching {
    func search(_ request: LocalSearchRequest, roots: [URL]) async throws -> FileSearchSnapshot
}

@MainActor
struct SpotlightFileSearch: FileSearching {
    func search(_ request: LocalSearchRequest, roots: [URL]) async throws -> FileSearchSnapshot {
        let session = SpotlightSearchSession(request: request, roots: roots)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await session.run()
        } onCancel: {
            session.cancel()
        }
    }
}

/// One finite, cancellable gather. Stop before publishing a frozen ordering so
/// a voice reference to “the second one” cannot change under the user.
final class SpotlightSearchSession: @unchecked Sendable {
    private let request: LocalSearchRequest
    private let roots: [URL]
    // Confine Foundation query work and mutable state to one serial queue.
    // Startup exceptions are caught in Objective-C, before they can unwind
    // through a Swift task and leave the UI in a broken executor context.
    private let worker: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Jarvis.SpotlightSearch"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var query: NSMetadataQuery?
    private var continuation: CheckedContinuation<FileSearchSnapshot, Error>?
    private var observer: NSObjectProtocol?
    private var timeout: DispatchWorkItem?
    private var cancelled = false

    init(request: LocalSearchRequest, roots: [URL]) { self.request = request; self.roots = roots }

    func run() async throws -> FileSearchSnapshot {
        return try await withCheckedThrowingContinuation { continuation in
            worker.addOperation { [self] in begin(continuation) }
        }
    }

    private func begin(_ continuation: CheckedContinuation<FileSearchSnapshot, Error>) {
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let query = NSMetadataQuery()
        self.query = query
        query.operationQueue = worker
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: nil) { [weak self] _ in
            self?.worker.addOperation { [weak self] in self?.finish(timedOut: false) }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.worker.addOperation { [weak self] in self?.finish(timedOut: true) }
        }
        self.timeout = timeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        var error: NSError?
        let scopes = roots.isEmpty ? [NSMetadataQueryLocalComputerScope] : roots.map(\.path)
        if !JarvisStartMetadataQuery(query, request.predicate(), scopes,
                                    [NSSortDescriptor(key: "kMDItemFSContentChangeDate", ascending: false)], &error) {
            complete(.failure(error ?? SearchError.unavailable as NSError))
        }
    }

    func cancel() {
        worker.addOperation { [self] in
            cancelled = true
            complete(.failure(CancellationError()))
        }
    }

    private func finish(timedOut: Bool) {
        guard continuation != nil, let query else { return }
        query.disableUpdates()
        let count = query.resultCount
        let candidates = (0..<min(count, 500)).compactMap { index -> FileSearchResult? in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String else { return nil }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard Self.isWithinRoots(url, roots: roots),
                  !url.pathComponents.contains(where: { $0.hasPrefix(".") }),
                  !(item.value(forAttribute: "kMDItemContentTypeTree") as? [String] ?? []).contains("com.apple.application-bundle") else { return nil }
            return FileSearchResult(url: url, name: item.value(forAttribute: "kMDItemFSName") as? String ?? url.lastPathComponent,
                size: (item.value(forAttribute: "kMDItemFSSize") as? NSNumber)?.int64Value ?? 0,
                modified: item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date ?? .distantPast,
                isDirectory: item.value(forAttribute: "kMDItemContentType") as? String == "public.folder")
        }
        let results = Self.rank(candidates, query: request.query)
        complete(.success(FileSearchSnapshot(results: Array(results.prefix(100)), limited: count > 500 || results.count > 100, timedOut: timedOut)))
    }

    static func isWithinRoots(_ url: URL, roots: [URL]) -> Bool {
        roots.isEmpty || roots.contains { root in
            url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
        }
    }

    static func rank(_ values: [FileSearchResult], query: String) -> [FileSearchResult] {
        let unique = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
        func score(_ item: FileSearchResult) -> Int {
            guard !query.isEmpty else { return 0 }
            let name = item.url.deletingPathExtension().lastPathComponent
            if name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame { return 2 }
            return name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil ? 0 : 1
        }
        return unique.sorted {
            if score($0) != score($1) { return score($0) > score($1) }
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }

    private func complete(_ result: Result<FileSearchSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timeout?.cancel(); timeout = nil
        query = nil
        continuation.resume(with: result)
    }
}
