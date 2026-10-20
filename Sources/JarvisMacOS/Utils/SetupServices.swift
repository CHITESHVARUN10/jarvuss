import Foundation
import AppKit

// MARK: - Ollama setup actions

enum OllamaSetup {
    static func ollamaBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama",
                          "/Applications/Ollama.app/Contents/Resources/ollama"]
        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["ollama"]
        guard let out = try? process.runCapturingOutput(timeout: 5), out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static func isInstalled() -> Bool {
        ollamaBinary() != nil
    }

    /// Runs when the binary is missing. Brew-first, web page as fallback.
    static func install(onLine: @escaping (String) -> Void) async -> String {
        guard brewPath() != nil else {
            if let url = URL(string: "https://ollama.com/download") {
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
            }
            return "Opened the Ollama download page — install it, then reopen Setup."
        }
        onLine("brew install ollama — this can take a while…")
        let result = try? await brewProcess(arguments: ["install", "ollama"], timeout: 900)
        guard let result, result.status == 0 else {
            return "brew install ollama failed: \(result?.stderr ?? "unknown error")"
        }
        return ""
    }

    static func start() async -> String {
        let process = Process()
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Ollama"]
        } else if let brew = brewPath() {
            process.executableURL = URL(fileURLWithPath: brew)
            process.arguments = ["services", "start", "ollama"]
        } else {
            return "Open Ollama or run ollama serve, then refresh Setup."
        }
        do {
            let result = try await process.runCapturingOutputAsync(timeout: 60)
            return result.status == 0 ? "Ollama is starting. Refresh Setup in a few seconds." : "Could not start Ollama: \(result.stderr)"
        } catch { return "Could not start Ollama: \(error.localizedDescription)" }
    }

    static func pullModel(onProgress: @escaping (String) -> Void) async -> String? {
        guard let ollamaPath = ollamaBinary() else { return "Install Ollama first." }
        // The server can still be starting right after Install/Start — pull
        // would fail with "connection refused" and look like a broken button.
        onProgress("Waiting for Ollama to start…")
        guard await waitUntilReachable(timeout: 30) else {
            return "Ollama is not responding on port 11434. Press Start, then retry Pull."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ollamaPath)
        process.arguments = ["pull", JarvisModel.name]
        onProgress("Downloading \(JarvisModel.name). This may take several minutes…")
        do {
            let result = try await process.runCapturingOutputAsync(timeout: 3600)
            onProgress(result.status == 0 ? "Model installed." : "Download failed. Retry when Ollama is running.")
            return result.status == 0 ? nil : "Model download failed: \(result.stderr)"
        } catch { return error.localizedDescription }
    }

    static func waitUntilReachable(timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request),
               ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2 {
                return true
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    static func brewPath() -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    private static func brewProcess(arguments: [String], timeout: TimeInterval) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath()!)
        process.arguments = arguments
        return try await process.runCapturingOutputAsync(timeout: timeout)
    }
}

// MARK: - Homebrew actions (Postgres)

enum HomebrewActions {
    static func brewPath() -> String? {
        for candidate in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func prepareBackend(onLine: @escaping (String) -> Void) async -> String {
        guard BackendServiceManager.mode != .off else {
            return "Turn the backend to Automatic or Always running in Assistant before preparing it."
        }
        let pythonInstalled = ["/opt/homebrew/bin/python3.11", "/usr/local/bin/python3.11"]
            .contains { FileManager.default.isExecutableFile(atPath: $0) }
        if !pythonInstalled {
            guard let brew = brewPath() else { return "Install Homebrew from brew.sh, then retry Prepare." }
            onLine("Installing Python 3.11…")
            do {
                let result = try await Process().executable(cmd: brew, args: ["install", "python@3.11"])
                    .runCapturingOutputAsync(timeout: 1800)
                guard result.status == 0 else { return "Python installation failed: \(result.stderr)" }
            } catch { return error.localizedDescription }
        }
        onLine("Preparing helper dependencies. The first download may take several minutes…")
        let ready = await BackendServiceManager.ensureRunningForFeature()
        onLine(ready ? "Helper ready. Voice models load only when needed." : "Preparation failed. See Jarvis/logs/backend-pip.log in Application Support.")
        return ready ? "Python helper is ready." : "Could not prepare the helper. Check the backend logs and retry."
    }

    /// brew install postgresql@18 (when missing) + brew services start.
    static func installAndStartPostgres(onLine: @escaping (String) -> Void) async -> String? {
        guard let brew = brewPath() else {
            if let url = URL(string: "https://brew.sh") {
                _ = await MainActor.run { NSWorkspace.shared.open(url) }
            }
            return "Homebrew not found — install it from brew.sh, then retry."
        }
        let formula = "postgresql@18"

        let listed = try? await Process()
            .executable(cmd: brew, args: ["list", "--formula", formula])
            .runCapturingOutputAsync(timeout: 60)
        if listed?.status != 0 {
            onLine("brew install \(formula) …")
            let install = try? await Process()
                .executable(cmd: brew, args: ["install", formula])
                .runCapturingOutputAsync(timeout: 1800)
            guard let install, install.status == 0 else {
                return "brew install \(formula) failed: \(install?.stderr ?? "timed out or unknown error")"
            }
        }

        onLine("brew services start \(formula) …")
        let start = try? await Process()
            .executable(cmd: brew, args: ["services", "start", formula])
            .runCapturingOutputAsync(timeout: 120)
        guard let start, start.status == 0 else {
            return "brew services start failed: \(start?.stderr ?? "unknown error")"
        }
        return nil
    }
}

private extension Process {
    func executable(cmd: String, args: [String]) -> Process {
        executableURL = URL(fileURLWithPath: cmd)
        arguments = args
        return self
    }
}
