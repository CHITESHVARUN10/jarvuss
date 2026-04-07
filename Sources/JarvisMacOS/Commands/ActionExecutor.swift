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

    private let appController   = AppController()
    private let fileManager     = JarvisFileManager()
    private let ollamaClient    = OllamaClient(model: "qwen2.5-coder:1.5b-base")
    private let volumeController = VolumeController()

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
            // Safety check before each action
            switch SafetyGuard.validate(action: action) {
            case .blocked(let reason):
                let result = ActionResult(action: action, success: false,
                                          message: "⛔ Blocked — \(reason)")
                onStepComplete(result)
                continue   // skip this step, continue with rest

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

            // Small pause between steps so apps can launch fully
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

        case .openURL(let url):
            return openURL(url)

        case .searchWeb(let engine, let query):
            // The URL action handles actual navigation; this just logs the intent
            return ActionResult(action: action, success: true,
                                message: "Searching \(engine) for '\(query)'.")

        case .openFolder(let path):
            let msg = fileManager.openFolder(named: path)
            return ActionResult(action: action, success: !msg.contains("not found") &&
                                !msg.lowercased().contains("fail"),
                                message: msg)

        case .openLatestFile(let folder):
            return openLatestFile(inFolder: folder)

        case .mediaControl(let mediaAction):
            return executeMediaAction(mediaAction)

        case .volumeControl(let volumeAction):
            let msg = volumeController.execute(volumeAction)
            // An empty msg means success with no error text
            let displayMsg = msg.isEmpty ? volumeAction.responseText : msg
            return ActionResult(action: action, success: true, message: displayMsg)

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
            // Double-guarded — should never reach here (SafetyGuard intercepts first)
            return ActionResult(action: action, success: false,
                                message: "🔒 Install blocked: '\(pkg)'. Source: \(source).")
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

    // MARK: - Spotify / media control via AppleScript

    private func executeMediaAction(_ action: MediaAction) -> ActionResult {
        NSLog("[Media] Routing to Spotify: \(action.description)")
        let script: String
        switch action {
        case .play:
            script = """
            tell application "Spotify"
                activate
                play
            end tell
            """
        case .pause:
            script = """
            tell application "Spotify"
                if it is running then pause
            end tell
            """
        case .nextTrack:
            script = """
            tell application "Spotify"
                activate
                next track
            end tell
            """
        case .previousTrack:
            script = """
            tell application "Spotify"
                activate
                previous track
            end tell
            """
        case .playLikedSongs:
            // Open Spotify and navigate to Liked Songs collection
            // "spotify:user::collection" is the liked songs URI on desktop
            script = """
            tell application "Spotify"
                activate
                play track "spotify:user::collection"
            end tell
            """

        case .playPlaylist(let name):
            // Open Spotify and search via URI — never use browser
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
            script = """
            tell application "Spotify"
                activate
                play track "spotify:search:\(encoded)"
            end tell
            """
        }

        let result = runAppleScript(script)
        return ActionResult(
            action: .mediaControl(action),
            success: result.success,
            message: result.success
                ? "Spotify: \(action.description)"
                : "Spotify control failed: \(result.error ?? "unknown")"
        )
    }

    // MARK: - AppleScript runner

    private struct AppleScriptResult {
        let success: Bool
        let error: String?
    }

    private func runAppleScript(_ script: String) -> AppleScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let errPipe = Pipe()
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return AppleScriptResult(success: true, error: nil)
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg  = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return AppleScriptResult(success: false, error: errMsg)
        } catch {
            return AppleScriptResult(success: false, error: error.localizedDescription)
        }
    }
}
