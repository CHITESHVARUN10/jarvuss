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

    // MARK: - Public API

    /// Clean and validate a raw command string.
    /// - Returns: Cleaned string if valid, nil if the command should be rejected.
    static func validate(_ raw: String) -> String? {
        var cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        // 1. Empty check
        guard !cleaned.isEmpty else {
            NSLog("[Validator] Rejected: empty command")
            return nil
        }

        // 2. Strip trailing filler words (repeat until stable)
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

        // 8. Hard absolute cap: any input > 15 words is almost certainly garbled speech
        let wordCount = cleaned.split(separator: " ").count
        if wordCount > 15 {
            NSLog("[Validator] Rejected: too long (%d words): '%@'", wordCount, cleaned)
            return nil
        }

        // Fix #11: Word-count limit for system commands (> 10 words → likely garbage run-on).
        // AI queries are exempt from this cap.
        let systemPrefixes = ["open ", "close ", "play ", "search ", "launch ",
                              "run ", "create ", "start ", "next ", "previous ",
                              "increase ", "decrease ", "mute", "unmute", "pause"]
        let isSystemCommand = systemPrefixes.contains { lower.hasPrefix($0) }
        if isSystemCommand && wordCount > 10 {
            NSLog("[Validator] Rejected: system command too long (%d words): '%@'", wordCount, cleaned)
            return nil
        }

        return cleaned
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
