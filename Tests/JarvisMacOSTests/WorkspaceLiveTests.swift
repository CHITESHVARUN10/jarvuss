import AppKit
import XCTest
@testable import JarvisMacOS

/// Explicit opt-in. Creates only blank browser windows/tabs and a temporary folder.
final class WorkspaceLiveTests: XCTestCase {
    private func script(_ source: String, arguments: [String] = []) async throws -> ProcessOutput {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source, "--"] + arguments
        return try await process.runCapturingOutputAsync(timeout: 12)
    }
    func testBrowserWindowsAndTabsAgainstInstalledApps() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_RUN_WORKSPACE_TESTS"] == "1", "Live workspace actions are opt-in")
        for app in [WorkspaceApp.brave, .chrome] {
            let before = try await script("tell application id \"\(app.bundleID)\" to get id of windows")
            guard before.status == 0 else { throw XCTSkip("Browser Automation unavailable: \(before.stderr)") }
            let oldIDs = Set(before.stdout.components(separatedBy: ", ").filter { !$0.isEmpty })
            do {
                _ = try await NativeWorkspaceController().perform(.init(operation: .newWindow, app: app))
                _ = try await NativeWorkspaceController().perform(.init(operation: .newTab, app: app))
                let after = try await script("tell application id \"\(app.bundleID)\" to get id of windows")
                let newIDs = Set(after.stdout.components(separatedBy: ", ").filter { !$0.isEmpty }).subtracting(oldIDs)
                XCTAssertFalse(newIDs.isEmpty, app.label)
                for id in newIDs where Int(id) != nil { _ = try await script("tell application id \"\(app.bundleID)\" to close window id \(id)") }
            } catch {
                let after = try await script("tell application id \"\(app.bundleID)\" to get id of windows")
                for id in Set(after.stdout.components(separatedBy: ", ")).subtracting(oldIDs) where Int(id) != nil {
                    _ = try? await script("tell application id \"\(app.bundleID)\" to close window id \(id)")
                }
                throw error
            }
        }
    }
    func testCodeWindowAndProjectFolderWithNoExistingSession() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_RUN_WORKSPACE_TESTS"] == "1", "Live workspace actions are opt-in")
        let alreadyRunning = await MainActor.run { !NSRunningApplication.runningApplications(withBundleIdentifier: WorkspaceApp.vscode.bundleID).isEmpty }
        try XCTSkipIf(alreadyRunning, "Preserve the existing VS Code session")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis Code fixture \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var failure: Error?
        do {
            let controller = NativeWorkspaceController()
            let window = try await controller.perform(.init(operation: .newWindow, app: .vscode))
            XCTAssertTrue(window.contains("Opened a new"))
            let project = try await controller.perform(.init(operation: .openProject, app: .vscode, project: "fixture"), folder: folder)
            XCTAssertTrue(project.contains("Sent"))
        } catch { failure = error }
        // No existing Code process was present and no document edits were made.
        _ = try? await script("tell application id \"com.microsoft.VSCode\" to quit")
        if let failure { throw failure }
    }
    func testFinderOpensFixtureFolder() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["JARVIS_RUN_WORKSPACE_TESTS"] == "1", "Live workspace actions are opt-in")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Jarvis workspace \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var failure: Error?
        do { _ = try await NativeWorkspaceController().perform(.init(operation: .openProject, app: .finder, project: "fixture"), folder: folder) }
        catch { failure = error }
        let cleanup = #"""
        on run argv
            set destination to POSIX file (item 1 of argv) as alias
            tell application "Finder"
                set windowIDs to id of every Finder window
                repeat with candidateID in windowIDs
                    try
                        set currentWindow to Finder window id (contents of candidateID)
                        if (target of currentWindow as alias) is destination then close currentWindow
                    end try
                end repeat
            end tell
        end run
        """#
        _ = try await script(cleanup, arguments: [folder.path])
        if let failure { throw failure }
    }
}
