import Foundation

/// Pure voice-transcript cleaning, extracted from AppState (the batch path in
/// `handleTranscript` is the sole command entry — these are its filters).
///
/// All logging goes through the optional `onLog` hook so the functions stay
/// pure and unit-testable; AppState passes its `appendLog`, tests capture.
enum TranscriptSanitizer {
    /// Whisper emits these on silence ("thank you" on an empty buffer is the
    /// classic hallucination) — never commands without a wake word.
    static let hallucinatedSingletons: Set<String> = [
        "thankyou", "thanks", "you", "thankyouthankyou", "okay", "ok",
        "thankyouforwatching", "thanksforwatching", "thankyouverymuch",
        "subtitlesby", "blankaudio", "youyouyou",
    ]

    static func isHallucinatedSingleton(_ text: String) -> Bool {
        hallucinatedSingletons.contains(normalizeCompact(text))
    }

    static func normalizeCompact(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
    }

    static func normalizedTokens(from text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
    }

    static func sanitizeSpokenCommand(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[\\p{Punct}\\s]+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsWakeWord(_ text: String) -> Bool {
        text.lowercased().range(of: "\\bjarvis\\b", options: .regularExpression) != nil
    }

    static func normalizeMisheardTargets(in command: String) -> String {
        let lower = command.lowercased()
        if lower.hasPrefix("open ") || lower.hasPrefix("close ") {
            if lower.contains("get her desktop") ||
                lower.contains("getha desktop") ||
                lower.contains("get desktop") ||
                lower.contains("gate desktop") {
                let verb = lower.hasPrefix("close ") ? "close" : "open"
                return "\(verb) GitHub Desktop"
            }
        }
        return command
    }

    static func removeTrailingWakeWordFragment(from command: String) -> String {
        var tokens = command.split(separator: " ").map(String.init)
        guard let last = tokens.last?.lowercased() else { return command }

        let wakeFragments = ["ja", "jar", "jarv", "jarvi", "jarvis"]
        if wakeFragments.contains(last) {
            tokens.removeLast()
        }

        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func collapseRepeatedWords(_ text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        var output: [String] = []
        for token in tokens {
            if output.last?.lowercased() != token.lowercased() {
                output.append(token)
            }
        }
        return output.joined(separator: " ")
    }

    /// One wake-word-split segment → validated command, or nil to drop.
    static func cleanVoiceSegment(_ segment: String, onLog: ((String) -> Void)? = nil) -> String? {
        var cleaned = sanitizeSpokenCommand(segment)
        cleaned = removeTrailingWakeWordFragment(from: cleaned)
        cleaned = collapseRepeatedWords(cleaned)
        cleaned = normalizeMisheardTargets(in: cleaned)

        // Strip filler words
        let fillerRegex = "\\b(please|okay|ok|uh|um|you know|like)\\b"
        cleaned = cleaned
            .replacingOccurrences(of: fillerRegex, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip any residual jarvis tokens (edge-case partial matches)
        cleaned = cleaned
            .replacingOccurrences(of: "(?i)\\bjarvis\\b", with: " ",
                                   options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Enforce 8-word max per command
        let tokens = cleaned.split(separator: " ").map(String.init)
        let capped  = tokens.count > 8 ? Array(tokens.prefix(8)).joined(separator: " ") : cleaned

        guard let validated = CommandValidator.validate(capped) else {
            if !capped.isEmpty { onLog?("[Validator] Rejected segment: '\(capped)'") }
            return nil
        }
        return validated
    }

    /// Dedup (last wins) + open/close conflict resolution (last wins per
    /// target) + cap. Notices go through `onLog`, keeping this testable.
    static func sanitizeBatch(
        _ raw: [String],
        maxBatchSize: Int = 3,
        onLog: ((String) -> Void)? = nil
    ) -> [String] {
        let original = raw.count

        // Step 1: Deduplicate — last occurrence wins
        var seen = Set<String>()
        var deduplicated: [String] = []
        for cmd in raw.reversed() {
            let key = cmd.lowercased().trimmingCharacters(in: .whitespaces)
            if seen.insert(key).inserted { deduplicated.insert(cmd, at: 0) }
        }

        // Step 2: Build app-target → winning command map
        let appPrefixes = ["open ", "close ", "launch ", "start ", "run "]
        func appTarget(for cmd: String) -> (verb: String, target: String)? {
            let lower = cmd.lowercased()
            for prefix in appPrefixes {
                if lower.hasPrefix(prefix) {
                    let target = String(lower.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                    return (prefix.trimmingCharacters(in: .whitespaces), target)
                }
            }
            return nil
        }

        var winner = [String: String]()
        for cmd in deduplicated {
            if let (verb, target) = appTarget(for: cmd) {
                if let prev = winner[target] {
                    let prevVerb = appTarget(for: prev)?.verb ?? "?"
                    onLog?("[Conflict] resolved: \(target) \(prevVerb) → \(verb) (last wins)")
                }
                winner[target] = cmd
            }
        }

        // Step 3: Rebuild in ORIGINAL ORDER
        var emittedTargets = Set<String>()
        var combined: [String] = []
        for cmd in deduplicated {
            if let (_, target) = appTarget(for: cmd) {
                if let w = winner[target], w == cmd, !emittedTargets.contains(target) {
                    combined.append(cmd)
                    emittedTargets.insert(target)
                }
            } else {
                combined.append(cmd)
            }
        }

        // Step 4: Cap at maxBatchSize
        if combined.count > maxBatchSize {
            onLog?("[Batch] capped: \(combined.count) → \(maxBatchSize) commands")
            combined = Array(combined.suffix(maxBatchSize))
        }

        if combined.count != original {
            onLog?("[Batch] sanitized: \(original) → \(combined.count) commands")
        }
        return combined
    }
}
