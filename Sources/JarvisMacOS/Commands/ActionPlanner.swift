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
        }
    }
}

enum SystemInfoAction: Equatable, CustomStringConvertible {
    case currentTime
    case currentDate
    case wifiStatus
    case bluetoothDevices
    case batteryStatus
    case systemVolume

    var description: String {
        switch self {
        case .currentTime:         return "current time"
        case .currentDate:         return "current date"
        case .wifiStatus:          return "wifi status"
        case .bluetoothDevices:    return "bluetooth devices"
        case .batteryStatus:       return "battery status"
        case .systemVolume:        return "system volume"
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

// MARK: - ActionPlanner

/// Rule-based intent parser.  Ollama is called ONLY when the input
/// cannot be parsed by any rule and is also not a known single command.
final class ActionPlanner {

    private let ollamaClient = OllamaClient(model: "qwen2.5-coder:1.5b-base")

    // ── Public entry point ──────────────────────────────────────────

    func plan(from raw: String) async -> [PlannedAction] {
        // 1. Strip wake word and trailing noise before anything else
        let cleaned = stripWakeWord(stripTrailingNoise(raw))
        let lower   = cleaned.lowercased()

        NSLog("[Plan] Input cleaned: '%@'", cleaned)

        // 2. Safety pre-check on the full input
        switch SafetyGuard.validate(rawCommand: cleaned) {
        case .blocked(let reason):
            return [.aiQuery("blocked: \(reason)")]
        case .installPreview(let cmd, let src):
            return [.installPreview(package: cmd, source: src)]
        case .allowed:
            break
        }

        // 3. Strict priority router
        // SYSTEM -> INFO -> MEDIA -> AI
        if let actions = ruleBasedPlan(cleaned: cleaned, lower: lower) {
            NSLog("[Plan] Rule-based: %@", actions.map(\.description).joined(separator: ", "))
            return actions
        }

        // 5. Fallback to Ollama only for complex/unrecognised input
        // Guard: only route to Ollama when input is substantial (≥ 4 tokens)
        // and doesn't look like a media/volume/search command that we missed.
        // ── Fix #9: Block system-like commands from reaching Ollama ───────────────
        // If the unmatched input contains a system keyword it was a misfire,
        // not a genuine AI question. DROP it — do not send to AI.
        let systemIntentKeywords = [
            "open", "close", "launch", "start", "run",
            "volume", "mute", "unmute", "play", "pause", "next", "previous", "skip",
            "search", "create"
        ]
        if systemIntentKeywords.contains(where: { lower.split(separator: " ").map(String.init).contains($0) }) {
            NSLog("[Block] system-intent keyword detected — dropping instead of routing to AI: '%@'", cleaned)
            return []
        }

        let tokenCount = lower.split(separator: " ").count
        if tokenCount < 4 {
            NSLog("[Plan] Short unrecognised input (%d tokens) — treating as AI query without Ollama call", tokenCount)
            return [.aiQuery(cleaned)]
        }

        NSLog("[Intent] AI: fallback")
        NSLog("[Plan] → Routing to Ollama: '%@'", cleaned)
        return await ollamaFallback(cleaned)
    }

    // MARK: - Rule-based planner

    private func ruleBasedPlan(cleaned: String, lower: String) -> [PlannedAction]? {

        if let system = parseSystemCommand(lower) {
            NSLog("[Intent] SYSTEM: %@", lower)
            return [system]
        }

        if let info = parseInfoCommand(lower) {
            NSLog("[Intent] INFO: %@", info.description)
            return [.systemInfo(info)]
        }

        // Volume remains before media and after system/info.
        if let volume = parseVolumeCommand(lower) {
            NSLog("[Block] prevented AI fallback → volume command")
            return [volume]
        }

        // Media is lower priority than system + info.
        if let media = parseMediaCommand(lower) {
            NSLog("[Intent] MEDIA: %@", media.description)
            return [media]
        }

        // ── Search commands (BEFORE app-open to avoid misrouting) ────
        if let searchActions = parseSearchQuery(lower) {
            return searchActions
        }

        // ── "open X and play Y" / conjunction splits ─────────────────
        let conjuncts = splitByConjunction(lower)
        if conjuncts.count > 1 {
            var actions: [PlannedAction] = []
            for part in conjuncts {
                let partTrimmed = part.trimmingCharacters(in: .whitespaces)
                // Try volume first on each part
                if let vol = parseVolumeCommand(partTrimmed) {
                    actions.append(vol)
                    continue
                }
                if let info = parseInfoCommand(partTrimmed) {
                    actions.append(.systemInfo(info))
                    continue
                }
                // Try media on each part
                if let media = parseMediaCommand(partTrimmed) {
                    actions.append(media)
                    continue
                }
                // Close on each part
                if partTrimmed.hasPrefix("close ") {
                    let t = String(partTrimmed.dropFirst("close ".count))
                    actions.append(.closeApp(resolveApp(t)))
                    continue
                }
                let subActions = parseSinglePhrase(partTrimmed, originalRaw: cleaned)
                actions.append(contentsOf: subActions)
            }
            if let controlOnly = preferredSingleControlAction(from: actions) {
                NSLog("[Plan] Collapsing conjunction to single control action: %@", controlOnly.description)
                return [controlOnly]
            }
            if !actions.isEmpty {
                NSLog("[Voice] split into %d commands via conjunction", actions.count)
            }
            return actions.isEmpty ? nil : actions
        }

        // ── Single-phrase parse ─────────────────────────────────────
        let single = parseSinglePhrase(lower, originalRaw: cleaned)
        return single.isEmpty ? nil : single
    }

    private func splitCompoundMediaCommand(_ lower: String) -> [PlannedAction]? {
        _ = lower
        // Disabled intentionally: control commands must execute as a single action.
        return nil
    }

    // MARK: - Single-phrase parser

    private func parseSinglePhrase(_ lower: String, originalRaw: String) -> [PlannedAction] {

        // ── Browser URL shortcuts (always use system default browser) ──
        if lower.hasPrefix("open youtube") || lower == "youtube" {
            return [.openURL("https://www.youtube.com")]
        }
        if lower.hasPrefix("open google") && !lower.contains("search") {
            return [.openURL("https://www.google.com")]
        }
        if lower.hasPrefix("open netflix") || lower == "netflix" {
            return [.openURL("https://www.netflix.com")]
        }
        if lower.hasPrefix("open github") && !lower.contains("desktop") {
            return [.openURL("https://github.com")]
        }
        if lower.hasPrefix("open spotify") || lower == "spotify" {
            // Spotify is a native app — open the app directly
            return [.openApp("Spotify")]
        }
        if lower.hasPrefix("open whatsapp") || lower == "whatsapp" {
            return [.openApp("WhatsApp")]
        }

        // ── "open X in chrome/brave/firefox/safari" ─────────────────
        // Only when the user EXPLICITLY names a browser
        if let (site, browser) = parseOpenInBrowser(lower) {
            return [.openApp(resolveApp(browser)), .openURL(site)]
        }

        // ── Open folder + latest file ───────────────────────────────
        if lower.contains("open latest file") || lower.contains("open newest file") {
            let folder = extractFolderName(from: lower) ?? "Downloads"
            return [.openFolder(folder), .openLatestFile(inFolder: folder)]
        }

        // ── Open folder ─────────────────────────────────────────────
        if lower.hasPrefix("open folder ") {
            let folder = String(lower.dropFirst("open folder ".count))
            return [.openFolder(folder)]
        }
        // "open downloads", "open documents", "open desktop" without "folder" keyword
        let knownFolders = ["downloads", "documents", "desktop", "pictures", "movies", "music"]
        for kf in knownFolders {
            if lower == "open \(kf)" || lower == kf {
                return [.openFolder(kf)]
            }
        }

        // ── App open/close ──────────────────────────────────────────
        for prefix in ["launch ", "start ", "run ", "open "] {
            if lower.hasPrefix(prefix) {
                let target = String(lower.dropFirst(prefix.count))
                let resolved = resolveApp(target)
                NSLog("[Intent] detected: open_app(%@)", resolved)
                NSLog("[Block] prevented AI fallback → open_app")
                return [.openApp(resolved)]
            }
        }
        // close is already handled at ruleBasedPlan level, but kept as safety
        if lower.hasPrefix("close ") {
            let target = String(lower.dropFirst("close ".count))
            let resolved = resolveApp(target)
            NSLog("[Intent] detected: close_app(%@)", resolved)
            NSLog("[Block] prevented AI fallback → close_app")
            return [.closeApp(resolved)]
        }

        // ── Create file / folder ──────────────────────────────────────────────
        if lower.hasPrefix("create file ") {
            let name = String(lower.dropFirst("create file ".count))
            NSLog("[Intent] detected: create_file(%@)", name)
            return [.createFile(name)]
        }
        if lower.hasPrefix("create folder ") {
            let name = String(lower.dropFirst("create folder ".count))
            NSLog("[Intent] detected: create_folder(%@)", name)
            return [.createFolder(name)]
        }

        // ── AI query fallback — ONLY for genuine questions ────────────────────
        // Fix #9: NEVER send system-like or app-name commands to AI.
        // All system verb prefixes are blocked here as a last-resort guard.
        let systemBlockPrefixes = [
            "volume", "mute", "unmute", "play", "pause", "next", "previous", "skip",
            "open folder", "open downloads", "open documents", "open desktop",
            "open ", "close ", "launch ", "start ", "run ", "search ", "create "
        ]
        if systemBlockPrefixes.contains(where: { lower.hasPrefix($0) }) {
            NSLog("[Block] prevented AI fallback → system command: '%@'", lower)
            return []
        }

        // Fix #4: Reject noun-only or vague inputs (e.g. "chrome and whatsapp" after
        // conjunction filtering drops verbs). If " and " / " then " present with no
        // AI question prefix → DROP. Do not send to AI.
        let hasConjunction = lower.contains(" and ") || lower.contains(" then ")
        let hasAIPrefix = lower.hasPrefix("explain ") || lower.hasPrefix("what is ")
            || lower.hasPrefix("who is ") || lower.hasPrefix("why ") || lower.hasPrefix("how ")
            || lower.hasPrefix("tell me ") || lower.hasPrefix("describe ")
        if hasConjunction && !hasAIPrefix {
            NSLog("[Block] noun-only conjunction command dropped: '%@'", lower)
            return []
        }

        if hasAIPrefix {
            NSLog("[Plan] → Routing to Ollama (AI prefix): '%@'", originalRaw)
            return [.aiQuery(originalRaw)]
        }

        // Any remaining unmatched command → AI query
        NSLog("[Plan] → Routing to Ollama (no rule match): '%@'", originalRaw)
        return [.aiQuery(originalRaw)]
    }

    // MARK: - Media command parser

    private func parseSystemCommand(_ lower: String) -> PlannedAction? {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let app = singleAppShortcut(for: trimmed) {
            return .openApp(resolveApp(app))
        }

        if trimmed.hasPrefix("open ") {
            let target = String(trimmed.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                return .openApp(resolveApp(target))
            }
        }

        if trimmed.hasPrefix("launch ") {
            let target = String(trimmed.dropFirst("launch ".count)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                return .openApp(resolveApp(target))
            }
        }

        if trimmed.hasPrefix("close ") {
            let target = String(trimmed.dropFirst("close ".count)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                return .closeApp(resolveApp(target))
            }
        }

        if trimmed.hasPrefix("quit ") {
            let target = String(trimmed.dropFirst("quit ".count)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                return .closeApp(resolveApp(target))
            }
        }

        return nil
    }

    private func parseInfoCommand(_ lower: String) -> SystemInfoAction? {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "what time is it" || trimmed == "current time" || trimmed == "time now" {
            return .currentTime
        }

        if trimmed == "what is today's date" || trimmed == "what is todays date" || trimmed == "today's date" || trimmed == "todays date" || trimmed == "current date" {
            return .currentDate
        }

        if trimmed.contains("wifi") {
            return .wifiStatus
        }

        if trimmed.contains("bluetooth") {
            return .bluetoothDevices
        }

        if trimmed.contains("battery") {
            return .batteryStatus
        }

        if trimmed == "system volume" || trimmed == "current volume" || trimmed == "volume level" {
            return .systemVolume
        }

        return nil
    }

    private func singleAppShortcut(for lower: String) -> String? {
        let appNames: Set<String> = ["chrome", "spotify", "whatsapp"]
        return appNames.contains(lower) ? lower : nil
    }

    /// Returns a PlannedAction for any media-related utterance, or nil if not media.
    /// Must be called BEFORE parseSinglePhrase to prevent "play song" → openApp.
    private func parseMediaCommand(_ lower: String) -> PlannedAction? {
        let compact = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }

        if containsAnyWord(compact, words: ["open", "close", "launch", "quit"]) {
            return nil
        }

        let explicitMediaIntent = containsAnyWord(
            compact,
            words: ["play", "song", "songs", "music", "track", "liked", "playlist", "next", "previous", "prev", "pause", "resume", "skip", "back"]
        )
        guard explicitMediaIntent else { return nil }

        if containsAnyWord(compact, words: ["next", "skip"]) {
            NSLog("[Intent] detected: next_track")
            return .mediaControl(.nextTrack)
        }
        if containsAnyWord(compact, words: ["previous", "prev", "back"]) {
            NSLog("[Intent] detected: previous_track")
            return .mediaControl(.previousTrack)
        }
        if containsAnyWord(compact, words: ["pause", "stop"]) {
            NSLog("[Intent] detected: pause")
            return .mediaControl(.pause)
        }

        let normalizedIntent = normalizeMediaIntentText(compact)
        let normalizedTokens = normalizedIntent
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        let normalizedJoined = normalizedTokens.joined(separator: " ")

        if containsAnyWord(normalizedJoined, words: ["next", "skip"]) {
            NSLog("[Intent] detected: next_track")
            return .mediaControl(.nextTrack)
        }
        if containsAnyWord(normalizedJoined, words: ["previous", "prev", "back"]) {
            NSLog("[Intent] detected: previous_track")
            return .mediaControl(.previousTrack)
        }

        if containsAnyWord(normalizedJoined, words: ["liked", "favorites", "favourites", "saved"]) || isLikedSongsQuery(compact) {
            NSLog("[Intent] detected: liked_songs")
            return .mediaControl(.playLikedSongs)
        }

        if normalizedJoined.isEmpty || normalizedJoined == "resume" || normalizedJoined == "playback" {
            NSLog("[Intent] detected: play")
            return .mediaControl(.play)
        }

        let webKeywords = ["youtube", "netflix", "on youtube", "spotify web"]
        if webKeywords.contains(where: { compact.contains($0) }) {
            return nil
        }

        if isPlaylistQuery(compact) || containsAnyWord(compact, words: ["playlist"]) {
            let playlistName = extractPlaylistName(normalizedIntent)
            NSLog("[Intent] detected: play_playlist → '%@'", playlistName)
            return .mediaControl(.playPlaylist(playlistName))
        }

        let songName = extractSongName(normalizedIntent)
        NSLog("[Intent] detected: play_song → '%@'", songName)
        return .mediaControl(.playSong(songName))
    }

    private func normalizeMediaIntentText(_ text: String) -> String {
        let removable: Set<String> = ["play", "music", "song", "songs", "track", "tracks", "from"]
        let tokens = text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)

        let cleaned = tokens.filter { token in
            let normalized = token
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            return !removable.contains(normalized)
        }

        return cleaned.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAnyWord(_ text: String, words: [String]) -> Bool {
        let tokenSet = Set(
            text.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
                .filter { !$0.isEmpty }
        )
        return words.contains(where: { tokenSet.contains($0) })
    }

    private func preferredSingleControlAction(from actions: [PlannedAction]) -> PlannedAction? {
        let controlOrder: [MediaAction] = [.nextTrack, .previousTrack, .pause, .play]
        let mediaActions = actions.compactMap { action -> MediaAction? in
            if case .mediaControl(let media) = action { return media }
            return nil
        }

        for control in controlOrder where mediaActions.contains(control) {
            return .mediaControl(control)
        }
        return nil
    }

    func commandCheatSheet() -> String {
        """
        SYSTEM:
        - open chrome
        - open spotify
        - close spotify
        - open whatsapp
        - chrome / spotify / whatsapp

        MEDIA:
        - play song <name>
        - play liked songs
        - play <playlist>
        - next track
        - previous track

        INFO:
        - what time is it
        - what is today's date
        - which wifi am I connected to
        - which bluetooth devices are connected
        - battery status
        - system volume

        GENERAL:
        - ask anything (AI fallback)
        """
    }

    /// Extracts a meaningful playlist name from speech.
    /// Strips filler like "from", "songs", "playlist" before returning.
    /// Examples:
    ///   "songs from gym playlist" → "gym"
    ///   "music from chill vibes"  → "chill vibes"
    ///   "workout songs"           → "workout"
    private func extractPlaylistName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let fillerWords: Set<String> = ["play", "from", "playlist", "my", "the", "some"]
        let playlistSuffixes: Set<String> = ["songs", "tracks", "music", "station", "mix"]

        let tokens = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)

        var cleaned: [String] = []
        for token in tokens {
            let normalized = token
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            guard !normalized.isEmpty else { continue }
            if fillerWords.contains(normalized) { continue }
            cleaned.append(token)
        }

        while let last = cleaned.last {
            let normalized = last
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            if playlistSuffixes.contains(normalized) {
                cleaned.removeLast()
            } else {
                break
            }
        }

        let leadingNoise: Set<String> = ["play", "music", "song", "songs", "track", "tracks", "some"]
        while cleaned.count > 1, let first = cleaned.first {
            let normalized = first
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            if leadingNoise.contains(normalized) {
                cleaned.removeFirst()
            } else {
                break
            }
        }

        let extracted = cleaned.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? trimmed : extracted
    }

