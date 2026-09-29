import Foundation

/// Single model for the whole app (user asked: Qwen 2.5 Coder 1.5B).
/// Change here once — every planner, normalizer, and answer path follows.
/// NEVER point this at mistral:7b or any 7B+ model: on a 24 GB Mac the
/// 7B weights (~4.4 GB) plus Whisper (~1.6 GB resident) plus the app push
/// unified memory past 10 GB and macOS starts compressing.
///
/// Memory guards live HERE, not at each call site:
/// - keepAliveSeconds: unload the model after 60 s idle so VRAM returns.
/// - timeout: a stuck Ollama call can never wedge the queue forever.
/// - Single-flight: only one generate at a time; concurrent callers share
///   the in-flight result instead of spawning parallel model loads.
enum JarvisModel {
    static let name = "qwen2.5-coder:1.5b-base"
    static let unloadAfterIdleSeconds = 60
    static let requestTimeoutSeconds: TimeInterval = 60
}

final class OllamaClient {
    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private let model: String

    /// Single-flight lock: only one Ollama inference at a time app-wide.
    /// Parallel /generate calls each load a runner (~1-4 GB); without this,
    /// 3 queued voice commands = 3 concurrent loads = the 10 GB spike.
    private static let flightLock = NSLock()
    private static var inFlight: Task<String, Never>?

    init(model: String = JarvisModel.name) {
        if model != JarvisModel.name {
            NSLog("[Ollama] WARNING: non-canonical model '%@' requested — forcing '%@' (7B+ models OOM this Mac)", model, JarvisModel.name)
        }
        self.model = JarvisModel.name
    }

    func generate(prompt: String) async -> String {
        OllamaClient.flightLock.lock()
        if let shared = OllamaClient.inFlight {
            OllamaClient.flightLock.unlock()
            NSLog("[Ollama] Coalesced concurrent generate — sharing in-flight result")
            return await shared.value
        }
        let task = Task<String, Never> { [endpoint, model] in
            await Self.runGenerate(endpoint: endpoint, model: model, prompt: prompt)
        }
        OllamaClient.inFlight = task
        OllamaClient.flightLock.unlock()

        let result = await task.value

        OllamaClient.flightLock.lock()
        if OllamaClient.inFlight?.hashValue == task.hashValue {
            OllamaClient.inFlight = nil
        }
        OllamaClient.flightLock.unlock()
        return result
    }

    private static func runGenerate(endpoint: URL, model: String, prompt: String) async -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = JarvisModel.requestTimeoutSeconds

        // keep_alive unloads the model 60 s after last use so VRAM returns
        // to the system instead of sitting resident between commands.
        let payload = OllamaGenerateRequest(
            model: model, prompt: prompt, stream: false,
            keepAliveSeconds: JarvisModel.unloadAfterIdleSeconds
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, urlResponse) = try await URLSession.shared.data(for: request)

            guard let http = urlResponse as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return "Ollama request failed: unexpected HTTP response."
            }

            let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            let response = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
            StatsRecorder.shared.recordLLM(promptChars: prompt.count, responseChars: response.count)
            return response
        } catch {
            return "Ollama error: \(error.localizedDescription). Make sure Ollama is running."
        }
    }
}

private struct OllamaGenerateRequest: Codable {
    let model: String
    let prompt: String
    let stream: Bool
    let keepAliveSeconds: Int

    enum CodingKeys: String, CodingKey {
        case model, prompt, stream
        case keepAliveSeconds = "keep_alive"
    }
}

private struct OllamaGenerateResponse: Codable {
    let response: String
}
