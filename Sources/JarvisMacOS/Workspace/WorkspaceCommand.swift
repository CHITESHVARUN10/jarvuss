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
        switch text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "brave", "brave browser": return .brave
        case "chrome", "google chrome": return .chrome
        case "code", "vs code", "vscode", "visual studio code": return .vscode
        case "finder": return .finder
        case "terminal": return .terminal
        default: return nil
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

enum WorkspaceCommandParser {
    static func plan(_ raw: String) -> [PlannedAction]? {
        let text = clean(raw)
        let pattern = #"(?:,\s*|\s+(?:and then|then|and)\s+)(?=(?:open|create|make)\b)"#
        let parts = text.replacingOccurrences(of: pattern, with: "\u{001F}", options: [.regularExpression, .caseInsensitive]).components(separatedBy: "\u{001F}")
        var actions: [PlannedAction] = []
        var hasWorkspace = false
        for part in parts {
            if let command = parse(part) { actions.append(.workspace(command)); hasWorkspace = true }
            else if parts.count > 1, case .execute(let existing) = FastPathRouter.route(part), !existing.isEmpty,
                    !existing.contains(where: { if case .aiQuery = $0 { return true }; return false }) { actions += existing }
            else { return nil }
        }
        return hasWorkspace ? actions : nil
    }

    static func parse(_ raw: String) -> WorkspaceCommand? {
        let text = clean(raw)
        if let groups = capture(#"^(?:open|create|make) (?:a |an |one )?new (window|tab|editor tab|terminal tab)(?: (?:in|on|for|of) (.+))?$"#, text) {
            let kind = groups[0].lowercased()
            guard groups.count > 1, let app = WorkspaceApp.parse(groups[1]) else { return nil }
            let operation: WorkspaceCommand.Operation = kind == "window" ? .newWindow : kind == "terminal tab" ? .newTerminalTab : .newTab
            return WorkspaceCommand(operation: operation, app: app)
        }
        if let groups = capture(#"^(?:open|create|make) (?:a |an |one )?new (.+) (window|tab)$"#, text), let app = WorkspaceApp.parse(groups[0]) {
            return WorkspaceCommand(operation: groups[1].lowercased() == "window" ? .newWindow : .newTab, app: app)
        }
        guard var body = capture(#"^open (.+)$"#, text)?.first else { return nil }
        var app: WorkspaceApp = .finder
        var explicitApp = false
        if let groups = capture(#"^(.+) (?:in|on|with) (?:a new window (?:in|of) )?(.+)$"#, body), let target = WorkspaceApp.parse(groups[1]) {
            body = groups[0]; app = target; explicitApp = true
        }
        var root = ""
        if let groups = capture(#"^(.+) from (.+)$"#, body) { body = groups[0]; root = unquote(groups[1]) }
        let hasProject = body.range(of: #"\bprojects?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let followup = ["it", "that", "that project", "this project"].contains(body.lowercased())
        guard hasProject || followup || (explicitApp && [.finder, .vscode, .terminal].contains(app)) else { return nil }
        body = body.replacingOccurrences(of: #"^(?:my|the)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        body = body.replacingOccurrences(of: #"\s+project$|^project\s+|^project$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return WorkspaceCommand(operation: .openProject, app: app, project: followup ? "@recent" : unquote(body), root: root)
    }
    private static func clean(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^(?:hey\s+)?jarvis[,:]?\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^(?:(?:can|could) you\s+)?(?:please\s+)?"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[.!?]+$"#, with: "", options: .regularExpression)
    }
    private static func unquote(_ text: String) -> String { text.trimmingCharacters(in: CharacterSet(charactersIn: " \"'“”")) }
    private static func capture(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
