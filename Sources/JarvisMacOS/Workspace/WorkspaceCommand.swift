import Foundation

enum WorkspaceApp: String, Codable, CaseIterable {
    case brave, chrome, vscode, finder, terminal
    var bundleID: String {
        switch self {
        case .brave: return "com.brave.Browser"
        case .chrome: return "com.google.Chrome"
        case .vscode: return "com.microsoft.VSCode"
        case .finder: return "com.apple.finder"
        case .terminal: return "com.apple.Terminal"
        }
    }
    var label: String {
        switch self {
        case .brave: return "Brave Browser"
        case .chrome: return "Google Chrome"
        case .vscode: return "Visual Studio Code"
        case .finder: return "Finder"
        case .terminal: return "Terminal"
        }
    }
    static func parse(_ text: String) -> Self? {
        coreParseWorkspaceApp(text: text).map(Self.init)
    }

    init(_ value: CoreWorkspaceApp) {
        switch value {
        case .brave: self = .brave
        case .chrome: self = .chrome
        case .vscode: self = .vscode
        case .finder: self = .finder
        case .terminal: self = .terminal
        }
    }
}

struct WorkspaceCommand: Equatable, Codable, CustomStringConvertible {
    enum Operation: String, Codable { case newWindow, newTab, newTerminalTab, openProject }
    var operation: Operation
    var app: WorkspaceApp
    var project: String = ""
    var root: String = ""
    var description: String {
        "\(operation.rawValue) in \(app.rawValue)" + (project.isEmpty ? "" : " project '\(project)'") + (root.isEmpty ? "" : " from '\(root)'")
    }
    var intent: String {
        switch operation {
        case .newWindow: return "app.new_window"
        case .newTab, .newTerminalTab: return "app.new_tab"
        case .openProject: return "project.open"
        }
    }
}

/// Rust interprets the command; Swift composes existing non-workspace routes.
enum WorkspaceCommandParser {
    static func plan(_ raw: String) -> [PlannedAction]? {
        let parts = coreWorkspaceParts(raw: raw)
        var actions: [PlannedAction] = []
        var hasWorkspace = false
        for part in parts {
            if let request = part.request {
                actions.append(.workspace(adapt(request))); hasWorkspace = true
            } else if parts.count > 1, case .execute(let existing) = FastPathRouter.route(part.text), !existing.isEmpty,
                      !existing.contains(where: { if case .aiQuery = $0 { return true }; return false }) {
                actions += existing
            } else { return nil }
        }
        return hasWorkspace ? actions : nil
    }
    static func parse(_ raw: String) -> WorkspaceCommand? {
        coreParseWorkspace(raw: raw).map(adapt)
    }
    private static func adapt(_ value: CoreWorkspaceRequest) -> WorkspaceCommand {
        let operation: WorkspaceCommand.Operation
        switch value.operation {
        case .newWindow: operation = .newWindow
        case .newTab: operation = .newTab
        case .newTerminalTab: operation = .newTerminalTab
        case .openProject: operation = .openProject
        }
        return WorkspaceCommand(operation: operation, app: WorkspaceApp(value.app), project: value.project, root: value.root)
    }
}
