import Foundation

/// Maps the learned intent model's JSON output (`dataset/` schema:
/// `{"name": "...", "args": {...}}`) onto `PlannedAction`.
///
/// Every mapping is strict: an unknown name or a wrong/missing arg type
/// returns nil, which makes `IntentModelRouter` treat the whole response
/// as a miss and fall back to the rule router.
enum IntentActionMapper {

    static func map(_ intents: [[String: Any]]) -> [PlannedAction]? {
        var actions: [PlannedAction] = []
        for intent in intents {
            guard let name = intent["name"] as? String else { return nil }
            let args = (intent["args"] as? [String: Any]) ?? [:]
            guard let action = mapSingle(name: name, args: args) else { return nil }
            actions.append(action)
        }
        return actions.isEmpty ? nil : actions
    }

    private static func mapSingle(name: String, args: [String: Any]) -> PlannedAction? {
        switch name {
        case "app.open":
            guard let v = stringArg(args, "name") else { return nil }
            return .openApp(v)
        case "app.close":
            guard let v = stringArg(args, "name") else { return nil }
            return .closeApp(v)
        case "url.open":
            guard let v = stringArg(args, "url") else { return nil }
            return .openURL(v)
        case "web.search":
            guard let engine = stringArg(args, "engine"), let query = stringArg(args, "query") else { return nil }
            return .searchWeb(engine: engine, query: query)

        case "display.brightness_set":
            guard let level = intArg(args, "level") else { return nil }
            return .displayControl(.setBrightness(level))
        case "display.brightness_up":
            guard let by = intArg(args, "by") else { return nil }
            return .displayControl(.increaseBrightness(by: by))
        case "display.brightness_down":
            guard let by = intArg(args, "by") else { return nil }
            return .displayControl(.decreaseBrightness(by: by))
        case "display.contrast_set":
            guard let level = intArg(args, "level") else { return nil }
            return .displayControl(.setContrast(level))
        case "display.contrast_up":
            guard let by = intArg(args, "by") else { return nil }
            return .displayControl(.increaseContrast(by: by))
        case "display.contrast_down":
            guard let by = intArg(args, "by") else { return nil }
            return .displayControl(.decreaseContrast(by: by))

        case "volume.set":
            guard let level = intArg(args, "level") else { return nil }
            return .volumeControl(.setLevel(level))
        case "volume.up":
            guard let by = intArg(args, "by") else { return nil }
            return .volumeControl(.increase(by: by))
        case "volume.down":
            guard let by = intArg(args, "by") else { return nil }
            return .volumeControl(.decrease(by: by))
        case "volume.mute":
            return .volumeControl(.mute)
        case "volume.unmute":
            return .volumeControl(.unmute)

        case "media.play":
            return .mediaControl(.play)
        case "media.pause":
            return .mediaControl(.pause)
        case "media.next":
            return .mediaControl(.nextTrack)
        case "media.previous":
            return .mediaControl(.previousTrack)
        case "media.play_song":
            guard let title = stringArg(args, "title") else { return nil }
            return .mediaControl(.playSong(title))
        case "media.play_playlist":
            guard let playlist = stringArg(args, "name") else { return nil }
            return .mediaControl(.playPlaylist(playlist))
        case "media.play_liked":
            return .mediaControl(.playLikedSongs)

        case "info.time":
            return .systemInfo(.currentTime)
        case "info.date":
            return .systemInfo(.currentDate)
        case "info.brightness":
            return .systemInfo(.displayBrightness)
        case "info.contrast":
            return .systemInfo(.displayContrast)
        case "info.volume":
            return .systemInfo(.systemVolume)
        case "info.battery":
            return .systemInfo(.batteryStatus)
        case "info.wifi":
            return .systemInfo(.wifiStatus)
        case "info.bluetooth":
            return .systemInfo(.bluetoothDevices)

        case "file.create":
            guard let v = stringArg(args, "name") else { return nil }
            return .createFile(v)
        case "folder.create":
            guard let v = stringArg(args, "name") else { return nil }
            return .createFolder(v)
        case "folder.open":
            guard let v = stringArg(args, "name") else { return nil }
            return .openFolder(v)
        case "file.open_latest":
            guard let folder = stringArg(args, "folder") else { return nil }
            return .openLatestFile(inFolder: folder)

        case "files.query":
            guard let opRaw = stringArg(args, "op"),
                  let op = FileQueryOp(rawValue: opRaw) else { return nil }
            let folder = stringArg(args, "folder") ?? "downloads"
            let ext = (args["ext"] as? String) ?? ""
            return .fileQuery(FileQuery(op: op, folder: folder, ext: ext))

        case "install.preview":
            guard let package = stringArg(args, "package") else { return nil }
            let source = stringArg(args, "source") ?? "homebrew"
            return .installPreview(package: package, source: source)

        case "ai.query":
            guard let text = stringArg(args, "text") else { return nil }
            return .aiQuery(text)

        default:
            return nil
        }
    }

    private static func stringArg(_ args: [String: Any], _ key: String) -> String? {
        guard let value = args[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func intArg(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? Double { return Int(value) }
        if let value = args[key] as? NSNumber { return value.intValue }
        if let value = args[key] as? String { return Int(value) }
        return nil
    }
}
