import Foundation

// MARK: - Output structures

/// Priority of a normalized command, matching CommandQueueManager's priority system.
/// NOTE: This mirrors CommandPriority from CommandQueueManager. We keep them separate
/// to avoid coupling the AI layer to the App layer.
enum NormalizedPriority {
    case high    // time/date, stop/cancel
    case normal  // open app, browser
    case low     // background tasks
}

/// A single parsed action from the normalized input.
enum CommandAction: Equatable, CustomStringConvertible {
    case openApp(String)
    case closeApp(String)
    case openURL(String)         // uses system default browser
    case searchWeb(engine: String, query: String)  // search query + engine
    case openFolder(String)
    case createFile(String)
    case createFolder(String)
    case media(String)           // Spotify playback: play|pause|next|prev|liked_songs|play_song:<n>|play_playlist:<n>
    case volume(String)          // set:<0-100> | mute
    case display(String)         // brightness:<0-100>
    case systemInfo(String)      // time|date|battery|wifi|bluetooth|volume|brightness
    case aiQuery(String)         // LLM answer query

    var description: String {
        switch self {
        case .openApp(let n):      return "openApp(\(n))"
        case .closeApp(let n):     return "closeApp(\(n))"
        case .openURL(let u):      return "openURL(\(u))"
        case .searchWeb(let e, let q): return "searchWeb(\(e): \(q))"
        case .openFolder(let p):   return "openFolder(\(p))"
        case .createFile(let n):   return "createFile(\(n))"
        case .createFolder(let n): return "createFolder(\(n))"
        case .media(let m):       return "media(\(m))"
        case .volume(let v):      return "volume(\(v))"
        case .display(let d):     return "display(\(d))"
        case .systemInfo(let k):  return "systemInfo(\(k))"
        case .aiQuery(let q):      return "aiQuery(\(q))"
        }
    }
}

/// The structured result that CommandNormalizer produces.
struct NormalizedCommand {
    let priority: NormalizedPriority
    let actions: [CommandAction]
    let isAIQuery: Bool
    let rawText: String
    /// True when the command was rejected by the safety filter.
    let isBlocked: Bool
    let blockedReason: String?

    // MARK: Backward-compatible string representation
    /// Returns a legacy string for use with CommandParser / the old pipeline.
    func toLegacyString() -> String {
        guard !isBlocked else { return "ai: [blocked] \(blockedReason ?? "")" }
        guard let first = actions.first else { return "ai: \(rawText)" }
        switch first {
        case .openApp(let n):      return "open \(n)"
        case .closeApp(let n):     return "close \(n)"
        case .openURL(let u):      return "open \(u)"
        case .searchWeb(_, let q): return "searchweb: \(q)"
        case .openFolder(let p):   return "open folder \(p)"
        case .createFile(let n):   return "create file \(n)"
        case .createFolder(let n): return "create folder \(n)"
        case .media(let m):       return "media \(m)"
        case .volume(let v):      return "volume \(v)"
        case .display(let d):     return "display \(d)"
        case .systemInfo(let k):  return "info \(k)"
        case .aiQuery(let q):      return "ai: \(q)"
        }
    }

    // MARK: Factory

    static func blocked(reason: String, raw: String) -> NormalizedCommand {
        NormalizedCommand(priority: .high, actions: [],
                          isAIQuery: false, rawText: raw,
                          isBlocked: true, blockedReason: reason)
    }

    static func single(_ action: CommandAction,
                       priority: NormalizedPriority = .normal,
                       raw: String) -> NormalizedCommand {
        NormalizedCommand(priority: priority, actions: [action],
                          isAIQuery: action.isAI, rawText: raw,
                          isBlocked: false, blockedReason: nil)
    }

    static func multi(_ actions: [CommandAction],
                      priority: NormalizedPriority = .normal,
                      raw: String) -> NormalizedCommand {
        NormalizedCommand(priority: priority, actions: actions,
                          isAIQuery: false, rawText: raw,
                          isBlocked: false, blockedReason: nil)
    }
}

private extension CommandAction {
    var isAI: Bool {
        if case .aiQuery = self { return true }
        return false
    }
}

// MARK: - CommandNormalizer

