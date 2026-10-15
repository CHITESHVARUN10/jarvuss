import Foundation

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

    private let ollamaClient: LLMGenerating
    private let intentModelRouter: IntentRouting
    private let intentLog: IntentRouterLog

    init(ollamaClient: LLMGenerating = OllamaClient(),
         intentModelRouter: IntentRouting = IntentModelRouter(),
         intentLog: IntentRouterLog = .shared) {
        self.ollamaClient = ollamaClient
        self.intentModelRouter = intentModelRouter
        self.intentLog = intentLog
    }

    // Thin internal wrappers over the private parsers, used only by tests.
    func splitByConjunctionForTesting(_ text: String) -> [String] { splitByConjunction(text) }
    func mediaCommandForTesting(_ text: String) -> PlannedAction? { parseMediaCommand(text) }
    func fileQueryForTesting(_ text: String) -> PlannedAction? { parseFileQuery(text) }
    func rulePlanForTesting(_ text: String) -> [PlannedAction]? {
        ruleBasedPlan(cleaned: text, lower: text.lowercased())
    }

    // ── Public entry point ──────────────────────────────────────────

    func plan(from raw: String, requestID: UUID = UUID()) async -> [PlannedAction] {
        guard !Task.isCancelled else { return [] }
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

        // 2. File-exploration questions ("how many folders do I have") are
        // answered from the filesystem by pure Swift rules. They must never
        // reach the LLM, and the Rust core has no fileQuery action yet — so
        // this runs in BOTH pipeline modes, before any router. Without it,
        // the Rust cut-over flag sent every file question to Qwen, and with
        // Ollama down the transport error surfaced as the "answer".
        if let files = parseFileQuery(lower) {
            NSLog("[Plan] File query (local): %@", files.description)
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: [files])
            RustPipeline.shadowCompare(cleaned: cleaned, swiftActions: [files],
                                       swiftBranch: "rule", requestID: requestID)
            return [files]
        }

        // Unambiguous single actions never wait for model admission, loading,
        // or a backend timeout. Compound/ambiguous input still uses the model.
        if actionVerbCount(cleaned) <= 1, splitByConjunction(cleaned).count <= 1,
           !QuickInfoMatcher.looksCompound(lower),
           case .execute(let actions) = FastPathRouter.route(cleaned),
           !actions.isEmpty,
           !actions.contains(where: { if case .aiQuery = $0 { return true }; return false }) {
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: actions)
            return actions
        }

        // 2a. Learned intent model handles ambiguous and compound requests.
        // It understands phrasing
        // and ordered multi-step plans the regexes cannot. On ANY miss
        // (disabled, backend down, low confidence, unmappable JSON) it logs
        // to intent_router.jsonl for RL and returns nil — the regex pipeline
        // below (FastPathRouter → rules → Qwen) stays as the safety net.
        if let learned = await intentModelRouter.route(cleaned, requestID: requestID) {
            guard !Task.isCancelled else { return [] }
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
                    intentLog.append([
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

        guard !Task.isCancelled else { return [] }

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
                // HTTP inference has one cancellable owner in both modes.
                let actions = await ollamaFallback(cleaned)
                guard !Task.isCancelled else { return [] }
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
        intentLog.append([
            "event": "plan",
            "branch": branch,
            "request_id": requestID.uuidString,
            "text": text,
            "actions": actions.map(\.description),
        ])
    }

    // MARK: - Rule-based planner

    // MARK: - Ollama fallback (complex / unrecognised input only)

    private func ollamaFallback(_ cleaned: String) async -> [PlannedAction] {
        // X (user words) + the tools prompt in, Y (executor JSON) out. The
        // input continues the prompt's own few-shot pattern.
        let prompt = JarvisToolsPrompt.text + "\nCommand: \(cleaned)\n"
        let response = await ollamaClient.generate(prompt: prompt)
        guard !Task.isCancelled else { return [] }

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
