import Foundation

enum AutomationActionType: String, Codable, CaseIterable, Identifiable {
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

    var displayName: String {
        switch self {
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
}

struct AutomationAction: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var type: AutomationActionType
    var value: String

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
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let decoded = try? JSONDecoder().decode([VoiceAutomation].self, from: data) else { return [] }
        return decoded
    }

    func save(_ automations: [VoiceAutomation]) throws {
        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(automations)
        try data.write(to: fileURL, options: .atomic)
    }
}
