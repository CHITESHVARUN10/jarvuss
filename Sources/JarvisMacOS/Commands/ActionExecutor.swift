import Foundation

// MARK: - Action result

struct ActionResult {
    let action: PlannedAction
    let success: Bool
    let message: String
}

// MARK: - ActionExecutor

/// Executes a plan (array of PlannedActions) sequentially.
/// Each action is safety-checked immediately before execution.
final class ActionExecutor {

    private let appController    = AppController()
    private let fileManager      = JarvisFileManager()
    private let ollamaClient     = OllamaClient(model: "qwen2.5-coder:1.5b-base")
    private let volumeController = VolumeController()
    private let displayController = DisplayController()

    var onLog: ((String) -> Void)? {
        didSet {
            volumeController.onLog = onLog
            displayController.onLog = onLog
        }
    }

    // ── Delays between steps so macOS has time to open apps ─────────
    private let interStepDelay: TimeInterval = 0.8

    // MARK: - Public entry point

    /// Execute the plan and return per-step results.
    func execute(
        plan: [PlannedAction],
        onStepStart: @escaping (PlannedAction) -> Void,
        onStepComplete: @escaping (ActionResult) -> Void
    ) async {
        for action in plan {
            switch SafetyGuard.validate(action: action) {
            case .blocked(let reason):
                let result = ActionResult(action: action, success: false,
                                          message: "⛔ Blocked — \(reason)")
                onStepComplete(result)
                continue

            case .installPreview(let cmd, let source):
                let result = ActionResult(
                    action: action, success: false,
                    message: "🔒 Install Preview: '\(cmd)'. Source: \(source). " +
                             "Requires face auth + confirmation (not yet active)."
                )
                onStepComplete(result)
                continue

            case .allowed:
                break
            }

            onStepStart(action)
            let result = await runSingleAction(action)
            onStepComplete(result)

            if result.success && plan.count > 1 {
                try? await Task.sleep(nanoseconds: UInt64(interStepDelay * 1_000_000_000))
            }
        }
    }

    // MARK: - Single action runner

    private func runSingleAction(_ action: PlannedAction) async -> ActionResult {
        switch action {

        case .openApp(let name):
            let msg = appController.open(appName: name)
            return ActionResult(action: action, success: !msg.lowercased().contains("fail") &&
                                !msg.lowercased().contains("error"),
                                message: msg)

        case .closeApp(let name):
            let msg = appController.close(appName: name)
            return ActionResult(action: action, success: !msg.lowercased().contains("fail") &&
                                !msg.lowercased().contains("error"),
                                message: msg)

        case .systemInfo(let infoAction):
            return executeSystemInfo(infoAction)

        case .openURL(let url):
            return openURL(url)

        case .searchWeb(let engine, let query):
            return executeSearchWeb(engine: engine, query: query, action: action)

        case .openFolder(let path):
            let msg = fileManager.openFolder(named: path)
            return ActionResult(action: action, success: !msg.contains("not found") &&
                                !msg.lowercased().contains("fail"),
                                message: msg)

        case .openLatestFile(let folder):
            return openLatestFile(inFolder: folder)

        case .mediaControl(let mediaAction):
            return await executeMediaAction(mediaAction)

        case .volumeControl(let volumeAction):
            let msg = volumeController.execute(volumeAction)
            let displayMsg = msg.isEmpty ? volumeAction.responseText : msg
            let success = !displayMsg.lowercased().contains("no actual volume change")
            return ActionResult(action: action, success: success, message: displayMsg)

        case .createFile(let name):
            let msg = fileManager.createFile(named: name)
            return ActionResult(action: action, success: !msg.lowercased().contains("fail") &&
                                !msg.lowercased().contains("blocked"),
                                message: msg)

        case .createFolder(let name):
            let msg = fileManager.createFolder(named: name)
            return ActionResult(action: action, success: !msg.lowercased().contains("fail") &&
                                !msg.lowercased().contains("blocked"),
                                message: msg)

        case .aiQuery(let query):
            if query.hasPrefix("blocked:") {
                return ActionResult(action: action, success: false,
                                    message: "⛔ " + query)
            }
            let response = await ollamaClient.generate(prompt: query)
            return ActionResult(action: action, success: true, message: response)

        case .installPreview(let pkg, let source):
            return ActionResult(action: action, success: false,
                                message: "🔒 Install blocked: '\(pkg)'. Source: \(source).")

        case .displayControl(let displayAction):
            let msg = displayController.execute(displayAction)
            let success = !msg.lowercased().contains("fail") && !msg.lowercased().contains("error")
            return ActionResult(action: action, success: success, message: msg)
        }
    }

