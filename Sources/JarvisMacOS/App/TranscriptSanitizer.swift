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

    /// Collapses a phrase repeated three or more times in a row. Whisper's
    /// greedy decoder occasionally gets stuck on silence or low-confidence
    /// audio ("a little bit of a little bit of …"); the existing word-level
    /// collapse cannot see multi-word loops. Requiring three full repetitions
    /// keeps deliberate repetition ("very good very good") intact.
    ///
    /// Comparison ignores case and surrounding punctuation; the first
    /// occurrence's original tokens are kept.
    static func collapseRepeatedPhrases(
        _ text: String,
        maxPhraseWords: Int = 10,
        minRepeats: Int = 3
    ) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        guard tokens.count >= minRepeats * 2 else { return text }

        func core(_ token: String) -> String {
            token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }

        func phraseMatches(at start: Int, and other: Int, length: Int) -> Bool {
            guard start >= 0, other >= 0,
                  start + length <= tokens.count,
                  other + length <= tokens.count else { return false }
            for offset in 0..<length {
                let a = core(tokens[start + offset])
                let b = core(tokens[other + offset])
                // Punctuation-only tokens never establish a loop.
                guard !a.isEmpty, !b.isEmpty, a == b else { return false }
            }
            return true
        }

        var output: [String] = []
        var index = 0

        while index < tokens.count {
            var collapsed = false
            let maxLength = min(maxPhraseWords, (tokens.count - index) / minRepeats)

            if maxLength >= 2 {
                for length in stride(from: maxLength, through: 2, by: -1) {
                    var repeats = 1
                    while index + (repeats + 1) * length <= tokens.count,
                          phraseMatches(at: index, and: index + repeats * length, length: length) {
                        repeats += 1
                    }
                    if repeats >= minRepeats {
                        output.append(contentsOf: tokens[index..<(index + length)])
                        index += repeats * length
                        collapsed = true
                        break
                    }
                }
            }

            if !collapsed {
                output.append(tokens[index])
                index += 1
            }
        }

        return output.joined(separator: " ")
    }

    /// Used by the polish guard: a repetition that survived the rules pass and
    /// appeared in model output means the model introduced it, so the rules
    /// text should win.
    static func hasRepeatedPhraseLoop(_ text: String) -> Bool {
        collapseRepeatedPhrases(text) != text
    }

    /// One wake-word-split segment → validated command, or nil to drop.
    static func cleanVoiceSegment(_ segment: String, onLog: ((String) -> Void)? = nil) -> String? {
        var cleaned = sanitizeSpokenCommand(segment)
        cleaned = removeTrailingWakeWordFragment(from: cleaned)
        cleaned = collapseRepeatedWords(cleaned)
        cleaned = collapseRepeatedPhrases(cleaned)
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

    /// Resolve app-target conflicts (last wins per target) and cap. Repeated
    /// side-effecting commands such as next/volume-up retain their order.
    static func sanitizeBatch(
        _ raw: [String],
        maxBatchSize: Int = 3,
        onLog: ((String) -> Void)? = nil
    ) -> [String] {
        let original = raw.count

        // Separate utterances can intentionally repeat a side effect.
        let commands = raw

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
        for cmd in commands {
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
        for cmd in commands {
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
