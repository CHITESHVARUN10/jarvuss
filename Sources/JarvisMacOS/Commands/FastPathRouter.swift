import Foundation

// MARK: - Fast-path router (no-LLM gate)
//
// Called FIRST by plan(from:) before any rule parsing or Ollama fallback.
// Simple commands — open/close app, volume, media transport, display,
// search, time/date — execute straight from regexes with ZERO model load.
// Only genuinely complex, multi-step or question-like input reaches Qwen.
//
// This is the RAM fix for ⌘⇧A voice: Whisper mistranscriptions like
// "open spotify" must never wake a 1.5B inference for a one-word intent.
enum FastPathRouter {

    enum Verdict: Equatable {
        case execute([PlannedAction])
        case needsModel
    }

    static func route(_ cleaned: String) -> Verdict {
        let lower = cleaned.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .execute([]) }

        // Single known app shortcut: "chrome", "spotify", "whatsapp"
        if let shortcut = singleAppShortcut(lower) {
            return .execute([.openApp(resolveApp(shortcut))])
        }

        // Browser-targeted site and local dev URLs must run before the app
        // resolver, or "open chatgpt in brave" is treated as an app name.
        if let target = OpenTargetResolver.parseOpenInBrowser(lower) {
            return .execute([.openURLInBrowser(url: target.url, browser: target.browser)])
        }
        if let target = OpenTargetResolver.parseLocalDev(lower) {
            return .execute([.openURLInBrowser(url: target.url, browser: target.browser)])
        }

        // open/launch/start/run/close/quit + target (one app, no conjunction)
        if !lower.contains(" and ") && !lower.contains(" then ") {
            if let action = singleAppCommand(lower) {
                return .execute([action])
            }
        }

        // Known website: "open youtube", "open google", etc.
        if let url = knownWebsite(lower) {
            return .execute([.openURL(url)])
        }

        // Search: "search youtube/google/web for X", "google X"
        if let search = singleSearch(lower) {
            return .execute(search)
        }

        // Time / date / day / month / year + device reads — answered
        // locally with zero model load. Previously these returned
        // .aiQuery (an Ollama call for "what time is it"); now they route
        // to .systemInfo like the rule path below. Multi-clause inputs
        // stay out so the conjunction splitter keeps every clause.
        if !QuickInfoMatcher.looksCompound(lower),
           let kind = QuickInfoMatcher.match(lower) {
            return .execute([.systemInfo(QuickInfoMatcher.systemInfoAction(for: kind))])
        }
        if !QuickInfoMatcher.looksCompound(lower),
           let info = quickDeviceInfo(lower) {
            return .execute([.systemInfo(info)])
        }

        // Volume / mute / media transport / display — pure regex, no model.
        if let vol = singleVolume(lower) { return .execute([vol]) }
        if let media = singleMedia(lower) { return .execute([media]) }
        if let display = singleDisplay(lower) { return .execute([display]) }

        // AI question prefixes ("explain X", "what is X") — short enough
        // that the local answer path handles them; still no model call HERE.
        // (runCommand routes .aiQuery to Ollama exactly once downstream.)
        if isAIQuestion(lower) {
            return .execute([.aiQuery(cleaned)])
        }

        // Short single-intent utterances (≤ 3 words) that match NO rule and
        // carry NO system keyword are noise, not questions — drop locally.
        let words = lower.split(separator: " ").map(String.init)
        if words.count <= 3 && !containsSystemKeyword(words) {
            NSLog("[FastPath] dropping short noise without model: '%@'", cleaned)
            return .execute([])
        }

