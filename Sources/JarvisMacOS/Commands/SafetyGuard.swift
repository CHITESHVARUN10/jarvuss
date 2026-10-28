import Foundation

// MARK: - Safety result

enum SafetyVerdict {
    case allowed
    /// Action is blocked. `reason` is shown in the UI.
    case blocked(reason: String)
    /// Future: install preview — NOT executed, only shown.
    case installPreview(command: String, source: String)
}

// MARK: - SafetyGuard

enum SafetyGuard {

    /// The Rust core owns the safety policy in both routing modes. The Swift
    /// adapter only translates app-specific action types (including fileQuery).
    static func validate(rawCommand command: String) -> SafetyVerdict {
        RustPipeline.map(coreCheckSafety(raw: command))
    }

    /// Validate a single PlannedAction before it executes.
    static func validate(action: PlannedAction) -> SafetyVerdict {
        switch action {
        case .openApp(let name):
            return checkText(name)
        case .closeApp(let name):
            return checkText(name)
        case .systemInfo:
            return .allowed
        case .openURL(let url):
            return checkURL(url)
        case .openURLInBrowser(let url, _):
            return checkURL(url)
        case .searchWeb(let engine, let query):
            _ = engine
            return checkText(query)
        case .openFolder(let path):
            return checkPath(path)
        case .openLatestFile(let folder):
            return checkPath(folder)
        case .searchFiles, .fileResult, .openSettings:
            // Read-only metadata predicates, result-bound document actions,
            // and allowlisted settings links; no shell or arbitrary URLs.
            return .allowed
        case .fileQuery:
            // Folder names resolve through a fixed whitelist (Downloads,
            // Documents, Desktop, Pictures, Movies, Music) and the executor
            // uses FileManager, never a shell — nothing to sanitize.
            return .allowed
        case .mediaControl:
            return .allowed   // media controls are inherently safe
        case .volumeControl:
            return .allowed   // volume controls are inherently safe
        case .createFile(let name):
            return checkPath(name)
        case .createFolder(let name):
            return checkPath(name)
        case .aiQuery(let query):
            return checkText(query)
        case .installPreview(let pkg, let source):
            return .installPreview(command: "install \(pkg)", source: source)
        case .displayControl:
            // Brightness/contrast floors are enforced in the shared display controllers.
            return .allowed
        }
    }

    // MARK: - Internal checks

    private static func checkText(_ text: String) -> SafetyVerdict {
        validate(rawCommand: text)
    }

    private static func checkPath(_ path: String) -> SafetyVerdict {
        validate(rawCommand: path)
    }

    private static func checkURL(_ url: String) -> SafetyVerdict {
        if let parsed = URL(string: url), parsed.isFileURL {
            return checkPath(parsed.standardizedFileURL.resolvingSymlinksInPath().path)
        }
        return .allowed
    }
}
