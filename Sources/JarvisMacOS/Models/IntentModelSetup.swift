import Foundation
import Combine

@MainActor
final class IntentModelSetup: ObservableObject {
    static let shared = IntentModelSetup(runtimeStatus: {
        guard await BackendServiceManager.isBackendResponding() else { return nil }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000/intent_model/status")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await BackendAccess.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["update_error"] as? String
    })
    @Published private(set) var installedVersion: String?
    @Published private(set) var latestVersion: String?
    @Published private(set) var isInstalled = false
    @Published private(set) var isBusy = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var updateAvailable = false
    @Published private(set) var message = "Check the published intent model when you’re ready."
    @Published private(set) var lastChecked: Date?
    @Published private(set) var runtimeWarning: String?
    private let storage: IntentModelStorage
    private let remote: any IntentModelRemote
    private let runtimeStatus: @Sendable () async -> String?
    private var work: Task<Void, Never>?
    private var operationID: UUID?
    private var bootstrapped = false
    private var localReceipt: IntentModelReceipt?
    private var pending: RemoteIntentRelease?

    init(storage: IntentModelStorage? = nil, remote: any IntentModelRemote = HuggingFaceIntentRemote(),
         runtimeStatus: @escaping @Sendable () async -> String? = { nil }) {
        self.storage = storage ?? IntentModelStorage(
            root: RuntimeConfiguration.dataDirectory.appendingPathComponent("models/intent", isDirectory: true),
            bundled: Bundle.main.resourceURL?.appendingPathComponent("backend/models/intent-t5-small", isDirectory: true)
        )
        self.remote = remote
        self.runtimeStatus = runtimeStatus
    }

    /// Only a missing model auto-installs. Existing installations check for
    /// updates in Setup and keep working offline; no Python is started here.
    func startAutomaticSetup() {
        guard !bootstrapped else { return }
        bootstrapped = true
        start {
            await self.refreshLocal()
            if !self.isInstalled {
                try await self.check()
                try await self.downloadPending()
            }
        }
    }
    func checkForUpdates() { start { await self.refreshLocal(); try await self.check() } }
    func installLatest(force: Bool = false) {
        start {
            await self.refreshLocal()
            try await self.check()
            if !self.isInstalled || self.updateAvailable || force { try await self.downloadPending() }
        }
    }
    func cancel() { work?.cancel() }
    func refreshRuntimeStatus() async { runtimeWarning = await runtimeStatus() }
    func waitForIdle() async { await work?.value }

    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        guard work == nil else { return }
        isBusy = true
        operationID = UUID()
        work = Task {
            defer { self.isBusy = false; self.isDownloading = false; self.work = nil; self.operationID = nil }
            do { try await operation() }
            catch is CancellationError { self.message = "Download cancelled. Your existing model is unchanged." }
            catch let error as URLError where error.code == .cancelled {
                self.message = "Download cancelled. Your existing model is unchanged."
            }
            catch {
                self.message = "\(error.localizedDescription)\(self.isInstalled ? " Your installed model is still available." : " Native commands and dictation remain available.")"
            }
        }
    }
    private func refreshLocal() async {
        let local = await storage.inspect()
        localReceipt = local.receipt
        isInstalled = local.installed
        installedVersion = local.receipt?.version ?? (local.bundled ? "Bundled" : nil)
    }
    private func check() async throws {
        message = "Checking the latest intent model…"
        let release = try await remote.latest()
        try Task.checkCancellation()
        try release.validate()
        pending = release
        latestVersion = release.manifest.version
        lastChecked = Date()
        updateAvailable = !isInstalled || localReceipt == nil || localReceipt?.manifestSHA256 != intentSHA256(release.manifestData)
        if let localReceipt, versionIsOlder(release.manifest.version, than: localReceipt.version) {
            updateAvailable = false
            message = "You have a newer model installed than the current server release. It will be kept."
        } else if updateAvailable {
            message = isInstalled ? "Intent model \(release.manifest.version) is available." : "Intent model \(release.manifest.version) is ready to download (about \(release.manifest.totalBytes / 1_000_000) MB)."
        } else { message = "The intent model is up to date." }
    }
    private func downloadPending() async throws {
        guard let release = pending else { return }
        isDownloading = true
        progress = 0
        message = "Downloading intent model \(release.manifest.version)…"
        let id = operationID
        let staging = try await storage.createStaging()
        do {
            var completed: Int64 = 0
            for file in release.manifest.files {
                try Task.checkCancellation()
                let base = completed
                try await remote.download(file, release: release, into: staging) { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.isDownloading, self.operationID == id else { return }
                        self.progress = max(self.progress, min(1, Double(base + bytes) / Double(release.manifest.totalBytes)))
                    }
                }
                completed += file.sizeBytes
            }
            try Task.checkCancellation()
            message = "Verifying the downloaded model…"
            let receipt = try await storage.activate(release, staging: staging)
            localReceipt = receipt
            isInstalled = true
            installedVersion = receipt.version
            updateAvailable = false
            progress = 1
            message = "Intent model \(receipt.version) installed. It will be used for the next model-routed command."
        } catch {
            await storage.discard(staging)
            throw error
        }
    }
}

/// Compare arbitrary-length numeric components without integer overflow.
func versionIsOlder(_ left: String, than right: String) -> Bool {
    func numeric(_ a: String, _ b: String) -> Bool? {
        let l = String(a.drop(while: { $0 == "0" })), r = String(b.drop(while: { $0 == "0" }))
        if l.count != r.count { return l.count < r.count }
        return l == r ? nil : l < r
    }
    let a = left.split(separator: "-", maxSplits: 1), b = right.split(separator: "-", maxSplits: 1)
    for (l, r) in zip(a[0].split(separator: "."), b[0].split(separator: ".")) {
        if let older = numeric(String(l), String(r)) { return older }
    }
    if a.count != b.count { return a.count > b.count }
    guard a.count == 2 else { return false }
    let al = a[1].split(separator: "."), bl = b[1].split(separator: ".")
    for (l, r) in zip(al, bl) {
        if l == r { continue }
        let ln = l.allSatisfy(\.isNumber), rn = r.allSatisfy(\.isNumber)
        if ln && rn { if let older = numeric(String(l), String(r)) { return older } }
        else if ln != rn { return ln }
        else { return l < r }
    }
    return al.count < bl.count
}