/// Converts raw voice/text input into a structured `NormalizedCommand`.
///
/// Processing order (fastest → slowest):
///   1. Safety filter — blocks destructive/sudo/install commands
///   2. Rule-based fast path — handles the vast majority of commands locally
///   3. Ollama fallback — only for complex / unrecognised input
///
/// The legacy `normalize(_ raw:) -> String` is preserved as an adapter.
final class CommandNormalizer {

    private let ollamaClient: OllamaClient

    init(model: String = JarvisModel.name) {
        ollamaClient = OllamaClient(model: model)
    }

    // MARK: - Primary API (new, structured)

    func normalizeStructured(_ rawInput: String) async -> NormalizedCommand {
        let stripped = stripWakeWord(rawInput)
        let lower    = stripped.lowercased()
                               .trimmingCharacters(in: .whitespacesAndNewlines)

        // ── 1. Safety filter ─────────────────────────────────────────
        if let reason = safetyBlock(lower) {
            return .blocked(reason: reason, raw: rawInput)
        }

        // ── 2. Rule-based fast path ───────────────────────────────────
        if let result = ruleBased(stripped: stripped, lower: lower) {
            return result
        }

        // ── 3. Ollama fallback (complex / unrecognised) ───────────────
        return await ollamaFallback(stripped, raw: rawInput)
    }

    // MARK: - Legacy adapter (backward compatibility)

    /// Returns a plain string command for the existing CommandParser pipeline.
    func normalize(_ rawInput: String) async -> String {
        let result = await normalizeStructured(rawInput)
        return result.toLegacyString()
    }

    // MARK: - Safety filter

    private let _destructive = [
        "delete", "remove", "rm ", "rm\t", "format", "wipe", "erase",
        "overwrite", "shred", "truncate", "mkfs", "fdisk"
    ]
    private let _elevated = ["sudo ", "su -", "su root", "runas"]
    private let _install  = ["brew install", "npm install", "pip install",
                              "apt install", "gem install", "cargo add",
                              "yarn add", "pod install"]
    private let _sysPaths = ["/system", "/library", "/private", "/usr/",
                              "/bin/", "/sbin/", "/etc/", "/var/", "/root"]

    private func safetyBlock(_ lower: String) -> String? {
        for kw in _destructive  where lower.contains(kw) { return "destructive op '\(kw)'" }
        for kw in _elevated     where lower.contains(kw) { return "elevated privilege '\(kw)'" }
        for kw in _install      where lower.contains(kw) { return "install command '\(kw)'" }
        for kw in _sysPaths     where lower.contains(kw) { return "system path '\(kw)'" }
        return nil
    }

    // MARK: - Rule-based parser

