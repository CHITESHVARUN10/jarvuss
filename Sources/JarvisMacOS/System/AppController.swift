import Foundation

final class AppController {
    func open(appName: String) -> String {
        let normalized = AppAliasResolver.resolve(appName)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", normalized]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "Opened \(normalized)."
            }
            return "Failed to open \(normalized)."
        } catch {
            return "Error opening app: \(error.localizedDescription)"
        }
    }

    func close(appName: String) -> String {
        let normalized = AppAliasResolver.resolve(appName)
        let script = "tell application \"\(normalized)\" to quit"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return "Closed \(normalized)."
            }
            return "Failed to close \(normalized)."
        } catch {
            return "Error closing app: \(error.localizedDescription)"
        }
    }
}

enum AppAliasResolver {
    static func resolve(_ name: String) -> String {
        let value = normalize(name)
        guard !value.isEmpty else { return name }

        for (canonical, aliases) in aliasMap {
            if aliases.contains(value) {
                return canonical
            }
        }

        if let fuzzy = fuzzyResolve(value) {
            return fuzzy
        }

        return name
    }

    private static let aliasMap: [String: Set<String>] = [
        "Google Chrome": ["chrome", "google chrome", "googlechrom"],
        "GitHub Desktop": [
            "github", "github desktop", "git hub", "git hub desktop", "githab desktop",
            "get her desktop", "getha desktop", "get desktop", "gate desktop", "get up desktop", "gita desktop"
        ],
        "System Settings": ["system settings", "settings", "system setting"],
        "Brave Browser": ["brave", "brave browser", "browser", "web browser"],
        "Visual Studio Code": ["vscode", "vs code", "visual studio code", "visual code"],
        "Finder": ["finder"],
        "Terminal": ["terminal"]
    ]

    private static func fuzzyResolve(_ value: String) -> String? {
        var bestCanonical: String?
        var bestDistance = Int.max

        for (canonical, aliases) in aliasMap {
            for alias in aliases {
                let distance = levenshteinDistance(lhs: value, rhs: alias)
                if distance < bestDistance {
                    bestDistance = distance
                    bestCanonical = canonical
                }
            }
        }

        guard let bestCanonical else { return nil }
        let maxAllowedDistance = max(1, value.count / 4)
        return bestDistance <= maxAllowedDistance ? bestCanonical : nil
    }

    private static func normalize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func levenshteinDistance(lhs: String, rhs: String) -> Int {
        let lhsArray = Array(lhs)
        let rhsArray = Array(rhs)
        var matrix = Array(repeating: Array(repeating: 0, count: rhsArray.count + 1), count: lhsArray.count + 1)

        for lhsIndex in 0...lhsArray.count {
            matrix[lhsIndex][0] = lhsIndex
        }

        for rhsIndex in 0...rhsArray.count {
            matrix[0][rhsIndex] = rhsIndex
        }

        for lhsIndex in 1...lhsArray.count {
            for rhsIndex in 1...rhsArray.count {
                let cost = lhsArray[lhsIndex - 1] == rhsArray[rhsIndex - 1] ? 0 : 1
                matrix[lhsIndex][rhsIndex] = min(
                    matrix[lhsIndex - 1][rhsIndex] + 1,
                    min(
                        matrix[lhsIndex][rhsIndex - 1] + 1,
                        matrix[lhsIndex - 1][rhsIndex - 1] + cost
                    )
                )
            }
        }

        return matrix[lhsArray.count][rhsArray.count]
    }
}
