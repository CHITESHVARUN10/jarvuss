import Foundation

struct BackendStartupResult {
    let success: Bool
    let message: String
}

/// Backend process policy. `.automatic` (default) starts Python only when a
/// feature needs it and idles it out after `idleUnloadInterval`; `.always`
/// preserves the launch-at-boot behavior; `.off` never starts it.
enum BackendMode: String, CaseIterable {
    case automatic
    case always
    case off

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .always:    return "Always running"
        case .off:       return "Off"
        }
    }
}

// MARK: - Health probe result
private enum HealthProbeResult {
    case healthy
    case unhealthy(statusCode: Int)
    case noResponse(error: String)
}

final class BackendServiceManager {
    static let shared = BackendServiceManager()
    static let modeDefaultsKey = "jarvis.backendMode"

    static var mode: BackendMode {
        get { BackendMode(rawValue: UserDefaults.standard.string(forKey: modeDefaultsKey) ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeDefaultsKey) }
    }

    static let idleUnloadInterval: TimeInterval = 300
    /// Set by AppState so an idle stop updates the visible status text.
    static var idleStopHandler: ((String) -> Void)?
    @MainActor static var statusChangeHandler: ((String) -> Void)?

    private static let idleLock = NSLock()
    private static var lastActivity = Date.distantPast
    private static var watchdogArmed = false

    static func noteActivity() {
        idleLock.lock()
        lastActivity = Date()
        idleLock.unlock()
    }

    /// Pure decision so the idle policy is unit-testable.
    static func shouldIdleStop(mode: BackendMode, lastActivity: Date, now: Date = Date()) -> Bool {
        guard mode == .automatic else { return false }
        return now.timeIntervalSince(lastActivity) >= idleUnloadInterval
    }

