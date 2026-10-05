import Foundation

/// Single home for `.env` file discovery + parsing. Replaces two
/// copy-pasted parsers (DBManager, ActionExecutor) that used different
/// candidate paths and subtly different parsing (untrimmed keys in one).
/// Semantics: first file with any valid `KEY=value` lines wins.
enum DotEnvLoader {
    /// Parse every candidate location; return the first non-empty result.
    /// `extraSearchDirs` lets callers add their own ancestry walk
    /// (e.g. `#filePath`-relative source dirs) alongside the standard set.
    static func values(extraSearchDirs: [URL] = []) -> [String: String] {
        for fileURL in candidates(extraSearchDirs: extraSearchDirs) {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let parsed = parse(text)
            if !parsed.isEmpty { return parsed }
        }
        return [:]
    }

    /// Process env overlaid with `.env` values (env wins on conflict).
    static func mergedEnv(extraSearchDirs: [URL] = []) -> [String: String] {
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in values(extraSearchDirs: extraSearchDirs)
        where merged[key]?.isEmpty ?? true {
            merged[key] = value
        }
        return merged
    }

    static func value(for key: String, extraSearchDirs: [URL] = []) -> String? {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
            return env
        }
        let dotEnv = values(extraSearchDirs: extraSearchDirs)
        if let value = dotEnv[key], !value.isEmpty {
            return value
        }
        return nil
    }

    // MARK: - Internals

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = value
        }
        return out
    }

    private static func candidates(extraSearchDirs: [URL]) -> [URL] {
        let fm = Foundation.FileManager.default
        var out: [URL] = []
        var seen = Set<String>()
        func appendUnique(_ url: URL) {
            let normalized = url.standardizedFileURL.path
            if seen.contains(normalized) { return }
            seen.insert(normalized)
            out.append(url)
        }

        // Caller-supplied ancestry walks first (most specific wins): e.g. a
        // source-file-relative .env beats whatever the cwd happens to be.
        for dir in extraSearchDirs {
            var walk = dir
            for _ in 0..<10 {
                appendUnique(walk.appendingPathComponent(".env"))
                let parent = walk.deletingLastPathComponent()
                if parent.path == walk.path { break }
                walk = parent
            }
        }
        // Bundled backend copy (packaged app) + bundle root.
        if let resourcePath = Bundle.main.resourcePath {
            appendUnique(URL(fileURLWithPath: resourcePath).appendingPathComponent("backend/.env"))
            appendUnique(URL(fileURLWithPath: resourcePath).appendingPathComponent(".env"))
        }
        // Ancestors of the running executable (dev/SPM layouts).
        if let executableURL = Bundle.main.executableURL {
            var dir = executableURL.deletingLastPathComponent()
            for _ in 0..<4 {
                appendUnique(dir.appendingPathComponent(".env"))
                dir = dir.deletingLastPathComponent()
            }
        }
        // Ancestors of the current working directory.
        var cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
        for _ in 0..<10 {
            appendUnique(cwdURL.appendingPathComponent(".env"))
            let parent = cwdURL.deletingLastPathComponent()
            if parent.path == cwdURL.path { break }
            cwdURL = parent
        }
        return out
    }
}
