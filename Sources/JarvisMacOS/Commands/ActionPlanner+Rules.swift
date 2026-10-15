import Foundation

extension ActionPlanner {
    func ruleBasedPlan(cleaned: String, lower: String) -> [PlannedAction]? {

        // ── Compound commands FIRST ─────────────────────────────────
        // A multi-clause utterance must never be parsed as one giant target:
        // "open notes and increase the volume by 20 percent" used to become
        // openApp("notes and increase the volume by 20 percent"). Split
        // before any whole-string rule sees it.
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
                // Or a file-exploration question ("…and how many folders are in downloads")
                if let files = parseFileQuery(partTrimmed) {
                    actions.append(files)
                    continue
                }
                // Display on each part ("…and increase the brightness by 5 percent")
                if let display = parseDisplayCommand(partTrimmed) {
                    actions.append(display)
                    continue
                }
                // Search on each part ("…and in that search for iphone")
                if let searchActions = parseSearchQuery(partTrimmed) {
                    actions.append(contentsOf: searchActions)
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

        if let system = parseSystemCommand(lower) {
            NSLog("[Intent] SYSTEM: %@", lower)
            return [system]
        }

        if let info = parseInfoCommand(lower) {
            NSLog("[Intent] INFO: %@", info.description)
            return [.systemInfo(info)]
        }

        // Volume remains before media and after system/info.
        if let display = parseDisplayCommand(lower) { return [display] }

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

        // ── File exploration (counts, listing, sizes, oldest/newest) ─
        if let files = parseFileQuery(lower) {
            return [files]
        }

        // ── Single-phrase parse ─────────────────────────────────────
        let single = parseSinglePhrase(lower, originalRaw: cleaned)
        return single.isEmpty ? nil : single
    }

    func splitCompoundMediaCommand(_ lower: String) -> [PlannedAction]? {
        _ = lower
        // Disabled intentionally: control commands must execute as a single action.
        return nil
    }

    // MARK: - Single-phrase parser

    func parseSinglePhrase(_ lower: String, originalRaw: String) -> [PlannedAction] {

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

    func parseSystemCommand(_ lower: String) -> PlannedAction? {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let app = singleAppShortcut(for: trimmed) {
            return .openApp(resolveApp(app))
        }

        if trimmed.hasPrefix("open ") {
            let target = String(trimmed.dropFirst("open ".count)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                // Route known websites to openURL rather than openApp.
                // parseSinglePhrase has the same map, but parseSystemCommand fires first,
                // so we need the check here.
                if let url = knownWebsiteURL(for: target) {
                    return .openURL(url)
                }
                return .openApp(resolveApp(target))
            }
        }

        if trimmed.hasPrefix("launch ") {
            let target = String(trimmed.dropFirst("launch ".count)).trimmingCharacters(in: .whitespaces)
            if !target.isEmpty {
                if let url = knownWebsiteURL(for: target) {
                    return .openURL(url)
                }
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

    /// Maps common spoken website names to their canonical URLs.
    /// Add new sites here only — do NOT add native apps (Spotify, WhatsApp, etc.).
    func knownWebsiteURL(for target: String) -> String? {
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

    func parseInfoCommand(_ lower: String) -> SystemInfoAction? {
        let trimmed = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Time/date/day/month/year share one table with the FastPath router
        // and AppState presentation (QuickInfoMatcher) — never three copies.
        if !QuickInfoMatcher.looksCompound(trimmed),
           let kind = QuickInfoMatcher.match(trimmed) {
            switch kind {
            case .time:  return .currentTime
            case .date:  return .currentDate
            case .day:   return .currentDay
            case .month: return .currentMonth
            case .year:  return .currentYear
            }
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

    func singleAppShortcut(for lower: String) -> String? {
        let appNames: Set<String> = ["chrome", "spotify", "whatsapp"]
        return appNames.contains(lower) ? lower : nil
    }

    /// Returns a PlannedAction for any media-related utterance, or nil if not media.
    /// Must be called BEFORE parseSinglePhrase to prevent "play song" → openApp.
    func parseSearchQuery(_ lower: String) -> [PlannedAction]? {
        // Bare "search youtube" / "search youtube for X"
        if lower == "search youtube" || lower == "open youtube search" {
            return [.openURL("https://www.youtube.com")]
        }

        let searchPatterns: [(pattern: String, engine: String, baseURL: String)] = [
            // YouTube-specific — MUST come before generic "search for".
            // Covers the ⌘⇧A phrasings in the wild: "search on youtube for X",
            // "search X on youtube", "search X in youtube", trailing periods
            // from Whisper ("...in youtube.").
            (#"search (?:on )?youtube for (.+)"#, "YouTube", "https://www.youtube.com/results?search_query="),
            (#"youtube search for (.+)"#,          "YouTube", "https://www.youtube.com/results?search_query="),
            (#"search google for (.+)"#,           "Google",  "https://www.google.com/search?q="),
            (#"google (.+)"#,                      "Google",  "https://www.google.com/search?q="),
            (#"search (?:on )?the web for (.+)"#,  "Google",  "https://www.google.com/search?q="),
            (#"search (?:on )?(?:the )?web for (.+)"#, "Google", "https://www.google.com/search?q="),
            (#"search (?:on the )?internet for (.+)"#, "Google", "https://www.google.com/search?q="),
            (#"search for (.+)"#,                  "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) on youtube"#,          "YouTube", "https://www.youtube.com/results?search_query="),
            (#"search (.+?) in youtube"#,          "YouTube", "https://www.youtube.com/results?search_query="),
            (#"search (.+?) on google"#,           "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) in google"#,           "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) on the web"#,          "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) on the internet"#,     "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) in brave"#,            "Google",  "https://www.google.com/search?q="),
            (#"search (.+?) on brave"#,            "Google",  "https://www.google.com/search?q="),
        ]

        for entry in searchPatterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let qRange = Range(match.range(at: 1), in: lower) else { continue }
            var query = String(lower[qRange]).trimmingCharacters(in: .whitespaces)
            // Whisper appends sentence punctuation ("...in youtube.").
            query = query.trimmingCharacters(in: CharacterSet(charactersIn: "?.!."))
                .trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { continue }
            NSLog("[Plan] Search: engine=%@ query='%@'", entry.engine, query)
            // SINGLE open: executor already opens the URL from searchWeb —
            // returning both searchWeb AND openURL opened the browser twice.
            return [.searchWeb(engine: entry.engine, query: query)]
        }

        return nil
    }

    // MARK: - File exploration

    /// Spoken file questions → one `FileQuery`. Answers come from FileManager,
    /// so these never touch the shell and never reach the LLM.
    func parseFileQuery(_ lower: String) -> PlannedAction? {
        let text = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let folderWords = ["downloads", "download", "documents", "document", "docs",
                           "desktop", "pictures", "photos", "images", "movies",
                           "videos", "music", "home folder", "home directory"]
        let hasFolderWord = folderWords.contains { text.contains($0) }
        let hasFileWord = text.contains("file") || text.contains("folder")
            || text.contains("pdf") || text.contains("ppt") || text.contains("doc")
            || text.contains("spreadsheet") || text.contains("image") || text.contains("photo")
        guard hasFolderWord || hasFileWord else { return nil }

        // Anything that opens an app or a website is not a file question.
        if text.hasPrefix("open app ") || text.contains("youtube") || text.contains("google search") {
            return nil
        }

        let ext = detectFileExtension(text)
        let folder = detectFolderName(text) ?? "downloads"

        // ── Open the newest / oldest file ───────────────────────────
        let openVerb = text.hasPrefix("open ") || text.hasPrefix("show me ") || text.contains("open the ")
        if openVerb && (containsAnyWord(text, words: ["latest", "newest", "recent", "recently", "last"])
                        || text.contains("most recent")) {
            return .fileQuery(FileQuery(op: .openNewest, folder: folder, ext: ext))
        }
        if openVerb && containsAnyWord(text, words: ["oldest", "earliest", "first"]) {
            return .fileQuery(FileQuery(op: .openOldest, folder: folder, ext: ext))
        }

        // ── Counts ──────────────────────────────────────────────────
        let countish = text.contains("how many") || text.contains("number of")
            || text.hasPrefix("count ") || text.contains("count the")
            || text.contains("total number")
        if countish {
            return .fileQuery(FileQuery(op: wantsFolders(text) ? .countFolders : .count,
                                        folder: folder, ext: ext))
        }

        // ── Sizes ───────────────────────────────────────────────────
        if containsAnyWord(text, words: ["biggest", "largest", "heaviest"]) {
            return .fileQuery(FileQuery(op: .largest, folder: folder, ext: ext))
        }
        if text.contains("how much space") || text.contains("total size")
            || text.contains("size of all") || text.contains("take up") || text.contains("total space") {
            return .fileQuery(FileQuery(op: .totalSize, folder: folder, ext: ext))
        }

        // ── Oldest / newest ─────────────────────────────────────────
        if containsAnyWord(text, words: ["oldest", "earliest"]) {
            return .fileQuery(FileQuery(op: .oldest, folder: folder, ext: ext))
        }
        if containsAnyWord(text, words: ["latest", "newest", "recent", "recently"])
            || text.contains("most recent") {
            return .fileQuery(FileQuery(op: .newest, folder: folder, ext: ext))
        }

        // ── Listing ─────────────────────────────────────────────────
        let listingVerb = text.hasPrefix("list ") || text.hasPrefix("show ")
            || text.hasPrefix("tell me ") || text.hasPrefix("what ")
            || text.hasPrefix("which ") || text.contains("name of")
            || text.hasPrefix("give me ")
        if listingVerb || text.contains("what are the files") {
            return .fileQuery(FileQuery(op: wantsFolders(text) ? .listFolders : .list,
                                        folder: folder, ext: ext))
        }

        return nil
    }

    /// True when the QUESTION is about folders. The plural is what
    /// distinguishes "how many folders are in my downloads folder" (a folder
    /// count) from "the files in my documents folder" (a file list) — the
    /// singular "folder" is usually just the location noun.
    func wantsFolders(_ text: String) -> Bool {
        containsAnyWord(text, words: ["folders", "subfolder", "subfolders", "directories", "directory"])
            || text.contains("how many folder ")
            || text.contains("number of folder ")
    }

    /// Extensions the user actually names out loud.
    func detectFileExtension(_ text: String) -> String {
        let known = ["pdf", "pptx", "ppt", "docx", "doc", "xlsx", "xls", "csv",
                     "txt", "md", "json", "png", "jpg", "jpeg", "gif", "heic",
                     "mp4", "mov", "mp3", "zip", "swift", "py"]
        for ext in known where containsAnyWord(text, words: [ext]) {
            // "ppt" is how people say pptx; match either.
            if ext == "ppt" { return "pptx" }
            if ext == "doc" { return "docx" }
            if ext == "xls" { return "xlsx" }
            if ext == "jpeg" { return "jpg" }
            return ext
        }
        if containsAnyWord(text, words: ["image", "images", "photo", "photos", "picture", "pictures"]) {
            return "png"
        }
        if containsAnyWord(text, words: ["spreadsheet", "spreadsheets"]) { return "xlsx" }
        if containsAnyWord(text, words: ["presentation", "presentations", "deck", "decks", "slides"]) { return "pptx" }
        if containsAnyWord(text, words: ["video", "videos", "movie", "movies"]) { return "mp4" }
        return ""
    }

    /// The folder the question is about, or nil when the user did not say.
    func detectFolderName(_ text: String) -> String? {
        let ordered = ["downloads", "download", "documents", "docs", "desktop",
                       "pictures", "photos", "images", "movies", "videos", "music"]
        for word in ordered where text.contains(word) {
            return word
        }
        if text.contains("home folder") || text.contains("home directory") { return "home" }
        return nil
    }

    // MARK: - Conjunction splitter

    func splitByConjunction(_ lower: String) -> [String] {
        // A comma only starts a new clause when the next words are a fresh
        // action ("open spotify, open whatsapp") — a comma inside a search
        // query or a title ("search for iPhone 18 Pro, blue colour") must
        // stay in the same intent.
        let verbLookahead = "open|close|launch|quit|play|pause|resume|stop|next|previous|prev|skip|"
            + "search|google|find|list|count|show|tell|create|run|start|increase|decrease|set|turn|"
            + "mute|unmute|make|check|calculate"

        var parts = lower
            .replacingOccurrences(of: ", and ", with: " && ")
            .replacingOccurrences(of: " and then ", with: " && ")
            .replacingOccurrences(of: ", then ", with: " && ")
            .replacingOccurrences(
                of: ",\\s*(?=(?:also\\s+|plus\\s+|then\\s+)?(?:\(verbLookahead))\\b)",
                with: " && ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: " and ", with: " && ")
            .replacingOccurrences(of: " then ", with: " && ")
            .components(separatedBy: " && ")
            .map { dropLeadingConnectors($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }

        guard parts.count > 1 else { return parts }

        // Propagate the leading verb to parts that carry NO action verb at all
        // ("open chrome and spotify" → ["open chrome", "open spotify"]).
        let verbs = ["open ", "close ", "launch ", "play ", "search ", "create ", "run ", "start "]
        let firstVerb = verbs.first { parts[0].hasPrefix($0) }
        if let verb = firstVerb {
            parts = parts.map { part -> String in
                // A file question has no verb but is a complete intent.
                if hasActionVerb(part) || parseFileQuery(part) != nil { return part }
                return verb + part
            }
        }

        // Every part must still carry an action verb, otherwise it was noise.
        let exactCommands: Set<String> = [
            "play", "pause", "next", "previous", "prev", "skip", "resume", "mute", "unmute"
        ]
        let validated = parts.filter { part in
            if hasActionVerb(part) || exactCommands.contains(part) { return true }
            if parseFileQuery(part) != nil { return true }
            NSLog("[Intent] Dropped conjunction part without an action: '%@'", part)
            return false
        }

        return validated
    }

    /// Strip clause preamble so each part starts at its action:
    ///   "also open youtube"          → "open youtube"
    ///   "in chrome open youtube"     → "open youtube"
    ///   "in that search for iphone"  → "search for iphone"
    func dropLeadingConnectors(_ text: String) -> String {
        let connectors = ["and also ", "and then ", "and ", "also ", "plus ", "then ", "please "]
        var result = text
        var changed = true
        while changed {
            changed = false
            for connector in connectors where result.hasPrefix(connector) {
                result = String(result.dropFirst(connector.count))
                changed = true
            }
        }

        result = result.trimmingCharacters(in: .whitespaces)

        // Not starting at an action? Drop the preamble up to the first verb.
        if !startsWithActionVerb(result) {
            let tokens = result.split(separator: " ").map(String.init)
            if let index = tokens.firstIndex(where: { isActionVerbToken($0) }), index > 0 {
                result = tokens[index...].joined(separator: " ")
            }
        }
        return result
    }

    static let actionVerbTokens: Set<String> = [
        "open", "close", "launch", "quit", "play", "pause", "resume", "stop",
        "next", "previous", "prev", "skip", "search", "google", "find", "list",
        "count", "show", "tell", "create", "run", "start", "increase", "decrease",
        "set", "turn", "mute", "unmute", "make", "check", "calculate",
    ]

    func isActionVerbToken(_ token: String) -> Bool {
        Self.actionVerbTokens.contains(
            token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        )
    }

    /// How many action verbs the utterance contains, counting repeats:
    /// "open spotify, open whatsapp and play a song" → 3 clauses.
    func actionVerbCount(_ text: String) -> Int {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .filter { isActionVerbToken(String($0)) }
            .count
    }

    func startsWithActionVerb(_ text: String) -> Bool {
        guard let first = text.split(separator: " ").first else { return false }
        return isActionVerbToken(String(first))
    }

    /// True when any token of the part is an action verb — position-free, so
    /// "in spotify play a song" counts as an action.
    func hasActionVerb(_ text: String) -> Bool {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .contains { isActionVerbToken(String($0)) }
    }

    // MARK: - Helpers

    /// Local hardware-state reads that must NEVER reach Ollama.
    /// "What is the current brightness level" → systemInfo read answered
    /// from DisplayController, same as volume. Without this, Qwen
    /// hallucinates code for a question only the OS can answer.
    func answerLocalStateQuery(cleaned: String, lower: String) -> [PlannedAction]? {
        let brightnessTerms = ["brightness level", "brightness", "screen brightness"]
        let isBrightnessQ = (lower.contains("what") || lower.contains("current") || lower.contains("show") || lower.contains("tell"))
            && brightnessTerms.contains(where: { lower.contains($0) })
            && !lower.contains("set") && !lower.contains("increase") && !lower.contains("decrease")
            && !lower.contains("dimmer") && !lower.contains("brighter")
        if isBrightnessQ {
            NSLog("[Intent] INFO: brightness level (local read, no LLM)")
            return [.systemInfo(.displayBrightness)]
        }
        let contrastTerms = ["contrast level", "contrast"]
        let isContrastQ = (lower.contains("what") || lower.contains("current") || lower.contains("show") || lower.contains("tell"))
            && contrastTerms.contains(where: { lower.contains($0) })
            && !lower.contains("set") && !lower.contains("increase") && !lower.contains("decrease")
        if isContrastQ {
            NSLog("[Intent] INFO: contrast level (local read, no LLM)")
            return [.systemInfo(.displayContrast)]
        }
        return nil
    }

    func parseOpenInBrowser(_ lower: String) -> (url: String, browser: String)? {
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

    func siteToURL(_ site: String) -> String {
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

    func extractFolderName(from lower: String) -> String? {
        let known = ["downloads", "documents", "desktop", "pictures", "movies", "music"]
        return known.first { lower.contains($0) }
    }

    func resolveApp(_ name: String) -> String {
        AppAliasResolver.resolveSpoken(name)
    }

    // MARK: - Wake-word and trailing noise strippers

    func stripWakeWord(_ text: String) -> String {
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
    func stripTrailingNoise(_ text: String) -> String {
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

}
