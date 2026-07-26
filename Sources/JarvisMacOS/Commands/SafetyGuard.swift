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

    // ── Protected path prefixes ──────────────────────────────────────
    private static let protectedPaths: [String] = [
        "/System", "/Library", "/private", "/usr", "/bin",
        "/sbin", "/etc", "/var", "/root", "/Applications/Utilities"
    ]

    // ── Destructive keywords (regex word-boundary matched) ────────────
    private static let destructivePattern =
        "\\b(delete|remove|rm|format|wipe|erase|overwrite|shred|truncate)\\b"

    // ── Package-manager / install keywords ───────────────────────────
    private static let installPattern =
        "\\b(install|brew install|npm install|pip install|gem install|yarn add|apt-get|yum|dnf)\\b"

    // ── sudo – always blocked ─────────────────────────────────────────
    private static let sudoPattern = "\\bsudo\\b"

    // MARK: - Public API

    /// Validate a raw text command before it enters the pipeline.
    static func validate(rawCommand command: String) -> SafetyVerdict {
        let lower = command.lowercased()
        return runChecks(on: lower, original: command)
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
        case .searchWeb(let engine, let query):
            _ = engine
            return checkText(query)
        case .openFolder(let path):
            return checkPath(path)
        case .openLatestFile(let folder):
            return checkPath(folder)
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
        }
    }

    // MARK: - Internal checks

    private static func checkText(_ text: String) -> SafetyVerdict {
        return runChecks(on: text.lowercased(), original: text)
    }

    private static func checkPath(_ path: String) -> SafetyVerdict {
        let lower = path.lowercased()
        // Path-specific protected-prefix check
        for protected in protectedPaths {
            if lower.hasPrefix(protected.lowercased()) {
                return .blocked(reason: "Access to '\(protected)' is not allowed.")
            }
        }
        return runChecks(on: lower, original: path)
    }

    private static func checkURL(_ url: String) -> SafetyVerdict {
        // Reject file:// pointing at protected paths
        if url.lowercased().hasPrefix("file://") {
            let path = url.dropFirst("file://".count)
            return checkPath(String(path))
        }
        return .allowed
    }

    private static func runChecks(on lower: String, original: String) -> SafetyVerdict {
        // 1. sudo — permanent block
        if lower.range(of: sudoPattern, options: .regularExpression) != nil {
            return .blocked(reason: "sudo commands are permanently disabled for safety.")
        }

        // 2. Destructive operations
        if lower.range(of: destructivePattern, options: .regularExpression) != nil {
            return .blocked(reason: "Destructive operations (delete/remove/format) are disabled.")
        }

        // 3. Install commands — future-safe preview only
        if lower.range(of: installPattern, options: .regularExpression) != nil {
            let pkg = extractPackageName(from: lower) ?? original
            return .installPreview(
                command: "install \(pkg)",
                source: "Requires face auth + confirmation (not yet active)"
            )
        }

        // 4. Protected system paths
        for protected in protectedPaths {
            if lower.contains(protected.lowercased()) {
                return .blocked(reason: "Access to '\(protected)' is restricted.")
            }
        }

        return .allowed
    }

    private static func extractPackageName(from text: String) -> String? {
        let patterns = ["brew install ", "npm install ", "pip install ", "install "]
        for pattern in patterns {
            if let range = text.range(of: pattern) {
                let rest = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .whitespaces)
                    .first ?? ""
                if !rest.isEmpty { return rest }
            }
        }
        return nil
    }
}
