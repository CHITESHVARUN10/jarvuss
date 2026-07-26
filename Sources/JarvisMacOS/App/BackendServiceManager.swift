import Foundation

struct BackendStartupResult {
    let success: Bool
    let message: String
}

// MARK: - Health probe result
private enum HealthProbeResult {
    case healthy
    case unhealthy(statusCode: Int)
    case noResponse(error: String)
}

final class BackendServiceManager {
    private var started = false
    private let healthURL = URL(string: "http://127.0.0.1:8000/health")!

    // MARK: - Public API

    func startIfNeeded(log: @escaping (String) -> Void) async -> BackendStartupResult {
        if started {
            return BackendStartupResult(success: true, message: "Backend already started in this session")
        }

        // Fast path: already healthy (e.g. stale/orphaned uvicorn still alive on port 8000).
        // Reuse it rather than spawning a second process.
        let probe = await probeHealth()
        if case .healthy = probe {
            log("[Backend] Port 8000 already healthy — reusing existing process")
            started = true
            return BackendStartupResult(success: true, message: "Backend already running")
        }

        guard let scriptPath = bundledStartScriptPath() else {
            return BackendStartupResult(
                success: false,
                message: "Missing `start_backend.sh` in app bundle"
            )
        }

        // Resemblyzer imports torch at startup which can take 5–15 s on a cold
        // Python interpreter before uvicorn binds. Allow 20 s per attempt so the
        // total retry budget (40 s across 2 attempts) comfortably covers that.
        for attempt in 1...2 {
            log("[Backend] Launch attempt \(attempt)/2 (timeout: 20 s each)")
            let launch = runStartScript(scriptPath: scriptPath)
            if !launch.success {
                log("[Backend][ERROR] Failed to execute start script: \(launch.message)")
            }

            if await waitForHealth(timeoutSeconds: 20, log: log) {
                started = true
                return BackendStartupResult(success: true, message: "Backend started (attempt \(attempt))")
            }

            log("[Backend][WARN] Health check failed after attempt \(attempt)/2")
        }

        return BackendStartupResult(
            success: false,
            message: "Backend failed to start after 2 attempts (40 s total). Check ~/Library/Application Support/Jarvis/logs/backend.log"
        )
    }

    func stopIfNeeded(log: @escaping (String) -> Void) {
        guard let pidFile = pidFilePath() else { return }

        guard let pidText = try? String(contentsOf: URL(fileURLWithPath: pidFile), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidText),
              pid > 0 else {
            return
        }

        let terminated = kill(pid, SIGTERM) == 0
        if terminated {
            log("[Backend] Stopped backend process pid=\(pid)")
        }

        try? FileManager.default.removeItem(atPath: pidFile)
        started = false
    }

    // MARK: - Private helpers

    private func bundledStartScriptPath() -> String? {
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let scriptURL = executableDir.appendingPathComponent("start_backend.sh")
            if FileManager.default.fileExists(atPath: scriptURL.path) {
                return scriptURL.path
            }
        }
        return nil
    }

    private func pidFilePath() -> String? {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
        return support.appendingPathComponent("backend.pid").path
    }

    private func runStartScript(scriptPath: String) -> (success: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error  = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let merged = [output, error]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (process.terminationStatus == 0, merged.isEmpty ? "no output" : merged)
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
                    log("[Backend] Health probe: \(reason) — backend may still be importing torch")
                    lastReason = reason
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
        }
        return false
    }

    private func probeHealth() async -> HealthProbeResult {
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
    private func isHealthy() async -> Bool {
        if case .healthy = await probeHealth() { return true }
        return false
    }
}
