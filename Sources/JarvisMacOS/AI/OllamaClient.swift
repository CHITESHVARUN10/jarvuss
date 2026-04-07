import Foundation

final class OllamaClient {
    private let endpoint = URL(string: "http://localhost:11434/api/generate")!
    private let model: String

    init(model: String = "mistral:7b") {
        self.model = model
    }

    func generate(prompt: String) async -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = OllamaGenerateRequest(model: model, prompt: prompt, stream: false)

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return "Ollama request failed: unexpected HTTP response."
            }

            let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            return decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Ollama error: \(error.localizedDescription). Make sure Ollama is running."
        }
    }
}

private struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
}

private struct OllamaGenerateResponse: Codable {
    let response: String
}
