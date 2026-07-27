import Foundation

final class CommandExecutor {
    private let appController = AppController()
    private let fileController = JarvisFileManager()
    private let ollamaClient = OllamaClient()
    private let actionExecutor = ActionExecutor()
    private let voiceAuthClient = VoiceAuthClient()

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
        case .aiQuery(let query):
            return await ollamaClient.generate(prompt: query)
        case .ragQuery(let query):
            return await executeRAGQuery(query)
        case .unknown(let text):
            return "Unknown command: \(text)"
        case .multiAction(let plan):
            return await executePlan(plan)
        }
    }

    private func executeRAGQuery(_ query: String) async -> String {
        do {
            let chunks = try await voiceAuthClient.ragQuery(query: query, topK: 3)
            if chunks.isEmpty {
                return "No relevant documents found for: \(query)"
            }
            let context = chunks.joined(separator: "\n\n")
            let prompt = "Context from user documents:\n\(context)\n\nQuestion: \(query)\nAnswer concisely:"
            return await ollamaClient.generate(prompt: prompt)
        } catch {
            return "Failed to query documents: \(error.localizedDescription)"
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
