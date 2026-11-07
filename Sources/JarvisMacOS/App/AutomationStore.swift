import Foundation

enum AutomationActionType: String, Codable, CaseIterable, Identifiable {
    case command = "command"
    case openWebsite = "open_website"
    case openWebsiteBrave = "open_website_brave"
    case openWebsiteChrome = "open_website_chrome"
    case newTab = "new_tab"
    case newWindow = "new_window"
    case workspaceCommand = "workspace_command"
    case openApp = "open_app"
    case closeApp = "close_app"
    case playSong = "play_song"
    case playPlaylist = "play_playlist"
    case playLiked = "play_liked"
    case pause = "pause"
    case next = "next"
    case previous = "previous"
    case timer = "timer"
    case stopwatch = "stopwatch"
    case openFile = "open_file"
    case openFolder = "open_folder"

    var id: String { rawValue }

    static var selectableCases: [Self] { allCases.filter { $0 != .timer && $0 != .stopwatch } }

    var displayName: String {
        switch self {
        case .command: return "Run command"
        case .openWebsite: return "Website · default browser"
        case .openWebsiteBrave: return "Website · Brave"
        case .openWebsiteChrome: return "Website · Chrome"
        case .newTab: return "New tab"
        case .newWindow: return "New window"
        case .workspaceCommand: return "Window / tab / project"
        case .openApp: return "Open App"
        case .closeApp: return "Close App"
        case .playSong: return "Play Song"
        case .playPlaylist: return "Play Playlist"
        case .playLiked: return "Play Liked Songs"
        case .pause: return "Pause"
        case .next: return "Next Track"
        case .previous: return "Previous Track"
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        case .openFile: return "Open File"
        case .openFolder: return "Open Folder"
        }
    }

    var placeholder: String {
        switch self {
        case .command: return "open my portfolio project in VS Code"
        case .openWebsite, .openWebsiteBrave, .openWebsiteChrome: return "https://chatgpt.com"
        case .newTab, .newWindow: return "Brave, Chrome, VS Code, Finder or Terminal"
        case .workspaceCommand: return "open my portfolio project in VS Code"
        case .openApp, .closeApp:
            return "Spotify"
        case .playSong:
            return "Blinding Lights"
        case .playPlaylist:
            return "Gym"
        case .playLiked, .pause, .next, .previous, .stopwatch:
            return ""
        case .timer:
            return "25m or 1500s"
        case .openFile:
            return "/Users/you/Desktop/todo.txt"
        case .openFolder:
            return "Downloads"
        }
    }

    var requiresValue: Bool {
        switch self {
        case .playLiked, .pause, .next, .previous, .stopwatch:
            return false
        default:
            return true
        }
    }

    var guidance: String {
        switch self {
        case .command: return "Use any command you would say to Jarvis: search files, set volume, open a project, or combine actions."
        case .workspaceCommand: return "For example: open my portfolio project in VS Code, Finder or Terminal. Project locations come from your configured roots."
        case .newTab, .newWindow: return "Enter the app where this tab or window should open."
        case .openWebsite, .openWebsiteBrave, .openWebsiteChrome: return "Enter the website address. The selected browser will be used when this step runs."
        case .playSong: return "Enter the song title, optionally with its artist. Playback uses your Spotify connection."
        case .openFile: return "Enter the full file path, including its extension. The file opens in its default app."
        default: return ""
        }
    }
}

struct AutomationAction: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: AutomationActionType
    var value: String

    var validationMessage: String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if type.requiresValue && text.isEmpty { return "Enter a value for \(type.displayName)." }
        switch type {
        case .openWebsite, .openWebsiteBrave, .openWebsiteChrome:
            guard websiteURL != nil else { return "Enter a valid http or https website address." }
        case .newTab, .newWindow:
            guard WorkspaceApp.parse(text) != nil else { return "Choose Brave, Chrome, VS Code, Finder or Terminal." }
        case .workspaceCommand:
            guard let plan = WorkspaceCommandParser.plan(text), plan.count == 1, case .workspace = plan[0] else {
                return "Enter one window, tab or project command, or use Run command for multiple actions."
            }
        case .openFile:
            guard text.hasPrefix("/") || text.hasPrefix("~/") else { return "Enter an absolute file path or a path beginning with ~/." }
        case .timer, .stopwatch: return "Timers and stopwatches are not available yet. Replace this action before saving."
        default: break
        }
        return nil
    }

    var websiteURL: String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.contains("://") ? text : "https://\(text)"
        guard !text.contains(where: \.isWhitespace), let url = URL(string: normalized),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        return url.absoluteString
    }

    init(id: UUID = UUID(), type: AutomationActionType, value: String = "") {
        self.id = id
        self.type = type
        self.value = value
    }
}

struct VoiceAutomation: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var keyword: String
    var offKeyword: String?
    var actions: [AutomationAction]

    init(id: UUID = UUID(), keyword: String, offKeyword: String? = nil, actions: [AutomationAction]) {
        self.id = id
        self.keyword = keyword
        self.offKeyword = offKeyword
        self.actions = actions
    }
}

final class AutomationStore {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let baseDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Jarvis", isDirectory: true)
        self.fileURL = baseDir.appendingPathComponent("automations.json", isDirectory: false)
    }

    func load() -> [VoiceAutomation] {
        // Migration cut-over: Rust owns the file I/O (same path/JSON contract).
        if JarvisFlags.useRustPipeline,
           let json = coreReadAutomationsJson(),
           let data = json.data(using: .utf8) {
            return (try? JSONDecoder().decode([VoiceAutomation].self, from: data)) ?? []
        }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([VoiceAutomation].self, from: data) else { return [] }
        return decoded
    }

    func save(_ automations: [VoiceAutomation]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(automations)

        // Migration cut-over: Rust validates + atomically writes the file.
        if JarvisFlags.useRustPipeline, let json = String(data: data, encoding: .utf8) {
            try coreWriteAutomationsJson(json: json)
            return
        }

        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
