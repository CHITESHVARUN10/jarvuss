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
        if case .allowed = SafetyGuard.validate(rawCommand: raw), let native = coreNativeCommand(raw: raw), !native.isEmpty {
            let actions = RustPipeline.map(native)
            logPlanEvent(branch: "native", text: raw, requestID: requestID, actions: actions)
            return actions
        }
        if let actions = WorkspaceCommandParser.plan(raw), case .allowed = SafetyGuard.validate(rawCommand: raw) {
            logPlanEvent(branch: "workspace", text: raw, requestID: requestID, actions: actions)
            return actions
        }
        // Filename/content literals must survive legacy wake-word cleanup:
        // a file can legitimately contain "Jarvis", "okay", or "now".
        if let action = LocalSearchParser.route(raw),
           case .allowed = SafetyGuard.validate(rawCommand: raw) {
            logPlanEvent(branch: "native_search", text: raw, requestID: requestID, actions: [action])
            return [action]
        }
        // 1. Strip wake word and trailing noise before anything else
        let cleaned = TranscriptSanitizer.normalizeMisheardTargets(in: stripWakeWord(stripTrailingNoise(raw)))
        let lower   = cleaned.lowercased()
        if let actions = WorkspaceCommandParser.plan(cleaned), case .allowed = SafetyGuard.validate(rawCommand: raw) {
            logPlanEvent(branch: "workspace", text: cleaned, requestID: requestID, actions: actions)
            return actions
        }

        NSLog("[Plan] Input cleaned: '%@'", cleaned)

        // Parse exact volume semantics before legacy wake-word cleaning or
        // Rust local-state rules can discard punctuation or spoken tens.
        if let volume = SystemVolumeParser.route(raw),
           case .allowed = SafetyGuard.validate(rawCommand: raw) {
            logPlanEvent(branch: "rule", text: raw, requestID: requestID, actions: [volume])
            return [volume]
        }

        // Native file search and fixed settings panes must precede generic
        // app/“Bluetooth status” rules, including when Rust routing is enabled.
        if let action = LocalSearchParser.route(cleaned) {
            if case .allowed = SafetyGuard.validate(rawCommand: cleaned) {
                logPlanEvent(branch: "native_search", text: cleaned, requestID: requestID, actions: [action])
                return [action]
            }
        }

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

        if let volume = SystemVolumeParser.route(cleaned) {
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: [volume])
            return [volume]
        }

        if let shuffle = SpotifyShuffleParser.parse(cleaned) {
            let actions = [PlannedAction.mediaControl(shuffle)]
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: actions)
            return actions
        }
        if let name = coreSpotifyPlaylistName(raw: cleaned) {
            let actions = [PlannedAction.mediaControl(.playPlaylist(name))]
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: actions)
            return actions
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
           mediaContentTokens(lower).isEmpty,
           let media = parseMediaCommand(lower), case .mediaControl(.play) = media {
            logPlanEvent(branch: "rule", text: cleaned, requestID: requestID, actions: [media])
            return [media]
        }
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

        let decision = corePlanAfterModel(cleaned: cleaned)
        if decision.needsOllama {
            let actions = await ollamaFallback(cleaned)
            guard !Task.isCancelled else { return [] }
            logPlanEvent(branch: "qwen", text: cleaned, requestID: requestID, actions: actions)
            return actions
        }
        let actions = RustPipeline.map(decision.actions)
        logPlanEvent(branch: decision.branch, text: cleaned, requestID: requestID, actions: actions)
        return actions
    }

    /// One JSONL line per routing decision — the RL corpus pairs these with
    /// the model_hit/model_miss lines from IntentModelRouter and the
    /// execute_step lines from AppState runCommand (same request_id).
    private func logPlanEvent(branch: String, text: String, requestID: UUID, actions: [PlannedAction]) {
        PipelineTrace.current?.event("route_selected", fields: ["branch": branch, "steps": String(actions.count)])
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
        coreParseToolActions(raw: raw).map(RustPipeline.map)
    }
}
