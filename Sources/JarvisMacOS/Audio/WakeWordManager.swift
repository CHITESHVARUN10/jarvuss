import Foundation

final class WakeWordManager {
    private let wakeWord: String

    init(wakeWord: String) {
        self.wakeWord = wakeWord.lowercased()
    }

    func isWakeWordDetected(in text: String) -> Bool {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(wakeWord)
    }

    func extractCommand(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(wakeWord) else {
            return trimmed
        }

        return String(trimmed.dropFirst(wakeWord.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