    private func executeSystemInfo(_ action: SystemInfoAction) -> ActionResult {
        switch action {
        case .currentTime:
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return ActionResult(action: .systemInfo(action), success: true, message: "Current time: \(formatter.string(from: Date()))")

        case .currentDate:
            let formatter = DateFormatter()
            formatter.dateStyle = .full
            formatter.timeStyle = .none
            return ActionResult(action: .systemInfo(action), success: true, message: "Today's date: \(formatter.string(from: Date()))")

        case .wifiStatus:
            let wifi = runShell("/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk -F': ' '/ SSID/ {print $2}'")
            if wifi.success, let ssid = wifi.output, !ssid.isEmpty {
                return ActionResult(action: .systemInfo(action), success: true, message: "Wi-Fi connected: \(ssid)")
            }
            return ActionResult(action: .systemInfo(action), success: false, message: "Unable to determine Wi-Fi network")

        case .bluetoothDevices:
            let bt = runShell("system_profiler SPBluetoothDataType 2>/dev/null | awk '/Device Name:/{name=$3} /Connected: Yes/{print name}'")
            if bt.success, let output = bt.output, !output.isEmpty {
                return ActionResult(action: .systemInfo(action), success: true, message: "Connected Bluetooth devices: \(output)")
            }
            return ActionResult(action: .systemInfo(action), success: true, message: "No connected Bluetooth devices found")

        case .batteryStatus:
            let batt = runShell("pmset -g batt | head -n 1; pmset -g batt | tail -n +2 | head -n 1")
            if batt.success, let output = batt.output, !output.isEmpty {
                return ActionResult(action: .systemInfo(action), success: true, message: "Battery status: \(output)")
            }
            return ActionResult(action: .systemInfo(action), success: false, message: "Unable to read battery status")

        case .systemVolume:
            let vol = runShell("osascript -e 'output volume of (get volume settings)'")
            if vol.success, let output = vol.output, let level = Int(output) {
                return ActionResult(action: .systemInfo(action), success: true, message: "System volume: \(level)%")
            }
            return ActionResult(action: .systemInfo(action), success: false, message: "Unable to read system volume")
        }
    }

