import Foundation

// MARK: - Planned Action enum

/// Every step that the ActionPlanner produces is one of these.
enum PlannedAction: Equatable, CustomStringConvertible {
    case openApp(String)
    case closeApp(String)
    case systemInfo(SystemInfoAction)
    case openURL(String)
    case searchWeb(engine: String, query: String)
    case openFolder(String)
    case openLatestFile(inFolder: String)
    case mediaControl(MediaAction)
    case volumeControl(VolumeAction)
    case createFile(String)
    case createFolder(String)
    case aiQuery(String)
    case installPreview(package: String, source: String)
    case displayControl(DisplayAction)
    case fileQuery(FileQuery)

    var description: String {
        switch self {
        case .openApp(let n):              return "Open '\(n)'"
        case .closeApp(let n):             return "Close '\(n)'"
        case .systemInfo(let i):           return "Info: \(i)"
        case .openURL(let u):              return "Open URL: \(u)"
        case .searchWeb(let e, let q):     return "Search \(e) for '\(q)'"
        case .openFolder(let p):           return "Open folder '\(p)'"
        case .openLatestFile(let f):       return "Open latest file in '\(f)'"
        case .mediaControl(let a):         return "Media: \(a)"
        case .volumeControl(let a):        return "Volume: \(a)"
        case .createFile(let n):           return "Create file '\(n)'"
        case .createFolder(let n):         return "Create folder '\(n)'"
        case .aiQuery(let q):              return "AI query: '\(q)'"
        case .installPreview(let p, _):    return "Install preview: '\(p)'"
        case .displayControl(let a):       return "Display: \(a)"
        case .fileQuery(let q):            return "Files: \(q)"
        }
    }
}

/// One file-exploration request: an operation over a spoken folder, with an
/// optional extension filter.
struct FileQuery: Equatable, CustomStringConvertible {
    let op: FileQueryOp
    let folder: String
    let ext: String

    init(op: FileQueryOp, folder: String, ext: String = "") {
        self.op = op
        self.folder = folder
        self.ext = ext
    }

    var description: String {
        let extPart = ext.isEmpty ? "" : " [\(ext)]"
        return "\(op.rawValue) in '\(folder)'\(extPart)"
    }
}

enum SystemInfoAction: Equatable, CustomStringConvertible {
    case currentTime
    case currentDate
    case currentDay
    case currentMonth
    case currentYear
    case wifiStatus
    case bluetoothDevices
    case batteryStatus
    case systemVolume
    case displayBrightness
    case displayContrast

    /// Tool-prompt `system_info.kind` → action; unknown kinds return nil and
    /// the step is dropped.
    init?(toolKind: String) {
        switch toolKind {
        case "time":       self = .currentTime
        case "date":       self = .currentDate
        case "day":        self = .currentDay
        case "month":      self = .currentMonth
        case "year":       self = .currentYear
        case "battery":    self = .batteryStatus
        case "wifi":       self = .wifiStatus
        case "bluetooth":  self = .bluetoothDevices
        case "volume":     self = .systemVolume
        case "brightness": self = .displayBrightness
        case "contrast":   self = .displayContrast
        default:           return nil
        }
    }

    var description: String {
        switch self {
        case .currentTime:         return "current time"
        case .currentDate:         return "current date"
        case .currentDay:          return "current day"
        case .currentMonth:        return "current month"
        case .currentYear:         return "current year"
        case .wifiStatus:          return "wifi status"
        case .bluetoothDevices:    return "bluetooth devices"
        case .batteryStatus:       return "battery status"
        case .systemVolume:        return "system volume"
        case .displayBrightness:   return "display brightness level"
        case .displayContrast:     return "display contrast level"
        }
    }
}

enum MediaAction: Equatable, CustomStringConvertible {
    case play
    case playSong(String)
    case pause
    case nextTrack
    case previousTrack
    case playLikedSongs
    case playPlaylist(String)

    /// Tool-prompt media spec
    /// ("play|pause|next|prev|liked_songs|play_song:X|play_playlist:X").
    init?(spec: String) {
        switch spec {
        case "play":        self = .play
        case "pause":       self = .pause
        case "next":        self = .nextTrack
        case "prev":        self = .previousTrack
        case "liked_songs": self = .playLikedSongs
        default:
            if spec.hasPrefix("play_song:") {
                self = .playSong(String(spec.dropFirst("play_song:".count)))
            } else if spec.hasPrefix("play_playlist:") {
                self = .playPlaylist(String(spec.dropFirst("play_playlist:".count)))
            } else {
                return nil
            }
        }
    }

    var description: String {
        switch self {
        case .play:                  return "play"
        case .playSong(let n):       return "play song '\(n)'"
        case .pause:                 return "pause"
        case .nextTrack:             return "next track"
        case .previousTrack:         return "previous track"
        case .playLikedSongs:        return "play liked songs"
        case .playPlaylist(let n):   return "play playlist '\(n)'"
        }
    }
}

enum VolumeAction: Equatable, CustomStringConvertible {
    case increase(by: Int)    // percentage points
    case decrease(by: Int)
    case mute
    case unmute
    case setLevel(Int)        // absolute 0-100

    var description: String {
        switch self {
        case .increase(let n):  return "increase by \(n)%"
        case .decrease(let n):  return "decrease by \(n)%"
        case .mute:             return "mute"
        case .unmute:           return "unmute"
        case .setLevel(let n):  return "set to \(n)%"
        }
    }

    /// Human-readable response sentence for ResponseEngine.
    var responseText: String {
        switch self {
        case .increase(let n):  return "Volume increased by \(n) percent"
        case .decrease(let n):  return "Volume decreased by \(n) percent"
        case .mute:             return "Sound muted"
        case .unmute:           return "Sound unmuted"
        case .setLevel(let n):  return "Volume set to \(n) percent"
        }
    }
}

