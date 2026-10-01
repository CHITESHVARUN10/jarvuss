import Foundation

/// Validates and cleans raw command strings before they enter the execution pipeline.
///
/// Responsibilities:
/// - Strip trailing filler words ("and", "then", "please")
/// - Reject obviously incomplete or garbage inputs
/// - Log all rejections for debugging
enum CommandValidator {

    // MARK: - Trailing words to strip before validation

    // Trailing words/fragments to strip before validation.
    // "jarvis" handles mic bleed-in of the wake word at end of utterance.
    // "pause"/"stop" handle compound utterances that were split mid-sentence
    // where the second action keyword bleeds into the first command string.
    private static let trailingStripWords = [
        "and", "then", "please", "okay", "ok", "now",
        "jarvis",   // wake-word bleed at end
    ]

    // MARK: - Minimum length (characters, after cleaning)

    private static let minimumLength = 3

    /// Trailing politeness / sign-off phrases. Stripped before the word-level
    /// filler pass so "…play a song. Thank you." doesn't leak into the query.
    private static let trailingPhrases = [
        "thank you very much", "thank you so much", "thanks a lot", "thank you",
        "thanks", "that's all", "thats all", "that will be all", "that's it",
        "if you can", "if you could", "for me please", "please do", "for me",
    ]

    /// Action verbs used to tell a genuine multi-intent compound command
    /// ("open X and play Y") from a single-verb garbled run-on.
    private static let actionVerbs: Set<String> = [
        "open", "close", "launch", "quit", "play", "pause", "resume", "stop",
        "next", "previous", "prev", "skip", "search", "google", "find", "list",
        "count", "show", "tell", "create", "make", "run", "start", "increase",
        "decrease", "set", "turn", "mute", "unmute", "check", "calculate",
        "summarise", "summarize", "rename", "move", "delete", "sort",
    ]

    // MARK: - Public API

    /// Clean and validate a raw command string.
    /// - Returns: Cleaned string if valid, nil if the command should be rejected.
    static func validate(_ raw: String) -> String? {
        // Migration cut-over: the Rust core runs the same cleaning rules.
        if JarvisFlags.useRustPipeline {
            let cleaned = coreValidateCommandString(raw: raw)
            if cleaned == nil {
                NSLog("[Validator] Rejected (rust): '%@'", raw)
            }
            return cleaned
        }

        var cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // 1. Empty check
        guard !cleaned.isEmpty else {
            NSLog("[Validator] Rejected: empty command")
            return nil
        }

        // 2. Strip trailing politeness phrases, then trailing filler words
        cleaned = stripTrailingPhrases(cleaned)
        cleaned = stripTrailingFillers(cleaned)

        // 3. Re-check emptiness after stripping
        guard !cleaned.isEmpty else {
            NSLog("[Validator] Rejected: only filler words")
            return nil
        }

        // 4. Minimum length check
        guard cleaned.count >= minimumLength else {
            NSLog("[Validator] Rejected: too short ('%@')", cleaned)
            return nil
        }

        // 5. Strip residual "jarvis" tokens (post-split segments may still have fragments).
        // Strip rather than reject — implements "split THEN validate" requirement.
        if cleaned.lowercased().range(of: "\\bjarvis\\b", options: .regularExpression) != nil {
            cleaned = cleaned
                .replacingOccurrences(of: "(?i)\\bjarvis\\b", with: " ",
                                       options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog("[Validator] Stripped residual wake word → '%@'", cleaned)
            guard !cleaned.isEmpty else {
                NSLog("[Validator] Rejected: only wake word remaining")
                return nil
            }
        }

        // 6. Reject commands that still end with a conjunction (incomplete multi-command)
        let lower = cleaned.lowercased()
        let incompleteEndings = ["and", "then", "or", "but", "with", "to", "the", "a", "an"]
        let lastWord = lower.components(separatedBy: .whitespaces).last ?? ""
        if incompleteEndings.contains(lastWord) {
            NSLog("[Validator] Rejected: ends with conjunction '%@' — '%@'", lastWord, cleaned)
            return nil
        }

        // 7. Reject pure punctuation / numbers
        let alphaCount = cleaned.filter { $0.isLetter }.count
        guard alphaCount >= 2 else {
            NSLog("[Validator] Rejected: no meaningful words ('%@')", cleaned)
            return nil
        }

        // 8. Word caps. Length alone is only suspicious when the utterance
        // carries a SINGLE action — compound commands ("open X and play Y,
        // then search Z") are legitimately long. Counting action verbs lets
        // real multi-intent speech through while still rejecting run-on
        // garbage that would otherwise waste a model call.
        let tokens = lower
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        let wordCount = tokens.count
        let verbCount = Set(tokens).intersection(actionVerbs).count
        let isCompound = verbCount >= 2

        let wordCap = isCompound ? 40 : 15
        if wordCount > wordCap {
            NSLog("[Validator] Rejected: too long (%d words, %d verbs): '%@'",
                  wordCount, verbCount, cleaned)
            return nil
        }

        // Fix #11: single-action system commands stay tightly capped; compound
        // commands are exempt because every clause is a separate intent.
        let systemPrefixes = ["open ", "close ", "play ", "search ", "launch ",
                              "run ", "create ", "start ", "next ", "previous ",
                              "increase ", "decrease ", "mute", "unmute", "pause"]
        let isSystemCommand = systemPrefixes.contains { lower.hasPrefix($0) }
        if isSystemCommand && !isCompound && wordCount > 10 {
            NSLog("[Validator] Rejected: system command too long (%d words): '%@'", wordCount, cleaned)
            return nil
        }

        return cleaned
    }

    // MARK: - Strip trailing politeness phrases (longest match first)

    static func stripTrailingPhrases(_ input: String) -> String {
        var current = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lower = current.lowercased()
            for phrase in trailingPhrases {
                for separator in [" ", ", ", ". ", "! "] {
                    let suffix = separator + phrase
                    if lower.hasSuffix(suffix) || lower.hasSuffix(suffix + ".") {
                        let dropCount = lower.hasSuffix(suffix + ".") ? suffix.count + 1 : suffix.count
                        current = String(current.dropLast(dropCount))
                            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.!?;")))
                        changed = true
                        break
                    }
                }
                if changed { break }
            }
        }
        return current
    }

    // MARK: - Strip trailing filler words (recursive until stable)

    static func stripTrailingFillers(_ input: String) -> String {
        var current = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            let lower = current.lowercased()
            for word in trailingStripWords {
                let suffix1 = " \(word)"        // " and"
                let suffix2 = ", \(word)"       // ", and"
                if lower.hasSuffix(suffix1) {
                    current = String(current.dropLast(suffix1.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                } else if lower.hasSuffix(suffix2) {
                    current = String(current.dropLast(suffix2.count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return current
    }
}