    private func runShell(_ command: String) -> (success: Bool, output: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus == 0 {
                return (true, stdout)
            }

            let merged = [stdout, stderr].compactMap { $0 }.joined(separator: " ")
            return (false, merged.isEmpty ? nil : merged)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: - URL opener

    private func openURL(_ url: String) -> ActionResult {
        let normalized = url.hasPrefix("http") ? url : "https://\(url)"
        guard let urlObj = URL(string: normalized) else {
            return ActionResult(
                action: .openURL(url), success: false,
                message: "Invalid URL: \(url)"
            )
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [urlObj.absoluteString]
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            return ActionResult(action: .openURL(url), success: ok,
                                message: ok ? "Opened: \(normalized)" : "Failed to open URL: \(url)")
        } catch {
            return ActionResult(action: .openURL(url), success: false,
                                message: "URL open error: \(error.localizedDescription)")
        }
    }

    // MARK: - Search URL builder + opener

    private func executeSearchWeb(engine: String, query: String, action: PlannedAction) -> ActionResult {
        // Map engine name → base search URL
        let engineURLs: [String: String] = [
            "google":      "https://www.google.com/search?q=",
            "youtube":     "https://www.youtube.com/results?search_query=",
            "reddit":      "https://www.reddit.com/search/?q=",
            "twitter":     "https://twitter.com/search?q=",
            "x":           "https://twitter.com/search?q=",
            "bing":        "https://www.bing.com/search?q=",
            "duckduckgo":  "https://duckduckgo.com/?q=",
        ]

        let key = engine.lowercased()
        let baseURL = engineURLs[key] ?? "https://www.google.com/search?q="
        let engineLabel = engineURLs[key] != nil ? engine : "Google (fallback)"

        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: baseURL + encoded) else {
            return ActionResult(action: action, success: false,
                                message: "Could not build search URL for query: '\(query)'")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]

        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            return ActionResult(
                action: action,
                success: ok,
                message: ok
                    ? "Searching \(engineLabel) for '\(query)'"
                    : "Failed to open search URL"
            )
        } catch {
            return ActionResult(action: action, success: false,
                                message: "Search open error: \(error.localizedDescription)")
        }
    }

    // MARK: - Latest file opener

    private func openLatestFile(inFolder folderName: String) -> ActionResult {
        let fm   = Foundation.FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let folderAliases: [String: URL] = [
            "downloads": home.appendingPathComponent("Downloads"),
            "documents": home.appendingPathComponent("Documents"),
            "desktop":   home.appendingPathComponent("Desktop"),
        ]
        let folderURL = folderAliases[folderName.lowercased()]
            ?? home.appendingPathComponent(folderName)

        guard fm.fileExists(atPath: folderURL.path),
              let contents = try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
              ),
              let latest = contents.sorted(by: { a, b in
                  let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                  let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                  return da > db
              }).first
        else {
            return ActionResult(action: .openLatestFile(inFolder: folderName), success: false,
                                message: "No files found in '\(folderName)'.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [latest.path]
        do {
            try process.run()
            process.waitUntilExit()
            let ok = process.terminationStatus == 0
            return ActionResult(action: .openLatestFile(inFolder: folderName), success: ok,
                                message: ok ? "Opened latest file: \(latest.lastPathComponent)" : "Failed to open \(latest.lastPathComponent)")
        } catch {
            return ActionResult(action: .openLatestFile(inFolder: folderName), success: false,
                                message: "Open error: \(error.localizedDescription)")
        }
    }

    // MARK: - Spotify / media control (backend-only)

    private enum SpotifyBackendResult {
        case success(status: Int, message: String)
        case failure(status: Int?, message: String)
    }

    private struct SpotifyBackendEnvelope: Decodable {
        let status: String?
        let actionConfirmed: Bool?
        let message: String?
        let playbackState: PlaybackState?

        struct PlaybackState: Decodable {
            let isPlaying: Bool?

            enum CodingKeys: String, CodingKey {
                case isPlaying = "is_playing"
            }
        }

        enum CodingKeys: String, CodingKey {
            case status
            case actionConfirmed = "action_confirmed"
            case message
            case playbackState = "playback_state"
        }
    }

    private func executeMediaAction(_ action: MediaAction) async -> ActionResult {
        emitSpotify("[Media] Routing to backend Spotify: \(action.description)")

        let backendResult: SpotifyBackendResult
        switch action {
        case .play:
            backendResult = await callBackendSpotify(path: "/spotify/play")
        case .pause:
            backendResult = await callBackendSpotify(path: "/spotify/pause")
        case .nextTrack:
            backendResult = await callBackendSpotify(path: "/spotify/next")
        case .previousTrack:
            backendResult = await callBackendSpotify(path: "/spotify/previous")
        case .playLikedSongs:
            backendResult = await callBackendSpotify(path: "/spotify/play-liked")
        case .playSong(let name):
            backendResult = await callBackendSpotify(path: "/spotify/play-song", query: [
                URLQueryItem(name: "name", value: name)
            ])
        case .playPlaylist(let name):
            backendResult = await callBackendSpotify(path: "/spotify/play-playlist", query: [
                URLQueryItem(name: "name", value: name)
            ])
        }

        switch backendResult {
        case .success(let status, let message):
            return ActionResult(
                action: .mediaControl(action),
                success: true,
                message: "Spotify backend success (\(status)): \(message)"
            )
        case .failure(let status, let message):
            let prefix = status.map { "Spotify backend failed (\($0))" } ?? "Spotify backend failed"
            return ActionResult(
                action: .mediaControl(action),
                success: false,
                message: "\(prefix): \(message)"
            )
        }
    }

    private func callBackendSpotify(
        path: String,
        query: [URLQueryItem] = []
    ) async -> SpotifyBackendResult {
        let baseURL = backendBaseURL()
        guard var components = URLComponents(string: baseURL) else {
            return .failure(status: nil, message: "Invalid backend URL: \(baseURL)")
        }

        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        components.path = normalizedPath
        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else {
            return .failure(status: nil, message: "Failed to build backend URL for \(path)")
        }

        emitSpotify("[Spotify][Backend] Request: POST \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let raw = String(data: data, encoding: .utf8) ?? ""
            emitSpotify("[Spotify][Backend] Response status: \(status)")
            emitSpotify("[Spotify][Backend] Response body: \(raw)")

            let decoded = try? JSONDecoder().decode(SpotifyBackendEnvelope.self, from: data)
            let actionConfirmed = decoded?.actionConfirmed == true
            let isPlaying = decoded?.playbackState?.isPlaying == true
            let explicitOK = decoded?.status?.lowercased() == "ok"
            let successConfirmed = explicitOK && (actionConfirmed || isPlaying)

            if (200..<300).contains(status), successConfirmed {
                let backendMessage = decoded?.message ?? (raw.isEmpty ? "ok" : raw)
                return .success(status: status, message: backendMessage)
            }

            let interpretedReason: String = {
                if status == 403 { return "403 restriction/premium/device limitation" }
                if raw.lowercased().contains("no active spotify device") { return "no active device" }
                if (200..<300).contains(status) { return "action not confirmed by playback state" }
                if raw.isEmpty { return "unknown backend error" }
                return "backend returned error payload"
            }()

            emitSpotify("[Spotify][Backend] Interpreted reason: \(interpretedReason)")

            if (200..<300).contains(status) {
                return .failure(status: status, message: interpretedReason)
            }
            return .failure(status: status, message: raw.isEmpty ? "unknown error" : raw)
        } catch {
            emitSpotify("[Spotify][Backend][ERROR] Request failed: \(error.localizedDescription)")
            return .failure(status: nil, message: error.localizedDescription)
        }
    }

    private func backendBaseURL() -> String {
        let configured = envValue("JARVIS_BACKEND_URL")
            ?? envValue("BACKEND_BASE_URL")
            ?? "http://127.0.0.1:8000"
        return configured.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func envValue(_ key: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return value
        }
        let dotEnv = parseDotEnv()
        if let value = dotEnv[key], !value.isEmpty {
            return value
        }
        return nil
    }

    private func parseDotEnv() -> [String: String] {
        let candidates = dotEnvCandidates()

        for fileURL in candidates {
            guard let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8) else { continue }
            var values: [String: String] = [:]
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                values[parts[0]] = parts[1]
            }
            if !values.isEmpty { return values }
        }
        return [:]
    }

    private func dotEnvCandidates() -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []

        var seen = Set<String>()
        func appendUnique(_ url: URL) {
            let normalized = url.standardizedFileURL.path
            if seen.contains(normalized) { return }
            seen.insert(normalized)
            candidates.append(url)
        }

        var cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<10 {
            appendUnique(cwdURL.appendingPathComponent(".env"))
            let parent = cwdURL.deletingLastPathComponent()
            if parent.path == cwdURL.path { break }
            cwdURL = parent
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
        var sourceDir = sourceURL.deletingLastPathComponent()
        for _ in 0..<10 {
            appendUnique(sourceDir.appendingPathComponent(".env"))
            let parent = sourceDir.deletingLastPathComponent()
            if parent.path == sourceDir.path { break }
            sourceDir = parent
        }

        return candidates
    }

    private func emitSpotify(_ message: String) {
        onLog?(message)
        NSLog("%@", message)
    }
}