    private func ruleBased(stripped: String, lower: String) -> NormalizedCommand? {

        // ── Stop / cancel (HIGH) ──────────────────────────────────
        if lower == "stop" || lower == "cancel" || lower == "abort" || lower == "stop that" {
            return .single(.aiQuery("stop"), priority: .high, raw: stripped)
        }

        // ── Multi-app conjunction ("open chrome and youtube") ──────
        if let multi = parseConjunction(stripped, lower: lower) {
            return multi
        }

        // ── "open X in chrome/brave/safari/firefox" ────────────────
        if let (url, browser) = parseExplicitBrowser(lower) {
            return .multi([.openApp(browser), .openURL(url)], raw: stripped)
        }

        // ── Browser URL shortcuts (system default — no hardcoded browser) ──
        let urlShortcuts: [(String, String)] = [
            ("youtube", "https://www.youtube.com"),
            ("netflix", "https://www.netflix.com"),
            ("github.com", "https://github.com"),
        ]
        for (kw, url) in urlShortcuts {
            if lower.hasPrefix("open \(kw)") || lower == kw {
                return .single(.openURL(url), raw: stripped)
            }
        }
        if (lower.hasPrefix("open google") || lower == "google") && !lower.contains("search") {
            return .single(.openURL("https://www.google.com"), raw: stripped)
        }

        // ── Web search ─────────────────────────────────────────────
        // Covers: "search on youtube for X", "search X on/in youtube",
        // "search on the internet for X", "search X in brave", plus
        // trailing Whisper punctuation ("...in youtube.").
        if let (engine, query) = parseSearch(lower) {
            // SINGLE open: the executor opens the engine's results URL from
            // searchWeb (engine-aware) — never return both or the browser
            // opens twice.
            return .single(.searchWeb(engine: engine, query: query), raw: stripped)
        }

        // ── App open ───────────────────────────────────────────────
        for prefix in ["launch ", "start ", "run ", "open "] {
            if lower.hasPrefix(prefix) {
                let target = String(stripped.dropFirst(prefix.count))
                               .trimmingCharacters(in: .whitespaces)
                // "open folder X"
                if prefix == "open " && lower.hasPrefix("open folder ") {
                    let folder = String(stripped.dropFirst("open folder ".count))
                                   .trimmingCharacters(in: .whitespaces)
                    return .single(.openFolder(folder), raw: stripped)
                }
                // Known web destinations without "open X in browser"
                if lower.hasPrefix("open browser") || lower == "open browser" || lower == "browser" {
                    // System default browser — just open default browser app
                    return .single(.openApp("browser"), raw: stripped)
                }
                return .single(.openApp(AppAliasResolver.resolveSpoken(target)), raw: stripped)
            }
        }

        // ── App close ─────────────────────────────────────────────
        if lower.hasPrefix("close ") {
            let target = String(stripped.dropFirst("close ".count))
                           .trimmingCharacters(in: .whitespaces)
            return .single(.closeApp(AppAliasResolver.resolveSpoken(target)), raw: stripped)
        }

        // ── File / folder creation ─────────────────────────────────
        if lower.hasPrefix("create file ") {
            let name = String(stripped.dropFirst("create file ".count))
            return .single(.createFile(name), raw: stripped)
        }
        if lower.hasPrefix("create folder ") {
            let name = String(stripped.dropFirst("create folder ".count))
            return .single(.createFolder(name), raw: stripped)
        }

        // ── High-priority info (handled upstream, but catch here too) ──
        let highTerms = ["what time", "current time", "what day", "what date",
                         "what month", "what year"]
        if highTerms.contains(where: { lower.contains($0) }) {
            return .single(.aiQuery(stripped), priority: .high, raw: stripped)
        }

        // ── AI / explain ───────────────────────────────────────────
        if lower.hasPrefix("explain ") || lower.hasPrefix("what is ") || lower.hasPrefix("who is ") {
            return .single(.aiQuery(stripped), raw: stripped)
        }

        return nil
    }

    // MARK: - Conjunction parser ("open chrome and youtube")

