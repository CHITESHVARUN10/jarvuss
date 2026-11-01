import AppKit
import CoreGraphics

struct NativeWorkspaceController {
    var locate: @MainActor (WorkspaceApp) throws -> URL = { try applicationURL($0) }
    var windowCount: () async -> Int = { await codeWindowCount() }
    var run: (URL, [String]) async throws -> ProcessOutput = { executable, arguments in
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        return try await process.runCapturingOutputAsync(timeout: 12)
    }
    @MainActor static func applicationURL(_ app: WorkspaceApp) throws -> URL {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            throw ProjectResolutionError.message("Install \(app.label) to use this command.")
        }
        return url
    }
    func perform(_ command: WorkspaceCommand, folder: URL? = nil) async throws -> String {
        try Task.checkCancellation()
        let appURL = try await locate(command.app)
        if command.operation == .openProject {
            guard let folder, [.finder, .vscode, .terminal].contains(command.app) else {
                throw ProjectResolutionError.message("Projects can open in Finder, Visual Studio Code, or Terminal.")
            }
            if command.app == .vscode {
                try await code(appURL, arguments: ["--new-window", folder.path])
                return "Sent ‘\(folder.lastPathComponent)’ to Visual Studio Code."
            }
            if command.app == .terminal {
                let report = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-workspace-\(UUID()).pwd")
                FileManager.default.createFile(atPath: report.path, contents: Data(), attributes: [.posixPermissions: 0o600])
                defer { try? FileManager.default.removeItem(at: report) }
                try await appleScript(Self.terminalScript, arguments: [folder.path, report.path])
                var confirmed = false
                for _ in 0..<50 {
                    try Task.checkCancellation()
                    if let data = try? Data(contentsOf: report), !data.isEmpty {
                        let actual = String(decoding: data, as: UTF8.self)
                        let path = actual.hasSuffix("\n") ? String(actual.dropLast()) : actual
                        guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path else {
                            throw ProjectResolutionError.message("Terminal opened, but its working directory did not match the project.")
                        }
                        confirmed = true; break
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard confirmed else { throw ProjectResolutionError.message("Terminal opened, but the project directory could not be confirmed.") }
            } else {
                try await appleScript(Self.finderScript, arguments: [folder.path])
            }
            return "Opened ‘\(folder.lastPathComponent)’ in \(command.app.label)."
        }
        if [.brave, .chrome].contains(command.app) {
            guard command.operation != .newTerminalTab else { throw ProjectResolutionError.message("An integrated terminal tab is a Visual Studio Code action.") }
            try await appleScript(Self.browserScript(app: command.app, tab: command.operation == .newTab))
        } else if command.app == .vscode {
            if command.operation == .newWindow {
                let before = await windowCount()
                try await code(appURL, arguments: ["--new-window"])
                for _ in 0..<60 {
                    try Task.checkCancellation()
                    if await windowCount() > before { return "Opened a new Visual Studio Code window." }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw ProjectResolutionError.message("VS Code accepted the request, but a new window could not be confirmed.")
            }
            if await windowCount() == 0 {
                try await code(appURL, arguments: ["--new-window"])
                for _ in 0..<60 {
                    if await windowCount() > 0 { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            try await appleScript(Self.codeTabScript, arguments: [command.operation == .newTerminalTab ? "terminal" : "editor"])
        } else {
            throw ProjectResolutionError.message("New window/tab commands currently support Brave, Chrome, and Visual Studio Code.")
        }
        if command.operation == .newTerminalTab { return "Requested a new integrated terminal in Visual Studio Code." }
        return "Opened a new \(command.operation == .newWindow ? "window" : command.operation == .newTerminalTab ? "terminal tab" : "tab") in \(command.app.label)."
    }
    private func code(_ appURL: URL, arguments: [String]) async throws {
        let executable = appURL.appendingPathComponent("Contents/Resources/app/bin/code")
        let output = try await run(executable, arguments)
        guard output.status == 0 else { throw ProjectResolutionError.message("VS Code could not open the requested window or folder: \(output.stderr)") }
    }
    private func appleScript(_ script: String, arguments: [String] = []) async throws {
        let output = try await run(URL(fileURLWithPath: "/usr/bin/osascript"), ["-e", script, "--"] + arguments)
        guard output.status == 0, output.stdout == "confirmed" else {
            if output.stderr.contains("-1743") { throw ProjectResolutionError.message("Allow Jarvis to control \(output.stderr.contains("System Events") ? "System Events" : "the requested app") in Privacy & Security → Automation.") }
            if output.stderr.contains("1002") || output.stderr.lowercased().contains("assistive") || output.stderr.contains("-1719") {
                throw ProjectResolutionError.message("Enable Jarvis in Privacy & Security → Accessibility to create VS Code tabs.")
            }
            throw ProjectResolutionError.message(output.stderr.isEmpty ? "The requested app did not confirm the action." : output.stderr)
        }
    }
    @MainActor private static func codeWindowCount() -> Int {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: WorkspaceApp.vscode.bundleID).map { $0.processIdentifier })
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { pids.contains(($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1) && ($0[kCGWindowLayer as String] as? Int) == 0 }.count
    }
    static func browserScript(app: WorkspaceApp, tab: Bool) -> String {
        // The identifier and action come exclusively from the allowlisted enum.
        """
        tell application id "\(app.bundleID)"
            set wasRunning to running
            launch
            if \(tab ? "true" : "false") then
                if (count windows) is 0 then make new window
                set targetWindow to front window
                set beforeCount to count tabs of targetWindow
                set createdTab to make new tab at end of tabs of targetWindow with properties {URL:"about:blank"}
                set active tab index of targetWindow to count tabs of targetWindow
                if (count tabs of targetWindow) ≤ beforeCount then error "The new tab was not confirmed."
            else
                set beforeCount to count windows
                if wasRunning or beforeCount is 0 then make new window
                if wasRunning and (count windows) ≤ beforeCount then error "The new window was not confirmed."
            end if
            activate
            return "confirmed"
        end tell
        """
    }
    static let finderScript = #"""
    on run argv
        set targetFolder to POSIX file (item 1 of argv) as alias
        tell application "Finder"
            set createdWindow to make new Finder window to targetFolder
            activate
            if (target of createdWindow as alias) is targetFolder then return "confirmed"
            error "Finder did not confirm the requested folder."
        end tell
    end run
    """#
    static let terminalScript = #"""
    on run argv
        set folderPath to item 1 of argv
        tell application "Terminal"
            set reportPath to item 2 of argv
            set createdTab to do script ("cd -- " & quoted form of folderPath & " && /bin/pwd > " & quoted form of reportPath)
            activate
            if (tty of createdTab) is "" then error "Terminal did not create a session."
            return "confirmed"
        end tell
    end run
    """#
    static let codeTabScript = #"""
    on run argv
        tell application id "com.microsoft.VSCode" to activate
        tell application "System Events"
            tell process "Code"
                if (count windows) is 0 then error "Open a VS Code window first."
                if item 1 of argv is "terminal" then
                    click menu item "New Terminal" of menu "Terminal" of menu bar item "Terminal" of menu bar 1
                else
                    click menu item "New Text File" of menu "File" of menu bar item "File" of menu bar 1
                    repeat 30 times
                        if name of front window contains "Untitled" then return "confirmed"
                        delay 0.1
                    end repeat
                    error "VS Code did not confirm an untitled editor."
                end if
            end tell
        end tell
        return "confirmed"
    end run
    """#
}
