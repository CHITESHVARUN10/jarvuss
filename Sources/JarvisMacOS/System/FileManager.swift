import Foundation

final class JarvisFileManager {
    private let fileManager = Foundation.FileManager.default
    private let protectedPathPrefixes = [
        "/System", "/Library", "/private", "/usr", "/bin", "/sbin", "/etc", "/var"
    ]

    func createFile(named name: String) -> String {
        createFileResult(named: name).message
    }

    /// Structured result: success is decided by the filesystem call, not by
    /// sniffing the message (a file named "error_log.txt" must not read as
    /// a failure).
    func createFileResult(named name: String) -> (message: String, success: Bool) {
        guard isSafeRelativeName(name) else {
            return ("Blocked: file creation in protected or invalid paths is not allowed.", false)
        }

        let targetURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(name)
        if fileManager.fileExists(atPath: targetURL.path) {
            return ("File already exists: \(name)", false)
        }

        let created = fileManager.createFile(atPath: targetURL.path, contents: Data(), attributes: nil)
        return created
            ? ("Created file: \(targetURL.path)", true)
            : ("Failed to create file: \(name)", false)
    }

    func createFolder(named name: String) -> String {
        createFolderResult(named: name).message
    }

    func createFolderResult(named name: String) -> (message: String, success: Bool) {
        guard isSafeRelativeName(name) else {
            return ("Blocked: folder creation in protected or invalid paths is not allowed.", false)
        }

        let targetURL = URL(fileURLWithPath: fileManager.currentDirectoryPath).appendingPathComponent(name)
        do {
            try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
            return ("Created folder: \(targetURL.path)", true)
        } catch {
            return ("Failed to create folder: \(error.localizedDescription)", false)
        }
    }

    func openFolder(named name: String) -> String {
        openFolderResult(named: name).message
    }

    func openFolderResult(named name: String) -> (message: String, success: Bool) {
        guard let targetURL = resolveFolderName(name) else {
            return ("Folder not found: \(name)", false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [targetURL.path]

        do {
            try process.run()
            guard process.waitUntilExit(timeout: 10) else {
                return ("Failed to open folder: \(targetURL.path) — timed out.", false)
            }
            return process.terminationStatus == 0
                ? ("Opened folder: \(targetURL.path)", true)
                : ("Failed to open folder: \(targetURL.path)", false)
        } catch {
            return ("Failed to open folder: \(error.localizedDescription)", false)
        }
    }

    // MARK: - Folder resolution (exact → prefix → fuzzy Levenshtein)

    private func resolveFolderName(_ input: String) -> URL? {
        let trimmed   = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let home      = fileManager.homeDirectoryForCurrentUser

        // ── 1. Exact / well-known aliases ────────────────────────────
        let exactAliases: [String: URL] = [
            "downloads":  home.appendingPathComponent("Downloads"),
            "desktop":    home.appendingPathComponent("Desktop"),
            "documents":  home.appendingPathComponent("Documents"),
            "pictures":   home.appendingPathComponent("Pictures"),
            "movies":     home.appendingPathComponent("Movies"),
            "music":      home.appendingPathComponent("Music"),
        ]
        if let hit = exactAliases[normalized], fileManager.fileExists(atPath: hit.path) {
            NSLog("[Folder] Exact match: %@", hit.path)
            return hit
        }

        // ── 2. Prefix / shorthand aliases ────────────────────────────
        // Handles misheard/abbreviated folder names from speech recognition.
        let prefixAliases: [(prefix: String, url: URL)] = [
            ("download",  home.appendingPathComponent("Downloads")),
            ("desk",      home.appendingPathComponent("Desktop")),
            ("doc",       home.appendingPathComponent("Documents")),
            ("pic",       home.appendingPathComponent("Pictures")),
            ("movie",     home.appendingPathComponent("Movies")),
            ("film",      home.appendingPathComponent("Movies")),
            ("music",     home.appendingPathComponent("Music")),
            ("song",      home.appendingPathComponent("Music")),
        ]
        for entry in prefixAliases {
            if normalized.hasPrefix(entry.prefix) && fileManager.fileExists(atPath: entry.url.path) {
                NSLog("[Folder] Prefix match '%@' → %@", entry.prefix, entry.url.path)
                return entry.url
            }
        }

        // ── 3. Absolute path handling ─────────────────────────────────
        let absolutePath = NSString(string: trimmed).expandingTildeInPath
        if absolutePath.hasPrefix("/") {
            guard isAllowedPath(absolutePath) else { return nil }
            let absoluteURL = URL(fileURLWithPath: absolutePath)
            return fileManager.fileExists(atPath: absoluteURL.path) ? absoluteURL : nil
        }

        // ── 4. Fuzzy: scan common home sub-directories ───────────────
        // Pick the folder whose lowercased name has the smallest Levenshtein
        // distance to the input.  Cap at distance 4 to avoid false positives.
        let searchRoots: [URL] = [home]
        var bestURL: URL?
        var bestDistance = 5   // anything ≥ 5 is rejected

        for root in searchRoots {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            ) else { continue }

            for item in contents {
                // Only consider directories
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                guard isDir else { continue }
                guard isAllowedPath(item.path) else { continue }

                let candidateName = item.lastPathComponent.lowercased()
                let dist = StringDistance.levenshtein(normalized, candidateName)
                NSLog("[Folder] Fuzzy candidate '%@' dist=%d", item.lastPathComponent, dist)
                if dist < bestDistance {
                    bestDistance = dist
                    bestURL = item
                }
            }
        }

        if let best = bestURL {
            NSLog("[Folder] Fuzzy match (dist=%d): %@", bestDistance, best.path)
        } else {
            // ── 5. Last resort: current working directory ─────────────
            let direct = URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(trimmed)
            guard isAllowedPath(direct.path) else { return nil }
            if fileManager.fileExists(atPath: direct.path) { return direct }
        }

        return bestURL
    }

    // MARK: - Safety checks

    private func isSafeRelativeName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("..") else { return false }
        guard !trimmed.hasPrefix("/") else { return false }
        return isAllowedPath(
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent(trimmed).path
        )
    }

    private func isAllowedPath(_ path: String) -> Bool {
        !protectedPathPrefixes.contains { path.hasPrefix($0) }
    }
}