    private func extractSongName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()

        let leadingFillers = ["play song ", "play track ", "play ", "song ", "track ", "the song ", "the track ", "music "]
        for filler in leadingFillers where lower.hasPrefix(filler) {
            name = String(name.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        let trailingFillers = [" song", " track", " music", " playlist"]
        for suffix in trailingFillers where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        return name.isEmpty ? raw : name
    }

    private func isPlaylistQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let playlistKeywords = ["playlist", "my playlist", "from playlist", "playlist called", "playlist named"]
        return playlistKeywords.contains(where: { lower.contains($0) })
    }

    private func isLikedSongsQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let likedKeywords = [
            "liked songs", "my liked songs", "liked", "my liked",
            "saved songs", "my saved songs", "favorites", "my favorites"
        ]
        return likedKeywords.contains(where: { lower == $0 || lower.hasPrefix("\($0) ") || lower.hasSuffix(" \($0)") })
    }

    // MARK: - Volume command parser

    /// Parses spoken volume commands into a VolumeAction.
    /// All variants of "sound"/"volume"/"audio" are handled here — NEVER goes to AI.
    private func parseVolumeCommand(_ lower: String) -> PlannedAction? {

        // ── Mute ─────────────────────────────────────────────────────
        let muteVariants = [
            "mute", "mute the sound", "mute audio", "mute sound",
            "sound off", "turn off sound", "silence", "go silent",
            "shut up", "be quiet",
        ]
        if muteVariants.contains(lower) {
            NSLog("[Intent] detected: mute")
            return .volumeControl(.mute)
        }

        // ── Unmute ───────────────────────────────────────────────────
        let unmuteVariants = [
            "unmute", "sound on", "turn on sound", "unmute the sound",
            "unmute audio", "unmute sound",
        ]
        if unmuteVariants.contains(lower) {
            NSLog("[Intent] detected: unmute")
            return .volumeControl(.unmute)
        }

        if lower.contains("set volume to ") || lower.contains("volume to ") {
            if let pct = extractVolumeAmount(from: lower) {
                NSLog("[Intent] detected: volume_set(%d%%)", pct)
                return .volumeControl(.setLevel(pct))
            }
        }

        // ── Increase: volume, sound, audio ───────────────────────────
        let increasePatterns = [
            "increase volume", "increase sound", "increase audio",
            "volume up", "sound up", "audio up",
            "turn up the volume", "turn up the sound", "turn up",
            "raise volume", "raise the volume",
            "louder", "make it louder", "volume louder",
            "bump up the volume", "bump the volume"
        ]
        if increasePatterns.contains(where: { lower.contains($0) }) {
            let amount = extractVolumeAmount(from: lower) ?? 10
            NSLog("[Intent] detected: volume_up(%d%%)", amount)
            return .volumeControl(.increase(by: amount))
        }

        // ── Decrease: volume, sound, audio ───────────────────────────
        let decreasePatterns = [
            "decrease volume", "decrease sound", "decrease audio",
            "volume down", "sound down", "audio down",
            "turn down the volume", "turn down the sound", "turn down",
            "lower volume", "lower the volume", "lower sound",
            "quieter", "make it quieter",
            "reduce volume", "reduce the volume"
        ]
        if decreasePatterns.contains(where: { lower.contains($0) }) {
            let amount = extractVolumeAmount(from: lower) ?? 10
            NSLog("[Intent] detected: volume_down(%d%%)", amount)
            return .volumeControl(.decrease(by: amount))
        }

        return nil
    }

    /// Extract a percentage/amount from spoken text.
    /// Handles:
    ///   "by 10%" → 10
    ///   "by ten" → 10
    ///   "by hundred" → 100
    ///   "by hundred percent" → 100
    ///   "100" → 100
    private func extractVolumeAmount(from lower: String) -> Int? {
        // Word-number mapping
        let wordNumbers: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
            "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100
        ]

        // Try word-number match first (e.g. "by ten", "by hundred percent")
        for (word, value) in wordNumbers {
            let patterns = ["by \(word) percent", "by \(word)", " \(word) percent", " \(word)"]
            for pattern in patterns {
                if lower.contains(pattern) {
                    return min(100, max(0, value))
                }
            }
        }

        // Try digit-based match (e.g. "by 10%", "increase volume by 10", "100")
        let pattern = #"(?:by\s+)?(\d+)\s*%?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower),
              let value = Int(lower[range]) else { return nil }
        return min(100, max(0, value))
    }

    /// Legacy alias kept for compatibility (delegates to extractVolumeAmount)
    private func extractPercent(from lower: String) -> Int? {
        extractVolumeAmount(from: lower)
    }

    // MARK: - Search query parser
    // NOTE: This is called BEFORE parseSinglePhrase so "search YouTube for X"
    // never falls through to the AI / Ollama path.

    private func parseSearchQuery(_ lower: String) -> [PlannedAction]? {
        // Bare "search youtube" / "search youtube for X"
        if lower == "search youtube" || lower == "open youtube search" {
            return [.openURL("https://www.youtube.com")]
        }

        let searchPatterns: [(pattern: String, engine: String, baseURL: String)] = [
            // YouTube-specific — MUST come before generic "search for"
            (#"search youtube for (.+)"#,  "YouTube", "https://www.youtube.com/results?search_query="),
            (#"youtube search for (.+)"#,  "YouTube", "https://www.youtube.com/results?search_query="),
            (#"search google for (.+)"#,   "Google",  "https://www.google.com/search?q="),
            (#"google (.+)"#,              "Google",  "https://www.google.com/search?q="),
            (#"search for (.+)"#,          "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) on youtube"#,  "YouTube", "https://www.youtube.com/results?search_query="),
            (#"search (.+?) on google"#,   "Google",  "https://www.google.com/search?q="),
        ]

        for entry in searchPatterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let qRange = Range(match.range(at: 1), in: lower) else { continue }
            let query   = String(lower[qRange]).trimmingCharacters(in: .whitespaces)
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            NSLog("[Plan] Search: engine=%@ query='%@'", entry.engine, query)
            // Return ONLY open_url — never AI query — for search commands
            return [.searchWeb(engine: entry.engine, query: query),
                    .openURL(entry.baseURL + encoded)]
        }

        return nil
    }

    // MARK: - Conjunction splitter

    private func splitByConjunction(_ lower: String) -> [String] {
        var parts = lower
            .replacingOccurrences(of: ", and ", with: " && ")
            .replacingOccurrences(of: " and then ", with: " && ")
            .replacingOccurrences(of: ", then ", with: " && ")
            .replacingOccurrences(of: " then ", with: " && ")
            .replacingOccurrences(of: " and ", with: " && ")
            .components(separatedBy: " && ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard parts.count > 1 else { return parts }

        // Propagate leading verb to parts that lack one
        // e.g. "open chrome and spotify" → ["open chrome", "open spotify"]
        let verbs = ["open ", "close ", "launch ", "play ", "search ", "create ", "run ", "start "]
        let firstVerb = verbs.first { parts[0].hasPrefix($0) }
        if let verb = firstVerb {
            parts = parts.map { part -> String in
                let hasVerb = verbs.contains { part.hasPrefix($0) }
                return hasVerb ? part : verb + part
            }
        }

        // Fix #4: STRICT validation — every part MUST have a recognized action verb
        // or be an exact media command. Noun-only parts ("chrome", "whatsapp") are
        // silently dropped instead of routed to AI.
        let exactCommands: Set<String> = [
            "play", "pause", "next", "previous", "prev", "skip", "resume", "mute", "unmute"
        ]
        let validated = parts.filter { part in
            let hasVerb = verbs.contains { part.hasPrefix($0) }
            let isExact = exactCommands.contains(part)
            if !hasVerb && !isExact {
                NSLog("[Intent] Dropped noun-only conjunction part (no action verb): '%@'", part)
            }
            return hasVerb || isExact
        }

        return validated
    }

    // MARK: - Helpers

    private func parseOpenInBrowser(_ lower: String) -> (url: String, browser: String)? {
        let pattern = #"open (.+) in (chrome|brave|firefox|safari|browser)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else {
            return nil
        }
        guard let siteRange   = Range(match.range(at: 1), in: lower),
              let browserRange = Range(match.range(at: 2), in: lower) else {
            return nil
        }
        let site    = String(lower[siteRange]).trimmingCharacters(in: .whitespaces)
        let browser = String(lower[browserRange])
        let url     = siteToURL(site)
        return (url, browser)
    }

    private func siteToURL(_ site: String) -> String {
        let known: [String: String] = [
            "youtube":  "https://www.youtube.com",
            "google":   "https://www.google.com",
            "spotify":  "https://open.spotify.com",
            "whatsapp": "https://web.whatsapp.com",
            "github":   "https://github.com",
            "netflix":  "https://www.netflix.com",
        ]
        if let url = known[site] { return url }
        if site.hasPrefix("http") { return site }
        return "https://\(site)"
    }

    private func extractFolderName(from lower: String) -> String? {
        let known = ["downloads", "documents", "desktop", "pictures", "movies", "music"]
        return known.first { lower.contains($0) }
    }

    private func resolveApp(_ name: String) -> String {
        AppAliasResolver.resolve(name)
    }

    // MARK: - Wake-word and trailing noise strippers

    private func stripWakeWord(_ text: String) -> String {
        // ✅ Case-insensitive regex strip: removes ALL Jarvis occurrences (any capitalisation)
        // Handles: "Jarvis", "JARVIS", "jarvis", "Hey Jarvis", "Ok Jarvis", "Okay Jarvis"
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip leading "hey/ok/okay jarvis" prefix variants first
        let prefixPattern = "^(?i)(hey\\s+jarvis|ok\\s+jarvis|okay\\s+jarvis|jarvis)\\s+"
        if let regex = try? NSRegularExpression(pattern: prefixPattern) {
            let range = NSRange(result.startIndex..., in: result)
            if let match = regex.firstMatch(in: result, range: range) {
                let matchRange = Range(match.range, in: result)!
                result = String(result[matchRange.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Strip any remaining embedded or trailing "jarvis" tokens
        result = result
            .replacingOccurrences(of: "(?i)\\bjarvis\\b", with: "",
                                   options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }

    /// Removes noise tokens from the end of a command that could confuse intent parsing.
    /// E.g., "play music Jarvis", "next song Jarvis okay"
    private func stripTrailingNoise(_ text: String) -> String {
        let noiseTokens: Set<String> = ["jarvis", "okay", "ok", "please", "now", "hey", "right"]
        var tokens = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
        var changed = true
        while changed {
            changed = false
            if let last = tokens.last?.lowercased(), noiseTokens.contains(last) {
                tokens.removeLast()
                changed = true
            }
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Ollama fallback (complex / unrecognised input only)

    private func ollamaFallback(_ cleaned: String) async -> [PlannedAction] {
        let prompt = """
        You are a command planner for a macOS voice assistant.
        Map the user's input to a JSON array of actions.

        Allowed action types and their JSON shapes:
        { "type": "open_app",    "app": "<name>" }
        { "type": "close_app",   "app": "<name>" }
        { "type": "open_url",    "url": "<url>" }
        { "type": "search_web",  "engine": "Google", "query": "<query>" }
        { "type": "open_folder", "path": "<name>" }
        { "type": "media",       "action": "play|pause|next|prev|liked_songs" }
        { "type": "ai_query",    "query": "<query>" }

        Rules:
        - "search YouTube" or "search YouTube for X" → use open_url with youtube search, NOT ai_query
        - "liked songs" → media action "liked_songs"
        - "next song" / "previous song" → media next / prev

        Output ONLY a valid JSON array. No explanations.

        User: \(cleaned)
        """
        let response = await ollamaClient.generate(prompt: prompt)

        if let actions = parseOllamaActions(response) {
            return actions
        }

        return [.aiQuery(cleaned)]
    }

    private func parseOllamaActions(_ raw: String) -> [PlannedAction]? {
        guard let start  = raw.firstIndex(of: "["),
              let end    = raw.lastIndex(of: "]") else { return nil }
        let jsonStr = String(raw[start...end])

        guard let data = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var actions: [PlannedAction] = []
        for obj in array {
            guard let type = obj["type"] as? String else { continue }
            switch type {
            case "open_app":
                if let app = obj["app"] as? String { actions.append(.openApp(app)) }
            case "close_app":
                if let app = obj["app"] as? String { actions.append(.closeApp(app)) }
            case "open_url":
                if let url = obj["url"] as? String { actions.append(.openURL(url)) }
            case "search_web":
                let engine = (obj["engine"] as? String) ?? "Google"
                if let q   = obj["query"] as? String {
                    actions.append(.searchWeb(engine: engine, query: q))
                }
            case "open_folder":
                if let p = obj["path"] as? String { actions.append(.openFolder(p)) }
            case "media":
                if let a = obj["action"] as? String {
                    switch a {
                    case "play":         actions.append(.mediaControl(.play))
                    case "pause":        actions.append(.mediaControl(.pause))
                    case "next":         actions.append(.mediaControl(.nextTrack))
                    case "prev":         actions.append(.mediaControl(.previousTrack))
                    case "liked_songs":  actions.append(.mediaControl(.playLikedSongs))
                    default:             break
                    }
                }
            case "ai_query":
                if let q = obj["query"] as? String { actions.append(.aiQuery(q)) }
            default:
                break
            }
        }
        return actions.isEmpty ? nil : actions
    }
}