    static func armIdleWatchdog() {
        idleLock.lock()
        let alreadyArmed = watchdogArmed
        watchdogArmed = true
        idleLock.unlock()
        guard !alreadyArmed else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak shared] in
            guard shouldIdleStop(mode: mode, lastActivity: lastActivitySnapshot()) else { return }
            guard let shared else { return }
            Task { @MainActor in
                // Recheck on the lifecycle actor: activity may arrive while queued.
                guard shared.startupTask == nil,
                      shouldIdleStop(mode: mode, lastActivity: lastActivitySnapshot()) else { return }
                shared.stopIfNeeded { message in
                    NSLog("%@", message)
                    idleStopHandler?(message)
                }
            }
        }
        timer.resume()
        idleWatchdog = timer
    }
    private static var idleWatchdog: DispatchSourceTimer?

    private static func lastActivitySnapshot() -> Date {
        idleLock.lock(); defer { idleLock.unlock() }
        return lastActivity
    }

    /// Entry point for every feature that talks to the backend: starts the
    /// process on demand (idempotent) and records activity. `.off` refuses.
    static func ensureRunningForFeature() async -> Bool {
        guard mode != .off else {
            NSLog("[Backend] Refusing to start: backend mode is Off")
            return false
        }
        noteActivity()
        let result = await shared.startIfNeeded { message in
            NSLog("%@", message)
        }
        armIdleWatchdog()
        if result.success { noteActivity() }
        return result.success && !Task.isCancelled && mode != .off
    }

    /// Non-starting probe for status display (2 s timeout).
    static func isBackendResponding() async -> Bool {
        await shared.isHealthy()
    }

    @MainActor private var startupTask: Task<BackendStartupResult, Never>?
    @MainActor private var startupID: UUID?
    private let healthURL = URL(string: "http://127.0.0.1:8000/health")!

    private let healthOverride: (() async -> Bool)?
    private let launchOverride: (() async -> Bool)?

    init(healthProbe: (() async -> Bool)? = nil, launcher: (() async -> Bool)? = nil) {
        healthOverride = healthProbe
        launchOverride = launcher
    }

    // MARK: - Public API

    @MainActor
    func startIfNeeded(log: @escaping (String) -> Void) async -> BackendStartupResult {
        if let startupTask { return await startupTask.value }
        let id = UUID()
        if self === Self.shared { Self.statusChangeHandler?("Starting backend…") }
        startupID = id
        let task = Task { await self.start(log: log) }
        startupTask = task
        let result = await task.value
        if startupID == id {
            startupTask = nil
            startupID = nil
            if self === Self.shared {
                Self.statusChangeHandler?(result.success ? "Backend running" : "Backend unavailable")
            }
        }
        return result
    }

    @MainActor
    private func start(log: @escaping (String) -> Void) async -> BackendStartupResult {
        if Self.mode == .off {
            return BackendStartupResult(success: false, message: "Backend is set to Off (Assistant → Behaviour)")
        }

        // Fast path: already healthy (e.g. stale/orphaned uvicorn still alive on port 8000).
        // Reuse it rather than spawning a second process.
        let probe = await probeHealth()
        if case .healthy = probe, !Task.isCancelled, Self.mode != .off {
            log("[Backend] Port 8000 already healthy — reusing existing process")
            return BackendStartupResult(success: true, message: "Backend already running")
        }

        guard let scriptPath = launchOverride == nil ? bundledStartScriptPath() : "test-launcher" else {
            return BackendStartupResult(
                success: false,
                message: "Missing `start_backend.sh` in app bundle"
            )
        }

        // Torch imports lazily (first voice request), but a cold Python
        // interpreter + uvicorn bind still takes a few seconds. Allow 20 s per
        // attempt so the total retry budget (40 s across 2 attempts) covers it.
        for attempt in 1...2 {
            log("[Backend] Launch attempt \(attempt)/2 (timeout: 20 s each)")
            guard !Task.isCancelled, Self.mode != .off else {
                return BackendStartupResult(success: false, message: "Backend startup cancelled")
            }
            let launch = await runStartScript(scriptPath: scriptPath)
            if !launch.success {
                log("[Backend][ERROR] Failed to execute start script: \(launch.message)")
                return BackendStartupResult(success: false,
                    message: "Backend preparation failed: \(launch.message). Check logs/backend-pip.log in Jarvis Application Support.")
            }

            if await waitForHealth(timeoutSeconds: 20, log: log) {
                return BackendStartupResult(success: true, message: "Backend started (attempt \(attempt))")
            }

            log("[Backend][WARN] Health check failed after attempt \(attempt)/2")
        }

        return BackendStartupResult(
            success: false,
            message: "Backend failed to start after 2 attempts (40 s total). Check ~/Library/Application Support/Jarvis/logs/backend.log"
        )
    }

    @MainActor
    func stopIfNeeded(log: @escaping (String) -> Void) {
        startupTask?.cancel()
        startupTask = nil
        startupID = nil
        guard let pidFile = pidFilePath() else { return }

        guard let pidText = try? String(contentsOf: URL(fileURLWithPath: pidFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidText),
              pid > 0 else {
            return
        }

        // A stale PID file can point at an unrelated process after PID reuse.
        let inspection = Process()
        inspection.executableURL = URL(fileURLWithPath: "/bin/ps")
        inspection.arguments = ["-p", String(pid), "-o", "command="]
        guard let output = try? inspection.runCapturingOutput(timeout: 2),
              output.status == 0, Self.isBackendCommand(output.stdout) else {
            log("[Backend] Ignoring stale PID file; process is not the Jarvis helper")
            try? FileManager.default.removeItem(atPath: pidFile)
            return
        }

        let terminated = kill(pid, SIGTERM) == 0
        if terminated {
            log("[Backend] Stopped backend process pid=\(pid)")
        }

        try? FileManager.default.removeItem(atPath: pidFile)
    }

    static func isBackendCommand(_ command: String) -> Bool {
        if command.range(of: #"(?:^|\s)-m\s+uvicorn\s+voice_auth_service:app(?:\s|$)"#,
                         options: .regularExpression) != nil { return true }
        guard let resources = Bundle.main.resourceURL else { return false }
        let frozen = resources.appendingPathComponent("backend/main").path
        return command == frozen || command.hasPrefix(frozen + " ")
    }

    // MARK: - Private helpers

    private func bundledStartScriptPath() -> String? {
        let fm = FileManager.default
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let macOSScript = executableDir.appendingPathComponent("start_backend.sh")
            if fm.fileExists(atPath: macOSScript.path) {
                return macOSScript.path
            }
            // Same bundle, Resources layout: Contents/Resources/backend/../start_backend.sh
            let resourcesScript = executableDir
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/backend/start_backend.sh")
            if fm.fileExists(atPath: resourcesScript.path) {
                return resourcesScript.path
            }
        }
        if let resourceDir = Bundle.main.resourcePath {
            let resScript = (resourceDir as NSString).appendingPathComponent("backend/start_backend.sh")
            if fm.fileExists(atPath: resScript) {
                return resScript
            }
        }
        // Dev fallback: running via `swift run` — use the repo script.
        for candidate in [
            "scripts/start_backend.sh",
            "../scripts/start_backend.sh",
        ] {
            let cwd = (fm.currentDirectoryPath as NSString).appendingPathComponent(candidate)
            if fm.fileExists(atPath: cwd) {
                return cwd
            }
        }
        return nil
    }

    private func pidFilePath() -> String? {
        RuntimeConfiguration.dataDirectory.appendingPathComponent("backend.pid").path
    }

    private func runStartScript(scriptPath: String) async -> (success: Bool, message: String) {
        if let launchOverride {
            return (await launchOverride(), "Injected launcher")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath]

        do {
            let result = try await process.runCapturingOutputAsync(timeout: 1800)
            let merged = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
            return (result.status == 0, merged.isEmpty ? "no output" : merged)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Polls `/health` every 500 ms up to `timeoutSeconds`. Logs each distinct
    /// failure reason so the caller can distinguish "no response" from "unhealthy".
    private func waitForHealth(timeoutSeconds: TimeInterval, log: @escaping (String) -> Void) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var lastReason = ""
        while Date() < deadline {
            guard !Task.isCancelled, Self.mode != .off else { return false }
            let probe = await probeHealth()
            switch probe {
            case .healthy:
                return true
            case .unhealthy(let code):
                let reason = "HTTP \(code)"
                if reason != lastReason {
                    log("[Backend] Health probe: responded but unhealthy (\(reason))")
                    lastReason = reason
                }
            case .noResponse(let err):
                let reason = "no response (\(err))"
                if reason != lastReason {
                    log("[Backend] Health probe: \(reason) — backend is not ready")
                    lastReason = reason
                }
            }
            do { try await Task.sleep(nanoseconds: 500_000_000) }
            catch { return false }
        }
        return false
    }

    private func probeHealth() async -> HealthProbeResult {
        if let healthOverride { return await healthOverride() ? .healthy : .unhealthy(statusCode: 503) }
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? .healthy : .unhealthy(statusCode: code)
        } catch {
            return .noResponse(error: error.localizedDescription)
        }
    }

    // Convenience wrapper for call sites that don't need per-probe logging.
    func isHealthy() async -> Bool {
        if case .healthy = await probeHealth() { return true }
        return false
    }
}