    private func parseConjunction(_ stripped: String, lower: String) -> NormalizedCommand? {
        // Only parse multi-open commands for now
        guard lower.contains(" and ") || lower.contains(", ") else { return nil }
        guard lower.hasPrefix("open ") || lower.hasPrefix("launch ") else { return nil }

        let _ = lower.hasPrefix("open ") ? "open " : "launch "
        // Normalise separators
        var tokens = lower
            .replacingOccurrences(of: ", and ", with: " && ")
            .replacingOccurrences(of: " and ", with: " && ")
            .replacingOccurrences(of: ", ", with: " && ")
            .components(separatedBy: " && ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Re-propagate leading verb to subsequent tokens that lack one
        let verbs = ["open ", "launch ", "close "]
        let firstVerb = verbs.first { tokens[0].hasPrefix($0) }
        if let verb = firstVerb {
            tokens = tokens.map { t in
                verbs.contains(where: { t.hasPrefix($0) }) ? t : verb + t
            }
        }

        guard tokens.count > 1 else { return nil }

        var actions: [CommandAction] = []
        let webShortcuts: [String: String] = [
            "youtube": "https://www.youtube.com",
            "google":  "https://www.google.com",
            "netflix": "https://www.netflix.com",
        ]

        for token in tokens {
            let tLower = token.lowercased()
            var target = token
            for v in verbs {
                if tLower.hasPrefix(v) {
                    target = String(token.dropFirst(v.count))
                    break
                }
            }
            let tTarget = target.lowercased().trimmingCharacters(in: .whitespaces)
            if let url = webShortcuts[tTarget] {
                actions.append(.openURL(url))
            } else if tLower.hasPrefix("close ") {
                actions.append(.closeApp(AppAliasResolver.resolveSpoken(tTarget)))
            } else {
                actions.append(.openApp(AppAliasResolver.resolveSpoken(tTarget)))
            }
        }

        return actions.isEmpty ? nil : .multi(actions, raw: stripped)
    }

    // MARK: - Explicit browser parse ("open youtube in chrome")

    private func parseExplicitBrowser(_ lower: String) -> (url: String, browser: String)? {
        let pattern = #"open (.+) in (chrome|brave|firefox|safari)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let siteRange    = Range(match.range(at: 1), in: lower),
              let browserRange = Range(match.range(at: 2), in: lower) else { return nil }

        let site     = String(lower[siteRange]).trimmingCharacters(in: .whitespaces)
        let browser  = String(lower[browserRange])
        let resolved = AppAliasResolver.resolveSpoken(browser)
        let url      = knownSiteURL(site)
        return (url, resolved)
    }

    private func knownSiteURL(_ site: String) -> String {
        let known: [String: String] = [
            "youtube":  "https://www.youtube.com",
            "google":   "https://www.google.com",
            "spotify":  "https://open.spotify.com",
            "github":   "https://github.com",
            "netflix":  "https://www.netflix.com",
        ]
        return known[site] ?? (site.hasPrefix("http") ? site : "https://\(site)")
    }

    // MARK: - Search parser

    private func parseSearch(_ lower: String) -> (engine: String, query: String)? {
        let patterns: [(pattern: String, engine: String)] = [
            (#"search (?:on )?youtube for (.+)"#, "YouTube"),
            (#"youtube search for (.+)"#,         "YouTube"),
            (#"search google for (.+)"#,          "Google"),
            (#"search (?:on the )?internet for (.+)"#, "Google"),
            (#"google (.+)"#,                     "Google"),
            (#"search for (.+)"#,                 "Google"),
            (#"search youtube for (.+)"#,         "YouTube"),
            (#"search (.+?) on youtube"#,         "YouTube"),
            (#"search (.+?) in youtube"#,         "YouTube"),
            (#"search (.+?) on google"#,          "Google"),
            (#"search (.+?) in google"#,          "Google"),
            (#"search (.+?) in brave"#,           "Google"),
            (#"search (.+?) on brave"#,           "Google"),
        ]
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let qRange = Range(match.range(at: 1), in: lower) else { continue }
            var query = String(lower[qRange]).trimmingCharacters(in: .whitespaces)
            query = query.trimmingCharacters(in: CharacterSet(charactersIn: "?.!."))
                .trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { continue }
            return (entry.engine, query)
        }
        return nil
    }

    // MARK: - Wake word stripper

    private func stripWakeWord(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.hasPrefix("jarvis ") {
            return String(text.dropFirst("jarvis ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Handle "...jarvis..." anywhere — use backward search
        if let range = lower.range(of: "jarvis ", options: .backwards) {
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let idx = text.index(text.startIndex, offsetBy: offset)
            return String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Ollama fallback (complex / unrecognised input only)

    private func ollamaFallback(_ cleaned: String, raw: String) async -> NormalizedCommand {
        // Migration cut-over: Rust owns the HTTP call + parsing (falls back
        // to a single aiQuery on unparseable output, same as Swift).
        if JarvisFlags.useRustPipeline {
            let outcome = await RustPipeline.runBlocking { coreOllamaNormalize(cleaned: cleaned) }
            if outcome.error == nil {
                StatsRecorder.shared.recordLLM(promptChars: Int(outcome.promptChars),
                                               responseChars: Int(outcome.responseChars))
            }
            return RustPipeline.map(outcome, rawText: raw)
        }

        // X (user words) + the single tools prompt in, Y (executor JSON) out.
        // Input continues the prompt's own "Command: …" few-shot pattern.
        let prompt = JarvisToolsPrompt.text + "\nCommand: \(cleaned)\n"

        let response = await ollamaClient.generate(prompt: prompt)

        if let actions = parseToolActions(response), !actions.isEmpty {
            let isAI = actions.allSatisfy(\.isAI)
            return NormalizedCommand(
                priority: .normal,
                actions: actions,
                isAIQuery: isAI,
                rawText: raw,
                isBlocked: false, blockedReason: nil
            )
        }

        // Ollama failed or returned garbage — fall back to AI query string
        return .single(.aiQuery(cleaned), raw: raw)
    }

    /// Parses the tools prompt's JSON array (`[{"type":…}]`, not a wrapped
    /// object) into `CommandAction`s. Strict schema: a recognized type with a
    /// missing/invalid payload invalidates the whole response (caller degrades
    /// to a single aiQuery); unknown types are skipped.
    private func parseToolActions(_ raw: String) -> [CommandAction]? {
        guard let start = raw.firstIndex(of: "["),
              let end   = raw.lastIndex(of: "]") else { return nil }
        let jsonStr = String(raw[start...end])

        guard let data  = jsonStr.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        var actions: [CommandAction] = []
        for obj in array {
            guard let type = obj["type"] as? String else { return nil }
            switch type {
            case "open_app":
                guard let app = obj["app"] as? String else { return nil }
                actions.append(.openApp(AppAliasResolver.resolveSpoken(app)))
            case "close_app":
                guard let app = obj["app"] as? String else { return nil }
                actions.append(.closeApp(AppAliasResolver.resolveSpoken(app)))
            case "open_url":
                guard let url = obj["url"] as? String else { return nil }
                actions.append(.openURL(url))
            case "search_web":
                guard let q = obj["query"] as? String else { return nil }
                actions.append(.searchWeb(engine: (obj["engine"] as? String) ?? "Google", query: q))
            case "open_folder":
                guard let p = obj["path"] as? String else { return nil }
                actions.append(.openFolder(p))
            case "media":
                guard let m = obj["action"] as? String, MediaAction(spec: m) != nil else { return nil }
                actions.append(.media(m))
            case "set_volume":
                guard let level = clampedPercent(obj["level"]) else { return nil }
                actions.append(.volume("set:\(level)"))
            case "mute":
                actions.append(.volume("mute"))
            case "set_brightness":
                guard let level = clampedPercent(obj["level"]) else { return nil }
                actions.append(.display("brightness:\(level)"))
            case "system_info":
                guard let kind = obj["kind"] as? String, SystemInfoAction(toolKind: kind) != nil else {
                    return nil
                }
                actions.append(.systemInfo(kind))
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

// MARK: - Bridge: CommandAction → PlannedAction

extension CommandAction {
    /// Colon media form ("play_song:X") -> the matching MediaAction.
    static func toPlannedMedia(_ raw: String) -> PlannedAction {
        MediaAction(spec: raw).map { .mediaControl($0) } ?? .aiQuery(raw)
    }

    /// Volume spec ("set:<0-100>" | "mute") -> the matching VolumeAction.
    static func toPlannedVolume(_ raw: String) -> PlannedAction {
        if raw == "mute" { return .volumeControl(.mute) }
        if raw == "unmute" { return .volumeControl(.unmute) }
        if raw.hasPrefix("set:"), let level = Int(raw.dropFirst("set:".count)) {
            return .volumeControl(.setLevel(min(100, max(0, level))))
        }
        return .aiQuery(raw)
    }

    /// Display spec ("brightness:<0-100>") -> the matching DisplayAction.
    static func toPlannedDisplay(_ raw: String) -> PlannedAction {
        if raw.hasPrefix("brightness:"), let level = Int(raw.dropFirst("brightness:".count)) {
            return .displayControl(.setBrightness(min(100, max(0, level))))
        }
        return .aiQuery(raw)
    }

    /// Converts to PlannedAction so AppState can pass multi-action
    /// NormalizedCommands directly to ActionExecutor without coupling layers.
    func toPlannedAction() -> PlannedAction {
        switch self {
        case .openApp(let n):      return .openApp(n)
        case .closeApp(let n):     return .closeApp(n)
        case .openURL(let u):      return .openURL(u)
        case .searchWeb(let e, let q): return .searchWeb(engine: e, query: q)
        case .openFolder(let p):   return .openFolder(p)
        case .createFile(let n):   return .createFile(n)
        case .createFolder(let n): return .createFolder(n)
        case .media(let m):       return CommandAction.toPlannedMedia(m)
        case .volume(let v):      return CommandAction.toPlannedVolume(v)
        case .display(let d):     return CommandAction.toPlannedDisplay(d)
        case .systemInfo(let k):  return SystemInfoAction(toolKind: k).map { .systemInfo($0) } ?? .aiQuery(k)
        case .aiQuery(let q):      return .aiQuery(q)
        }
    }
}