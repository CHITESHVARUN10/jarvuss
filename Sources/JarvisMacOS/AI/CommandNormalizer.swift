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
    case searchWeb(String)       // search query — executor opens search URL
    case openFolder(String)
    case createFile(String)
    case createFolder(String)
    case aiQuery(String)         // LLM answer query

    var description: String {
        switch self {
        case .openApp(let n):      return "openApp(\(n))"
        case .closeApp(let n):     return "closeApp(\(n))"
        case .openURL(let u):      return "openURL(\(u))"
        case .searchWeb(let q):    return "searchWeb(\(q))"
        case .openFolder(let p):   return "openFolder(\(p))"
        case .createFile(let n):   return "createFile(\(n))"
        case .createFolder(let n): return "createFolder(\(n))"
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
        case .searchWeb(let q):    return "ai: search for \(q)"
        case .openFolder(let p):   return "open folder \(p)"
        case .createFile(let n):   return "create file \(n)"
        case .createFolder(let n): return "create folder \(n)"
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

    init(model: String = "qwen2.5-coder:1.5b-base") {
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
        if let (engine, query) = parseSearch(lower) {
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let base: String = engine == "YouTube"
                ? "https://www.youtube.com/results?search_query="
                : "https://www.google.com/search?q="
            return .multi([.searchWeb(query), .openURL(base + encoded)], raw: stripped)
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
                return .single(.openApp(AppAliasResolver.resolve(target)), raw: stripped)
            }
        }

        // ── App close ─────────────────────────────────────────────
        if lower.hasPrefix("close ") {
            let target = String(stripped.dropFirst("close ".count))
                           .trimmingCharacters(in: .whitespaces)
            return .single(.closeApp(AppAliasResolver.resolve(target)), raw: stripped)
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
                actions.append(.closeApp(AppAliasResolver.resolve(tTarget)))
            } else {
                actions.append(.openApp(AppAliasResolver.resolve(tTarget)))
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
        let resolved = AppAliasResolver.resolve(browser)
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
            (#"search google for (.+)"#,  "Google"),
            (#"google (.+)"#,             "Google"),
            (#"search for (.+)"#,         "Google"),
            (#"search youtube for (.+)"#, "YouTube"),
        ]
        for entry in patterns {
            guard let regex = try? NSRegularExpression(pattern: entry.pattern),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let qRange = Range(match.range(at: 1), in: lower) else { continue }
            let query = String(lower[qRange]).trimmingCharacters(in: .whitespaces)
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
        let prompt = """
        You are a command normalizer for a macOS voice assistant.
        Convert the user input into a JSON object with this exact shape:

        {
          "priority": "high" | "normal" | "low",
          "actions": [
            { "type": "open_app",      "value": "<app name>" },
            { "type": "close_app",     "value": "<app name>" },
            { "type": "open_url",      "value": "<url>" },
            { "type": "search_web",    "value": "<query>" },
            { "type": "open_folder",   "value": "<folder name>" },
            { "type": "create_file",   "value": "<filename>" },
            { "type": "create_folder", "value": "<folder name>" },
            { "type": "ai_query",      "value": "<query>" }
          ]
        }

        Rules:
        - NEVER use chrome unless explicitly requested by the user.
        - Use open_url for web destinations; the system default browser will open it.
        - If you are not sure, return a single ai_query action.
        - Output ONLY the JSON object. No explanation.

        User: \(cleaned)
        """

        let response = await ollamaClient.generate(prompt: prompt)

        // Try to parse Ollama JSON response
        if let parsed = parseOllamaJSON(response, raw: raw) {
            return parsed
        }

        // Ollama failed or returned garbage — fall back to AI query string
        return .single(.aiQuery(cleaned), raw: raw)
    }

    private func parseOllamaJSON(_ raw: String, raw input: String) -> NormalizedCommand? {
        // Extract JSON object from response (may contain preamble text)
        guard let start = raw.firstIndex(of: "{"),
              let end   = raw.lastIndex(of: "}") else { return nil }
        let jsonStr = String(raw[start...end])

        guard let data  = jsonStr.data(using: .utf8),
              let obj   = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acts  = obj["actions"] as? [[String: Any]] else { return nil }

        let priorityStr = obj["priority"] as? String ?? "normal"
        let priority: NormalizedPriority = {
            switch priorityStr {
            case "high": return .high
            case "low":  return .low
            default:     return .normal
            }
        }()

        var actions: [CommandAction] = []
        for act in acts {
            guard let type  = act["type"]  as? String,
                  let value = act["value"] as? String else { continue }
            switch type {
            case "open_app":      actions.append(.openApp(AppAliasResolver.resolve(value)))
            case "close_app":     actions.append(.closeApp(AppAliasResolver.resolve(value)))
            case "open_url":      actions.append(.openURL(value))
            case "search_web":    actions.append(.searchWeb(value))
            case "open_folder":   actions.append(.openFolder(value))
            case "create_file":   actions.append(.createFile(value))
            case "create_folder": actions.append(.createFolder(value))
            case "ai_query":      actions.append(.aiQuery(value))
            default: break
            }
        }

        guard !actions.isEmpty else { return nil }
        return NormalizedCommand(
            priority: priority, actions: actions,
            isAIQuery: actions.allSatisfy(\.isAI),
            rawText: input,
            isBlocked: false, blockedReason: nil
        )
    }
}

// MARK: - Bridge: CommandAction → PlannedAction

extension CommandAction {
    /// Converts to PlannedAction so AppState can pass multi-action
    /// NormalizedCommands directly to ActionExecutor without coupling layers.
    func toPlannedAction() -> PlannedAction {
        switch self {
        case .openApp(let n):      return .openApp(n)
        case .closeApp(let n):     return .closeApp(n)
        case .openURL(let u):      return .openURL(u)
        case .searchWeb(let q):    return .searchWeb(engine: "Google", query: q)
        case .openFolder(let p):   return .openFolder(p)
        case .createFile(let n):   return .createFile(n)
        case .createFolder(let n): return .createFolder(n)
        case .aiQuery(let q):      return .aiQuery(q)
        }
    }
}