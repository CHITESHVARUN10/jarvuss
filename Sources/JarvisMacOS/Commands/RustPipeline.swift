import Foundation

/// Migration flags for the Swift → Rust cut-over. Persisted in UserDefaults
/// so the pipeline can be flipped (and rolled back) without a rebuild.
enum JarvisFlags {
    private static let rustPipelineKey = "jarvis.rust.pipeline"

    /// When ON, the command pipeline delegates rule decisions (validator,
    /// safety, app aliases, fast-path + rules) to the Rust core. Default OFF:
    /// Swift stays the source of truth until shadow parity is verified.
    /// `JARVIS_RUST_PIPELINE=1|0` overrides for tests/A-B runs.
    static var useRustPipeline: Bool {
        get {
            if let env = ProcessInfo.processInfo.environment["JARVIS_RUST_PIPELINE"] {
                return env == "1" || env.lowercased() == "true"
            }
            return UserDefaults.standard.bool(forKey: rustPipelineKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: rustPipelineKey) }
    }
}

/// Swift ↔ Rust bridge for the command pipeline cut-over.
///
/// The generated bindings (`Core*` types, `core*` functions) come from
/// `rust-core` via `scripts/build_rust_core.sh`. This layer is the only place
/// that knows about them — the rest of the app keeps using the Swift models.
enum RustPipeline {

    // MARK: - Action mapping

    static func map(_ actions: [CorePlannedAction]) -> [PlannedAction] {
        actions.compactMap(map)
    }

    static func map(_ action: CorePlannedAction) -> PlannedAction? {
        switch action {
        case .openApp(let name):
            return .openApp(name)
        case .closeApp(let name):
            return .closeApp(name)
        case .systemInfo(let info):
            return .systemInfo(map(info))
        case .openUrl(let url):
            return .openURL(url)
        case .searchWeb(let engine, let query):
            return .searchWeb(engine: engine, query: query)
        case .openFolder(let path):
            return .openFolder(path)
        case .openLatestFile(let folder):
            return .openLatestFile(inFolder: folder)
        case .mediaControl(let action):
            return .mediaControl(map(action))
        case .volumeControl(let action):
            return .volumeControl(map(action))
        case .createFile(let name):
            return .createFile(name)
        case .createFolder(let name):
            return .createFolder(name)
        case .aiQuery(let query):
            return .aiQuery(query)
        case .installPreview(let package, let source):
            return .installPreview(package: package, source: source)
        case .displayControl(let action):
            return .displayControl(map(action))
        }
    }

    static func map(_ action: CoreSystemInfoAction) -> SystemInfoAction {
        switch action {
        case .currentTime:       return .currentTime
        case .currentDate:       return .currentDate
        case .wifiStatus:        return .wifiStatus
        case .bluetoothDevices:  return .bluetoothDevices
        case .batteryStatus:     return .batteryStatus
        case .systemVolume:      return .systemVolume
        case .displayBrightness: return .displayBrightness
        case .displayContrast:   return .displayContrast
        }
    }

    static func map(_ action: CoreMediaAction) -> MediaAction {
        switch action {
        case .play:                 return .play
        case .playSong(let name):   return .playSong(name)
        case .pause:                return .pause
        case .nextTrack:            return .nextTrack
        case .previousTrack:        return .previousTrack
        case .playLikedSongs:       return .playLikedSongs
        case .playPlaylist(let name): return .playPlaylist(name)
        }
    }

    static func map(_ action: CoreVolumeAction) -> VolumeAction {
        switch action {
        case .increase(let by):   return .increase(by: Int(by))
        case .decrease(let by):   return .decrease(by: Int(by))
        case .mute:               return .mute
        case .unmute:             return .unmute
        case .setLevel(let level): return .setLevel(Int(level))
        }
    }

    static func map(_ action: CoreDisplayAction) -> DisplayAction {
        switch action {
        case .setBrightness(let percent):        return .setBrightness(Int(percent))
        case .increaseBrightness(let by):        return .increaseBrightness(by: Int(by))
        case .decreaseBrightness(let by):        return .decreaseBrightness(by: Int(by))
        case .setContrast(let percent):          return .setContrast(Int(percent))
        case .increaseContrast(let by):          return .increaseContrast(by: Int(by))
        case .decreaseContrast(let by):          return .decreaseContrast(by: Int(by))
        case .setResolution(let width, let height, let refreshRate):
            return .setResolution(width: Int(width), height: Int(height), refreshRate: refreshRate)
        case .listResolutions:                   return .listResolutions
        }
    }

    static func map(_ verdict: CoreSafetyVerdict) -> SafetyVerdict {
        switch verdict {
        case .allowed:
            return .allowed
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .installPreview(let command, let source):
            return .installPreview(command: command, source: source)
        }
    }

    // MARK: - Command normalizer mapping (tools prompt)

    static func map(_ action: CoreCommandAction) -> CommandAction {
        switch action {
        case .openApp(let name):      return .openApp(name)
        case .closeApp(let name):     return .closeApp(name)
        case .openUrl(let url):       return .openURL(url)
        case .searchWeb(let engine, let query): return .searchWeb(engine: engine, query: query)
        case .openFolder(let path):   return .openFolder(path)
        case .createFile(let name):   return .createFile(name)
        case .createFolder(let name): return .createFolder(name)
        case .media(let action):      return .media(action)
        case .volume(let action):     return .volume(action)
        case .display(let action):    return .display(action)
        case .systemInfo(let kind):   return .systemInfo(kind)
        case .aiQuery(let query):     return .aiQuery(query)
        }
    }

    static func map(_ command: CoreNormalizedCommand, rawText: String) -> NormalizedCommand {
        let priority: NormalizedPriority
        switch command.priority {
        case .high:   priority = .high
        case .normal: priority = .normal
        case .low:    priority = .low
        }
        return NormalizedCommand(
            priority: priority,
            actions: command.actions.map(map),
            isAIQuery: command.isAiQuery,
            rawText: rawText,
            isBlocked: command.blocked,
            blockedReason: command.blockedReason
        )
    }

    // MARK: - Blocking bridge

    /// Run a blocking Rust call (HTTP, file I/O) off the cooperative pool so
    /// an async caller never stalls a Swift executor thread.
    static func runBlocking<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    // MARK: - Shadow parity

    /// While the flag is OFF, log what the Rust core would decide for the same
    /// post-model input. Purely observational — the Swift result executes.
    /// Lines land in intent_router.jsonl next to the plan/model/execute events,
    /// tied by the same request_id.
    static func shadowCompare(cleaned: String,
                              swiftActions: [PlannedAction],
                              swiftBranch: String,
                              requestID: UUID) {
        guard !JarvisFlags.useRustPipeline else { return }
        let rust = corePlanAfterModel(cleaned: cleaned)
        let rustActions = map(rust.actions)
        let rustBranch = rust.needsOllama ? "ollama" : rust.branch
        let matches = rustBranch == swiftBranch && rustActions == swiftActions
        IntentRouterLog.shared.append([
            "event": "parity",
            "request_id": requestID.uuidString,
            "text": cleaned,
            "swift_branch": swiftBranch,
            "rust_branch": rustBranch,
            "swift_actions": swiftActions.map(\.description).joined(separator: " | "),
            "rust_actions": rustActions.map(\.description).joined(separator: " | "),
            "match": matches ? "true" : "false",
        ])
    }
}
