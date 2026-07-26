import Foundation

struct BackendStartupResult {
    let success: Bool
    let message: String
}

final class BackendServiceManager {
    private var started = false
    private let healthURL = URL(string: "http://127.0.0.1:8000/health")!

    func startIfNeeded(log: @escaping (String) -> Void) async -> BackendStartupResult {
        if started {
            return BackendStartupResult(success: true, message: "Backend already started in this session")
        }

        if await isHealthy() {
            started = true
            return BackendStartupResult(success: true, message: "Backend already running")
        }

        guard let scriptPath = bundledStartScriptPath() else {
            return BackendStartupResult(
                success: false,
                message: "Missing `start_backend.sh` in app bundle"
            )
        }

        for attempt in 1...2 {
            log("[Backend] Launch attempt \(attempt)/2")
            let launch = runStartScript(scriptPath: scriptPath)
            if !launch.success {
                log("[Backend][ERROR] Failed to execute start script: \(launch.message)")
            }

            if await waitForHealth(timeoutSeconds: 10) {
                started = true
                return BackendStartupResult(success: true, message: "Backend started successfully")
            }

            log("[Backend][WARN] Health check failed after attempt \(attempt)")
        }

        return BackendStartupResult(
            success: false,
            message: "Backend failed to start after one retry"
        )
    }

    func stopIfNeeded(log: @escaping (String) -> Void) {
        guard let pidFile = pidFilePath() else {
            return
        }

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
            let error = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let merged = [output, error]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return (
                process.terminationStatus == 0,
                merged.isEmpty ? "no output" : merged
            )
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func waitForHealth(timeoutSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await isHealthy() {
                return true
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        return false
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 2

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code)
        } catch {
            return false
        }
    }
}
