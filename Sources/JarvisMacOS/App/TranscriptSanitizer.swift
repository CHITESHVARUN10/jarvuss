import Foundation

/// Pure text policy lives in Rust. Swift delivers diagnostics and validates the
/// final command through the existing command admission path.
enum TranscriptSanitizer {
    static func isHallucinatedSingleton(_ text: String) -> Bool { coreHallucinatedSingleton(text: text) }
    static func normalizeCompact(_ text: String) -> String { coreNormalizeCompact(text: text) }
    static func normalizedTokens(from text: String) -> [String] { coreNormalizedTokens(text: text) }
    static func sanitizeSpokenCommand(_ text: String) -> String { coreSanitizeSpoken(text: text) }
    static func containsWakeWord(_ text: String) -> Bool { coreContainsWakeWord(text: text) }
    static func normalizeMisheardTargets(in command: String) -> String { coreNormalizeMisheardTargets(command: command) }
    static func removeTrailingWakeWordFragment(from command: String) -> String { coreRemoveWakeFragment(command: command) }
    static func collapseRepeatedWords(_ text: String) -> String { coreCollapseRepeatedWords(text: text) }
    static func collapseRepeatedPhrases(_ text: String, maxPhraseWords: Int = 10, minRepeats: Int = 3) -> String {
        coreCollapseRepeatedPhrases(text: text, maxPhraseWords: Int64(maxPhraseWords), minRepeats: Int64(minRepeats))
    }
    static func hasRepeatedPhraseLoop(_ text: String) -> Bool { coreRepeatedPhraseLoop(text: text) }

    static func cleanVoiceSegment(_ segment: String, onLog: ((String) -> Void)? = nil) -> String? {
        let result = corePrepareVoiceSegment(text: segment)
        if result.normalized != result.beforeNormalization {
            onLog?("[Normalize] '\(result.beforeNormalization)' → '\(result.normalized)'")
        }
        guard let validated = CommandValidator.validate(result.capped) else {
            if !result.capped.isEmpty { onLog?("[Validator] Rejected segment: '\(result.capped)'") }
            return nil
        }
        return validated
    }

    static func sanitizeBatch(_ raw: [String], maxBatchSize: Int = 3, onLog: ((String) -> Void)? = nil) -> [String] {
        let result = coreSanitizeTranscriptBatch(raw: raw, maxBatchSize: Int64(maxBatchSize))
        result.logs.forEach { onLog?($0) }
        return result.commands
    }
}