        return .needsModel
    }

    // MARK: - Matchers (pure functions, no I/O)

    private static func singleAppShortcut(_ lower: String) -> String? {
        let shortcuts: Set<String> = ["chrome", "spotify", "whatsapp"]
        return shortcuts.contains(lower) ? lower : nil
    }

    private static func singleAppCommand(_ lower: String) -> PlannedAction? {
        let verbs: [(prefix: String, close: Bool)] = [
            ("open ", false), ("launch ", false), ("start ", false), ("run ", false),
            ("close ", true), ("quit ", true),
        ]
        for verb in verbs {
            guard lower.hasPrefix(verb.prefix) else { continue }
            let target = String(lower.dropFirst(verb.prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, target.split(separator: " ").count <= 4 else { return nil }
            if let url = websiteURL(for: target) ?? OpenTargetResolver.siteURL(for: target) {
                return .openURL(url)
            }
            let resolved = resolveApp(target)
            return verb.close ? .closeApp(resolved) : .openApp(resolved)
        }
        return nil
    }

    private static func knownWebsite(_ lower: String) -> String? {
        let sites = ["youtube": "https://www.youtube.com",
                     "google": "https://www.google.com",
                     "netflix": "https://www.netflix.com",
                     "github": "https://github.com"]
        for (name, url) in sites {
            if lower == "open \(name)" || lower == name { return url }
        }
        if lower.hasPrefix("open ") {
            return OpenTargetResolver.siteURL(for: String(lower.dropFirst("open ".count)))
        }
        return OpenTargetResolver.siteURL(for: lower)
    }

    private static func websiteURL(for target: String) -> String? {
        let t = target.lowercased().trimmingCharacters(in: .whitespaces)
        switch t {
        case "youtube", "you tube":       return "https://www.youtube.com"
        case "google":                    return "https://www.google.com"
        case "netflix":                   return "https://www.netflix.com"
        case "github", "git hub":         return "https://github.com"
        case "twitter", "x", "twitter x": return "https://twitter.com"
        case "reddit":                    return "https://www.reddit.com"
        case "instagram":                 return "https://www.instagram.com"
        case "linkedin":                  return "https://www.linkedin.com"
        case "gmail":                     return "https://mail.google.com"
        case "maps", "google maps":       return "https://maps.google.com"
        default:                          return nil
        }
    }

    private static func singleSearch(_ lower: String) -> [PlannedAction]? {
        // Mirrors parseSearchQuery's coverage so fast-path hits return the
        // SAME single searchWeb action (executor opens the URL once).
        let patterns: [(pattern: String, engine: String)] = [
            (#"search (?:on )?youtube for (.+)"#, "YouTube"),
            (#"youtube search for (.+)"#,          "YouTube"),
            (#"search google for (.+)"#,           "Google"),
            (#"search (?:on the )?internet for (.+)"#, "Google"),
            (#"search for (.+)"#,                  "Google"),
            (#"search (.+?) on youtube"#,          "YouTube"),
            (#"search (.+?) in youtube"#,          "YouTube"),
            (#"search (.+?) on google"#,           "Google"),
            (#"search (.+?) in google"#,           "Google"),
            (#"search (.+?) in brave"#,            "Google"),
            (#"search (.+?) on brave"#,            "Google"),
        ]
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let qRange = Range(match.range(at: 1), in: lower) else { continue }
            var query = String(lower[qRange]).trimmingCharacters(in: .whitespaces)
            query = query.trimmingCharacters(in: CharacterSet(charactersIn: "?.!."))
                .trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { continue }
            return [.searchWeb(engine: entry.engine, query: query)]
        }
        return nil
    }

    /// Device/system reads that the rule path also answers locally
    /// (parseInfoCommand). Kept separate from QuickInfoMatcher, which owns
    /// the time/date/day/month/year tables shared with presentation.
    private static func quickDeviceInfo(_ lower: String) -> SystemInfoAction? {
        if lower.contains("wifi") { return .wifiStatus }
        if lower.contains("bluetooth") { return .bluetoothDevices }
        if lower.contains("battery") { return .batteryStatus }
        if lower == "system volume" || lower == "current volume" || lower == "volume level" {
            return .systemVolume
        }
        return nil
    }

    private static func singleVolume(_ lower: String) -> PlannedAction? {
        if lower == "mute" || lower == "mute the sound" || lower == "sound off" { return .volumeControl(.mute) }
        if lower == "unmute" || lower == "sound on" { return .volumeControl(.unmute) }
        if lower.contains("volume up") || lower.contains("sound up") || lower == "louder" {
            return .volumeControl(.increase(by: 10))
        }
        if lower.contains("volume down") || lower.contains("sound down") || lower == "quieter" {
            return .volumeControl(.decrease(by: 10))
        }
        return nil
    }

    private static func singleMedia(_ lower: String) -> PlannedAction? {
        if lower == "pause" || lower == "stop" { return .mediaControl(.pause) }
        if lower == "play" || lower == "resume" { return .mediaControl(.play) }
        if lower == "next" || lower == "next song" || lower == "next track" || lower == "skip" {
            return .mediaControl(.nextTrack)
        }
        if lower == "previous" || lower == "previous song" || lower == "prev" {
            return .mediaControl(.previousTrack)
        }
        if lower.contains("liked songs") || lower.contains("liked") && lower.contains("songs") {
            return .mediaControl(.playLikedSongs)
        }
        return nil
    }

    private static func singleDisplay(_ lower: String) -> PlannedAction? {
        if lower.contains("brighter") || lower.contains("brightness up") { return .displayControl(.increaseBrightness(by: 10)) }
        if lower.contains("dimmer") || lower.contains("brightness down") { return .displayControl(.decreaseBrightness(by: 10)) }
        return nil
    }

    private static func isAIQuestion(_ lower: String) -> Bool {
        ["explain ", "what is ", "who is ", "why ", "how ", "tell me ", "describe "]
            .contains(where: { lower.hasPrefix($0) })
    }

    private static func containsSystemKeyword(_ words: [String]) -> Bool {
        let keywords: Set<String> = [
            "open", "close", "launch", "start", "run", "quit",
            "volume", "mute", "unmute", "play", "pause", "next", "previous", "skip",
            "search", "create", "brightness", "contrast",
        ]
        return words.contains(where: { keywords.contains($0) })
    }

    private static func resolveApp(_ name: String) -> String {
        AppAliasResolver.resolveSpoken(name)
    }
}

