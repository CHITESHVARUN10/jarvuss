import Foundation

final class AssistantEngine {
    private let parser = CommandParser()
    private let executor = CommandExecutor()
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func handle(_ commandText: String) async {
        let normalized = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            print("I heard the wake word, but no command followed.")
            return
        }

        logger.log(command: normalized)
        let parsed = parser.parse(normalized)
        let output = await executor.execute(parsed)
        print(output)
    }

    func printHelp() {
        print("""
        Examples:
          Jarvis open chrome
          Jarvis close vscode
          Jarvis create file test.txt
          Jarvis create folder demo
          Jarvis open folder downloads
          Jarvis explain recursion
        """)
    }
}