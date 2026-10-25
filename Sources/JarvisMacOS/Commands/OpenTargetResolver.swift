import Foundation

/// Shared resolution for "open <site> in <browser>" and local dev URLs.
///
/// The learned intent model emits `url.open_in` for these; the deterministic
/// fast path uses the same resolver so the action works before retraining.
enum OpenTargetResolver {

    /// Canonical site targets used by the new browser/URL datasets.
    private static let siteTargets: [String: String] = [
        "chatgpt": "https://chatgpt.com",
        "chat gpt": "https://chatgpt.com",
        "chatgpt.com": "https://chatgpt.com",
        "chat gpt.com": "https://chatgpt.com",
        "chat gpt ai": "https://chatgpt.com",
        "chatgpt.ai": "https://chatgpt.com",
        "vercel": "https://vercel.com",
        "versel": "https://vercel.com",
        "varcel": "https://vercel.com",
        "vercel.com": "https://vercel.com",
        "versel.com": "https://vercel.com",
        "claude": "https://claude.com",
        "claude ai": "https://claude.com",
        "claude.ai": "https://claude.com",
        "claude.com": "https://claude.com",
        "claude code": "https://code.claude.com",
        "cloud code": "https://code.claude.com",
        "clawed code": "https://code.claude.com",
        "claude code.com": "https://code.claude.com",
        "cloud code.com": "https://code.claude.com",
        "code.claude.com": "https://code.claude.com",
        "command code": "https://commandcode.ai",
        "commandcode": "https://commandcode.ai",
        "commend code": "https://commandcode.ai",
        "command code.com": "https://commandcode.ai",
        "commandcode.ai": "https://commandcode.ai",
        "command code.ai": "https://commandcode.ai",
        "github": "https://github.com",
        "git hub": "https://github.com",
        "github.com": "https://github.com",
        "youtube": "https://www.youtube.com",
        "you tube": "https://www.youtube.com",
        "youtube.com": "https://www.youtube.com",
        "google": "https://www.google.com",
    ]

    private static let browserNames: [(alias: String, canonical: String)] = [
        ("brave browser", "Brave Browser"),
        ("brave", "Brave Browser"),
        ("google chrome", "Google Chrome"),
        ("chrome", "Google Chrome"),
        ("safari", "Safari"),
        ("firefox", "Firefox"),
        ("microsoft edge", "Microsoft Edge"),
        ("edge", "Microsoft Edge"),
        ("arc browser", "Arc"),
        ("arc", "Arc"),
    ]

    static func canonicalBrowser(_ raw: String) -> String? {
        let normalized = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
        return browserNames.first(where: { normalized == $0.alias })?.canonical
    }

    static func siteURL(for raw: String) -> String? {
        var target = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        guard !target.isEmpty else { return nil }

        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }

        // "chatgpt dot com" → "chatgpt.com"
        target = target.replacingOccurrences(of: " dot com", with: ".com")
        target = target.replacingOccurrences(of: " dot ai", with: ".ai")

        if let known = siteTargets[target] { return known }

        // A bare domain is a URL; words are not.
        if target.contains("."), !target.contains(" ") {
            return "https://\(target)"
        }
        return nil
    }

    /// "open chatgpt in brave", "open vercel on google chrome",
    /// "open claude code using arc".
    static func parseOpenInBrowser(_ lower: String) -> (url: String, browser: String)? {
        let pattern = #"^open\s+(.+?)\s+(?:in|on|using|with)\s+(?:the\s+|my\s+)?(brave browser|google chrome|chrome|brave|safari|firefox|microsoft edge|edge|arc browser|arc)(?:\s+browser)?[.!?]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let siteRange = Range(match.range(at: 1), in: lower),
              let browserRange = Range(match.range(at: 2), in: lower) else {
            return nil
        }

        let site = String(lower[siteRange])
        let browser = String(lower[browserRange])
        guard let url = siteURL(for: site),
              let canonical = canonicalBrowser(browser) else { return nil }
        return (url, canonical)
    }

    /// React/Vite defaults to 5173; a bare localhost defaults to 3000.
    /// Local development opens in Brave unless another browser is named.
    static func parseLocalDev(_ lower: String) -> (url: String, browser: String)? {
        guard lower.hasPrefix("open ") else { return nil }

        let hasLocalDevCue = lower.contains("localhost")
            || lower.contains("local host")
            || lower.contains("react app")
            || lower.contains("react application")
            || lower.contains("vite")
            || lower.range(of: #"\bport\s+\d{2,5}\b"#, options: .regularExpression) != nil
        guard hasLocalDevCue else { return nil }

        let port = extractPort(from: lower) ?? (isReact(lower) ? 5173 : 3000)
        guard (1...65535).contains(port) else { return nil }

        let browser = extractBrowser(from: lower) ?? "Brave Browser"
        return ("http://localhost:\(port)", browser)
    }

    private static func isReact(_ lower: String) -> Bool {
        lower.contains("react") || lower.contains("vite")
    }

    private static func extractPort(from lower: String) -> Int? {
        let patterns = [
            #"localhost[:\s]+(\d{2,5})"#,
            #"\bport\s+(\d{2,5})"#,
            #"\b(?:on|at|in)\s+(\d{2,5})\b"#,
            #":(\d{2,5})\b"#,
            #"\b(\d{2,5})\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
                  let range = Range(match.range(at: 1), in: lower),
                  let value = Int(lower[range]) else { continue }
            return value
        }
        return nil
    }

    private static func extractBrowser(from lower: String) -> String? {
        let pattern = #"(?:in|on|using|with)\s+(?:the\s+|my\s+)?(brave browser|google chrome|chrome|brave|safari|firefox|microsoft edge|edge|arc browser|arc)(?:\s+browser)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower) else { return nil }
        return canonicalBrowser(String(lower[range]))
    }
}
