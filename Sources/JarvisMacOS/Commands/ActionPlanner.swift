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

        // Time / date / day / month / year — answered locally, no model.
        if isQuickInfo(lower) {
            return .execute([.aiQuery(cleaned)])
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
            if let url = websiteURL(for: target) { return .openURL(url) }
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
        return nil
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

    private static func isQuickInfo(_ lower: String) -> Bool {
        let terms = ["what time", "current time", "time right now",
                     "what day", "what date", "today's date", "todays date", "current date",
                     "what month", "what year", "system volume", "current volume",
                     "wifi", "bluetooth", "battery"]
        return terms.contains(where: { lower.contains($0) })
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

// MARK: - ActionPlanner

// MARK: - Test hooks

/// Exposes the parsing internals to the test suite. These are thin wrappers —
/// no behaviour lives here.
extension ActionPlanner {
    func debugSplitByConjunction(_ text: String) -> [String] {
        splitByConjunctionForTesting(text)
    }

    func debugMediaCommand(_ text: String) -> PlannedAction? {
        mediaCommandForTesting(text)
    }

    func debugFileQuery(_ text: String) -> PlannedAction? {
        fileQueryForTesting(text)
    }
}

/// Rule-based intent parser.  Ollama is called ONLY when the input
/// cannot be parsed by any rule and is also not a known single command.
final class ActionPlanner {

    private let ollamaClient = OllamaClient(model: JarvisModel.name)
    private let intentModelRouter = IntentModelRouter()

    // Thin internal wrappers over the private parsers, used only by tests.
    func splitByConjunctionForTesting(_ text: String) -> [String] { splitByConjunction(text) }
    func mediaCommandForTesting(_ text: String) -> PlannedAction? { parseMediaCommand(text) }
    func fileQueryForTesting(_ text: String) -> PlannedAction? { parseFileQuery(text) }
    func rulePlanForTesting(_ text: String) -> [PlannedAction]? {
        ruleBasedPlan(cleaned: text, lower: text.lowercased())
    }

    // ── Public entry point ──────────────────────────────────────────

    func plan(from raw: String, requestID: UUID = UUID()) async -> [PlannedAction] {
        // 1. Strip wake word and trailing noise before anything else
        let cleaned = stripWakeWord(stripTrailingNoise(raw))
        let lower   = cleaned.lowercased()

        NSLog("[Plan] Input cleaned: '%@'", cleaned)

        // 1b. Local state reads — "what is the current brightness/volume
        // level" is answered from hardware, NEVER sent to Ollama (the
        // code-dump bug: Qwen answered a hardware question with Java).
        if JarvisFlags.useRustPipeline {
            if let rustLocal = coreResolveLocalState(cleaned: cleaned) {
                let local = RustPipeline.map(rustLocal)
                logPlanEvent(branch: "local", text: cleaned, requestID: requestID, actions: local)
                return local
            }
        } else if let local = answerLocalStateQuery(cleaned: cleaned, lower: lower) {
            logPlanEvent(branch: "local", text: cleaned, requestID: requestID, actions: local)
            return local
        }

        // 2. Safety pre-check on the full input (runs BEFORE the routers
        // so destructive/sudo/install input never executes unchecked).
        switch SafetyGuard.validate(rawCommand: cleaned) {
        case .blocked(let reason):
            let blocked = [PlannedAction.aiQuery("blocked: \(reason)")]
            logPlanEvent(branch: "blocked", text: cleaned, requestID: requestID, actions: blocked)
            return blocked
        case .installPreview(let cmd, let src):
            let preview = [PlannedAction.installPreview(package: cmd, source: src)]
            logPlanEvent(branch: "install", text: cleaned, requestID: requestID, actions: preview)
            return preview
        case .allowed:
            break
        }

        // 2a. Learned intent model — primary router. It understands phrasing
        // and ordered multi-step plans the regexes cannot. On ANY miss
        // (disabled, backend down, low confidence, unmappable JSON) it logs
        // to intent_router.jsonl for RL and returns nil — the regex pipeline
        // below (FastPathRouter → rules → Qwen) stays as the safety net.
        if let learned = await intentModelRouter.route(cleaned, requestID: requestID) {
            // Truncation guard: a compound utterance with N action verbs must
            // come back with (roughly) N actions. The model sometimes stops
            // early on long chains — "open spotify, open whatsapp and also open
            // youtube and in spotify play a song" returned 3 of the 4 clauses,
            // silently dropping "play a song". When that happens the rule
            // splitter is the more reliable path.
            //
            // "open youtube and search for X" legitimately collapses to ONE
            // web.search, so each search in the answer forgives one verb.
            let verbCount = actionVerbCount(cleaned)
            if verbCount >= 2 {
                let searches = learned.filter {
                    if case .searchWeb = $0 { return true }
                    return false
                }.count
                let expected = max(1, verbCount - searches)
                if learned.count < expected {
                    NSLog("[Plan] model truncated: %d actions for %d action verbs — falling through to rules",
                          learned.count, verbCount)
                    IntentRouterLog.shared.append([
                        "event": "model_miss",
                        "request_id": requestID.uuidString,
                        "text": cleaned,
                        "reason": "truncated_chain",
                        "raw": learned.map(\.description).joined(separator: ", "),
                        "confidence": 0,
                        "total_ms": 0,
                    ])
                } else {
                    NSLog("[Plan] Intent model: %@", learned.map(\.description).joined(separator: ", "))
                    logPlanEvent(branch: "model", text: cleaned, requestID: requestID, actions: learned)
                    return learned
                }
            } else {
                NSLog("[Plan] Intent model: %@", learned.map(\.description).joined(separator: ", "))
                logPlanEvent(branch: "model", text: cleaned, requestID: requestID, actions: learned)
                return learned
            }
        }

        // 2b. Post-model flow — fast-path router, then the strict priority
        // rules. With the migration flag ON this whole block is decided by
        // the Rust core; OFF keeps the Swift path and logs a shadow
        // comparison so parity can be verified from real usage.
        if JarvisFlags.useRustPipeline {
            let rust = corePlanAfterModel(cleaned: cleaned)
            if rust.needsOllama {
                // Rust owns the Ollama planner fallback (tools prompt +
                // Shape A parsing); unparseable output becomes a single
                // aiQuery exactly like the Swift path.
                let outcome = await RustPipeline.runBlocking { coreOllamaPlan(cleaned: cleaned) }
                if outcome.error == nil {
                    StatsRecorder.shared.recordLLM(promptChars: Int(outcome.promptChars),
                                                   responseChars: Int(outcome.responseChars))
                }
                let actions = RustPipeline.map(outcome.actions)
                NSLog("[Plan] Rust+Ollama (\(outcome.parsed ? "parsed" : "fallback")): %@",
                      actions.map(\.description).joined(separator: ", "))
                logPlanEvent(branch: "qwen", text: cleaned, requestID: requestID, actions: actions)
                return actions
            }
            let rustActions = RustPipeline.map(rust.actions)
            NSLog("[Plan] Rust (%@): %@", rust.branch,
                  rustActions.map(\.description).joined(separator: ", "))
            logPlanEvent(branch: rust.branch, text: cleaned, requestID: requestID, actions: rustActions)
            return rustActions
        }

        switch FastPathRouter.route(cleaned) {
        case .execute(let actions):
            if !actions.isEmpty {
                NSLog("[Plan] Fast-path (no LLM): %@", actions.map(\.description).joined(separator: ", "))
            } else {
                NSLog("[Plan] Fast-path: dropped noise without model")
            }
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: actions)
            RustPipeline.shadowCompare(cleaned: cleaned, swiftActions: actions,
                                       swiftBranch: actions.isEmpty ? "drop" : "fastpath",
                                       requestID: requestID)
            return actions
        case .needsModel:
            NSLog("[Plan] Fast-path miss — full pipeline")
            break
        }

        // 3. Strict priority router
        // SYSTEM -> INFO -> MEDIA -> AI
        if let actions = ruleBasedPlan(cleaned: cleaned, lower: lower) {
            NSLog("[Plan] Rule-based: %@", actions.map(\.description).joined(separator: ", "))
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: actions)
            RustPipeline.shadowCompare(cleaned: cleaned, swiftActions: actions,
                                       swiftBranch: "rule", requestID: requestID)
            return actions
        }

        // 5. Fallback to Ollama for complex/unrecognised input.
        // Unmatched system-looking commands used to be DROPPED here — that is
        // what turned "open spotify, open whatsapp and also open youtube and
        // in spotify play a song" into "Invalid command skipped" with no
        // explanation. A command the rules could not parse is exactly the case
        // Qwen exists for, and `ollamaFallback` degrades to a spoken aiQuery
        // answer by itself, so this branch can never end in silence.
        let tokenCount = lower.split(separator: " ").count
        if tokenCount < 4 {
            NSLog("[Plan] Short unrecognised input (%d tokens) — treating as AI query without Ollama call", tokenCount)
            let short = [PlannedAction.aiQuery(cleaned)]
            RustPipeline.shadowCompare(cleaned: cleaned, swiftActions: short,
                                       swiftBranch: "ai", requestID: requestID)
            return short
        }

        NSLog("[Intent] AI: fallback")
        NSLog("[Plan] → Routing to Ollama: '%@'", cleaned)
        let qwenPlan = await ollamaFallback(cleaned)
        RustPipeline.shadowCompare(cleaned: cleaned, swiftActions: qwenPlan,
                                   swiftBranch: "qwen", requestID: requestID)
        logPlanEvent(branch: "qwen", text: cleaned, requestID: requestID, actions: qwenPlan)
        return qwenPlan
    }

    /// One JSONL line per routing decision — the RL corpus pairs these with
    /// the model_hit/model_miss lines from IntentModelRouter and the
    /// execute_step lines from AppState runCommand (same request_id).
    private func logPlanEvent(branch: String, text: String, requestID: UUID, actions: [PlannedAction]) {
        IntentRouterLog.shared.append([
            "event": "plan",
            "branch": branch,
            "request_id": requestID.uuidString,
            "text": text,
            "actions": actions.map(\.description),
        ])
    }

    // MARK: - Rule-based planner

    private func ruleBasedPlan(cleaned: String, lower: String) -> [PlannedAction]? {

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
    private func knownWebsiteURL(for target: String) -> String? {
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

        // A sentence that merely CONTAINS "play" and "song" is not a song
        // title. "in spotify, could you play a song for me?" used to become
        // playSong("in spotify, could you a for me?") — every content word is
        // a trigger/filler, so it is a plain "start playing" request.
        if mediaContentTokens(compact).isEmpty {
            NSLog("[Intent] detected: play (no title in '%@')", compact)
            return .mediaControl(.play)
        }

        let songName = cleanSongTitle(extractSongName(normalizedIntent))
        guard !songName.isEmpty else {
            NSLog("[Intent] detected: play (empty title after cleanup)")
            return .mediaControl(.play)
        }
        NSLog("[Intent] detected: play_song → '%@'", songName)
        return .mediaControl(.playSong(songName))
    }

    /// Words that carry no song-title information: the media triggers
    /// themselves, question/politeness filler, and app/context nouns.
    /// Deliberately excludes short words that appear inside real titles
    /// ("of" in "shape of you").
    private static let mediaNonTitleWords: Set<String> = [
        "play", "plays", "playing", "song", "songs", "music", "track", "tracks",
        "playlist", "playlists", "tune", "tunes", "some", "any", "something",
        "anything", "one", "it", "that", "this", "these", "those",
        "a", "an", "the", "in", "on", "to", "at", "for", "me", "us", "my", "your",
        "could", "would", "can", "will", "please", "kindly", "just", "now",
        "again", "aloud", "jarvis", "spotify", "app", "application", "player",
        "like", "want", "wanna", "need", "let", "have", "got", "get", "give",
        "put", "start", "starting", "hear", "listen", "listening", "back",
        "do", "does", "did", "is", "are", "was", "were", "be", "you", "i",
    ]

    /// Content words of the utterance that could name a song.
    private func mediaContentTokens(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased() }
            .filter { !$0.isEmpty }
            .filter { !Self.mediaNonTitleWords.contains($0) }
    }

    /// Strip leading articles/possessives and trailing "on spotify"-style
    /// context so the title sent to Spotify is the name the user spoke.
    private func cleanSongTitle(_ raw: String) -> String {
        var words = raw
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }

        let leadingNoise: Set<String> = ["a", "an", "the", "my", "some", "that", "this", "please"]
        while let first = words.first?.lowercased(), leadingNoise.contains(first) {
            words.removeFirst()
        }

        let trailingNoise: Set<String> = ["spotify", "app", "player", "music", "song", "track", "please"]
        while let last = words.last?.lowercased(), trailingNoise.contains(last) {
            words.removeLast()
            if words.last?.lowercased() == "on" || words.last?.lowercased() == "in" || words.last?.lowercased() == "from" {
                words.removeLast()
            }
        }

        return words.joined(separator: " ")
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
        // Only collapse when the utterance is media control and NOTHING else.
        // Otherwise "open spotify, open whatsapp and play a song" would be
        // reduced to just `play`, silently dropping the app opens.
        let allMedia = actions.allSatisfy { action in
            if case .mediaControl = action { return true }
            return false
        }
        guard allMedia, actions.count > 1 else { return nil }

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
            "increase volume",  "increase the volume",
            "increase sound",   "increase the sound",
            "increase audio",   "increase the audio",
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
            "decrease volume",  "decrease the volume",
            "decrease sound",   "decrease the sound",
            "decrease audio",   "decrease the audio",
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

    // MARK: - Display command parser

    /// Parses brightness, contrast, and resolution commands.
    /// Returns nil if the input doesn't match any display pattern.
    private func parseDisplayCommand(_ lower: String) -> PlannedAction? {

        // ── Brightness set ──────────────────────────────────────────
        let brightnessSetPatterns = [
            "set brightness to ", "brightness to ", "set the brightness to ",
            "set screen brightness to ", "screen brightness to "
        ]
        for pattern in brightnessSetPatterns where lower.hasPrefix(pattern) {
            if let pct = extractPercent(from: lower) {
                NSLog("[Intent] detected: set_brightness(%d%%)", pct)
                return .displayControl(.setBrightness(pct))
            }
        }
        // Handle "set brightness 70" (no "to")
        if lower.hasPrefix("set brightness ") || lower.hasPrefix("brightness ") {
            if let pct = extractPercent(from: lower), pct >= 0, pct <= 100 {
                return .displayControl(.setBrightness(pct))
            }
        }

        // ── Brightness increase ──────────────────────────────────────
        let brightnessUpPatterns = [
            "increase brightness", "increase the brightness",
            "brightness up", "brighter", "make it brighter",
            "make the screen brighter", "turn up brightness", "turn up the brightness",
            "raise brightness", "raise the brightness",
            "dim up", "screen brighter"
        ]
        if brightnessUpPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            NSLog("[Intent] detected: brightness_up(%d%%)", amount)
            return .displayControl(.increaseBrightness(by: amount))
        }

        // ── Brightness decrease ──────────────────────────────────────
        let brightnessDownPatterns = [
            "decrease brightness", "decrease the brightness",
            "brightness down", "dimmer", "dim the screen",
            "make it dimmer", "make the screen dimmer",
            "turn down brightness", "turn down the brightness",
            "lower brightness", "lower the brightness",
            "reduce brightness", "reduce the brightness",
            "darker", "screen darker"
        ]
        if brightnessDownPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            NSLog("[Intent] detected: brightness_down(%d%%)", amount)
            return .displayControl(.decreaseBrightness(by: amount))
        }

        // ── Contrast set ────────────────────────────────────────────
        let contrastSetPatterns = [
            "set contrast to ", "contrast to ", "set the contrast to "
        ]
        for pattern in contrastSetPatterns where lower.hasPrefix(pattern) {
            if let pct = extractPercent(from: lower) {
                NSLog("[Intent] detected: set_contrast(%d%%)", pct)
                return .displayControl(.setContrast(pct))
            }
        }

        // ── Contrast increase ────────────────────────────────────────
        let contrastUpPatterns = ["increase contrast", "contrast up", "more contrast"]
        if contrastUpPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            return .displayControl(.increaseContrast(by: amount))
        }

        // ── Contrast decrease ────────────────────────────────────────
        let contrastDownPatterns = ["decrease contrast", "contrast down", "less contrast", "reduce contrast"]
        if contrastDownPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            return .displayControl(.decreaseContrast(by: amount))
        }

        // ── List resolutions ─────────────────────────────────────────
        let listResPatterns = ["list resolutions", "list the resolutions",
                               "show resolutions", "show the resolutions",
                               "available resolutions",
                               "what resolutions", "list display modes", "show display modes"]
        if listResPatterns.contains(where: { lower.contains($0) }) {
            return .displayControl(.listResolutions)
        }

        // ── Set resolution by shorthand ("4k", "1080p", "1440p") ────
        let resolutionTriggers = ["resolution to ", "switch to ", "change to ",
                                  "set display to ", "change resolution to ", "switch resolution to "]
        for trigger in resolutionTriggers {
            if lower.contains(trigger) {
                if let range = lower.range(of: trigger),
                   let resolved = DisplayModeController.resolveShorthand(String(lower[range.upperBound...])) {
                    NSLog("[Intent] detected: set_resolution(%d×%d)", resolved.width, resolved.height)
                    return .displayControl(.setResolution(width: resolved.width, height: resolved.height, refreshRate: nil))
                }
                if let parsed = parseExplicitResolution(from: lower) {
                    return .displayControl(.setResolution(width: parsed.width, height: parsed.height, refreshRate: parsed.refresh))
                }
            }
        }
        if lower.contains("resolution") {
            if let parsed = parseExplicitResolution(from: lower) {
                return .displayControl(.setResolution(width: parsed.width, height: parsed.height, refreshRate: parsed.refresh))
            }
        }

        return nil
    }

    /// Parses explicit resolution strings like "1920x1080", "1920 by 1080",
    /// optionally followed by "at 60hz" or "60 hertz".
    private func parseExplicitResolution(from lower: String) -> (width: Int, height: Int, refresh: Double?)? {
        let pattern = #"(\d{3,4})\s*(?:x|by)\s*(\d{3,4})(?:\s*(?:@|at)\s*(\d+)\s*(?:hz|hertz))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            guard let range = Range(match.range(at: i), in: lower) else { return nil }
            return String(lower[range])
        }
        guard let w = group(1).flatMap(Int.init),
              let h = group(2).flatMap(Int.init) else { return nil }
        let hz = group(3).flatMap(Double.init)
        return (width: w, height: h, refresh: hz)
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
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
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
    private func parseFileQuery(_ lower: String) -> PlannedAction? {
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
    private func wantsFolders(_ text: String) -> Bool {
        containsAnyWord(text, words: ["folders", "subfolder", "subfolders", "directories", "directory"])
            || text.contains("how many folder ")
            || text.contains("number of folder ")
    }

    /// Extensions the user actually names out loud.
    private func detectFileExtension(_ text: String) -> String {
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
    private func detectFolderName(_ text: String) -> String? {
        let ordered = ["downloads", "download", "documents", "docs", "desktop",
                       "pictures", "photos", "images", "movies", "videos", "music"]
        for word in ordered where text.contains(word) {
            return word
        }
        if text.contains("home folder") || text.contains("home directory") { return "home" }
        return nil
    }

    // MARK: - Conjunction splitter

    private func splitByConjunction(_ lower: String) -> [String] {
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
    private func dropLeadingConnectors(_ text: String) -> String {
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

    private static let actionVerbTokens: Set<String> = [
        "open", "close", "launch", "quit", "play", "pause", "resume", "stop",
        "next", "previous", "prev", "skip", "search", "google", "find", "list",
        "count", "show", "tell", "create", "run", "start", "increase", "decrease",
        "set", "turn", "mute", "unmute", "make", "check", "calculate",
    ]

    private func isActionVerbToken(_ token: String) -> Bool {
        Self.actionVerbTokens.contains(
            token.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        )
    }

    /// How many action verbs the utterance contains, counting repeats:
    /// "open spotify, open whatsapp and play a song" → 3 clauses.
    private func actionVerbCount(_ text: String) -> Int {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .filter { isActionVerbToken(String($0)) }
            .count
    }

    private func startsWithActionVerb(_ text: String) -> Bool {
        guard let first = text.split(separator: " ").first else { return false }
        return isActionVerbToken(String(first))
    }

    /// True when any token of the part is an action verb — position-free, so
    /// "in spotify play a song" counts as an action.
    private func hasActionVerb(_ text: String) -> Bool {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .contains { isActionVerbToken(String($0)) }
    }

    // MARK: - Helpers

    /// Local hardware-state reads that must NEVER reach Ollama.
    /// "What is the current brightness level" → systemInfo read answered
    /// from DisplayController, same as volume. Without this, Qwen
    /// hallucinates code for a question only the OS can answer.
    private func answerLocalStateQuery(cleaned: String, lower: String) -> [PlannedAction]? {
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
        AppAliasResolver.resolveSpoken(name)
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
        // X (user words) + the tools prompt in, Y (executor JSON) out. The
        // input continues the prompt's own few-shot pattern.
        let prompt = JarvisToolsPrompt.text + "\nCommand: \(cleaned)\n"
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

        // Strict schema: a recognized type with a missing/invalid payload
        // (e.g. `system_info` kind "weather") invalidates the whole plan —
        // the caller then degrades to a single ai_query instead of executing
        // a silently wrong action. Unknown types are skipped; an output with
        // nothing usable still returns nil.
        var actions: [PlannedAction] = []
        for obj in array {
            guard let type = obj["type"] as? String else { return nil }
            switch type {
            case "open_app":
                guard let app = obj["app"] as? String else { return nil }
                actions.append(.openApp(app))
            case "close_app":
                guard let app = obj["app"] as? String else { return nil }
                actions.append(.closeApp(app))
            case "open_url":
                guard let url = obj["url"] as? String else { return nil }
                actions.append(.openURL(url))
            case "search_web":
                guard let q = obj["query"] as? String else { return nil }
                let engine = (obj["engine"] as? String) ?? "Google"
                actions.append(.searchWeb(engine: engine, query: q))
            case "open_folder":
                guard let p = obj["path"] as? String else { return nil }
                actions.append(.openFolder(p))
            case "set_volume":
                guard let level = clampedPercent(obj["level"]) else { return nil }
                actions.append(.volumeControl(.setLevel(level)))
            case "mute":
                actions.append(.volumeControl(.mute))
            case "set_brightness":
                guard let level = clampedPercent(obj["level"]) else { return nil }
                actions.append(.displayControl(.setBrightness(level)))
            case "system_info":
                guard let kind = obj["kind"] as? String,
                      let info = SystemInfoAction(toolKind: kind) else { return nil }
                actions.append(.systemInfo(info))
            case "media":
                guard let spec = obj["action"] as? String,
                      let media = MediaAction(spec: spec) else { return nil }
                actions.append(.mediaControl(media))
            case "ai_query":
                guard let q = obj["query"] as? String else { return nil }
                actions.append(.aiQuery(q))
            default:
                continue
            }
        }
        return actions.isEmpty ? nil : actions
    }

    /// JSON numbers arrive as NSNumber — accept Int/Double/numeric String and
    /// clamp to a valid 0-100 percent.
    private func clampedPercent(_ value: Any?) -> Int? {
        let raw: Double?
        if let i = value as? Int {
            raw = Double(i)
        } else if let d = value as? Double {
            raw = d
        } else if let s = value as? String {
            raw = Double(s)
        } else {
            raw = nil
        }
        guard let n = raw else { return nil }
        return min(100, max(0, Int(n.rounded())))
    }
}
