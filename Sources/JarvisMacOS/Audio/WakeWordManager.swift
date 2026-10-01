import Foundation

final class WakeWordManager {
    private let wakeWord: String

    init(wakeWord: String) {
        self.wakeWord = wakeWord.lowercased()
    }

    func isWakeWordDetected(in text: String) -> Bool {
        // Migration cut-over: Rust core carries the same prefix rule.
        if JarvisFlags.useRustPipeline {
            return coreIsWakeWordDetected(text: text, wakeWord: wakeWord)
        }
        return text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(wakeWord)
    }

    func extractCommand(from text: String) -> String {
        // Migration cut-over: Rust core carries the same strip rule.
        if JarvisFlags.useRustPipeline {
            return coreExtractWakeCommand(text: text, wakeWord: wakeWord)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(wakeWord) else {
            return trimmed
        }

        return String(trimmed.dropFirst(wakeWord.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
