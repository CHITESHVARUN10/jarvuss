import Foundation

final class CommandExecutor {
    private let appController = AppController()
    private let fileController = JarvisFileManager()
    private let ollamaClient = OllamaClient()
    private let actionExecutor = ActionExecutor()

    func execute(_ command: ParsedCommand) async -> String {
        switch command {
        case .openApp(let appName):
            return appController.open(appName: appName)
        case .closeApp(let appName):
            return appController.close(appName: appName)
        case .createFile(let filename):
            return fileController.createFile(named: filename)
        case .createFolder(let folderName):
            return fileController.createFolder(named: folderName)
        case .openFolder(let folderName):
            return fileController.openFolder(named: folderName)
        case .searchWeb(let query):
            // Engine is lost in the legacy string hop — default Google, which
            // matches every current searchWeb producer (YouTube intent is
            // carried by parseSinglePhrase's openURL arm, not this path).
            // Single open only: the old double-open lived here + planner.
            return await executePlan([.searchWeb(engine: "Google", query: query)])
        case .aiQuery(let query):
            return await ollamaClient.generate(prompt: query)
        case .unknown(let text):
            return "Unknown command: \(text)"
        case .multiAction(let plan):
            return await executePlan(plan)
        }
    }

    // MARK: - Multi-step plan executor (delegates to ActionExecutor)


    private func executePlan(_ plan: [PlannedAction]) async -> String {
        var results: [String] = []

        await actionExecutor.execute(
            plan: plan,
            onStepStart: { _ in },
            onStepComplete: { result in
                let prefix = result.success ? "✓" : "✗"
                results.append("\(prefix) \(result.message)")
            }
        )

        return results.joined(separator: "\n")
    }
}
