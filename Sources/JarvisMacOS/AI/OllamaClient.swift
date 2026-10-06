import Foundation

/// The app's single local LLM. Change here once — every planner, normalizer,
/// answer path, and the ⌘⇧D polish pass follows.
/// NEVER point this at mistral:7b or any 7B+ model: on a 24 GB Mac the
/// 7B weights (~4.4 GB) plus Whisper (~1.6 GB resident) plus the app push
/// unified memory past 10 GB and macOS starts compressing.
///
/// Why INSTRUCT, not a base model: every caller here asks the model to OBEY
/// ("convert this to that JSON", "clean this up, change nothing else").
/// A base model has no instruction-following tuning — it continues text in
/// the style of its corpus, so it happily writes prose around a JSON request
/// or silently drops fields, while an instruct model was post-trained on
/// (instruction, correct answer) pairs and treats the prompt as a command.
/// The trade-off runs the other way for raw creative completion, which
/// nothing in this app needs.
///
/// Memory guards live HERE, not at each call site:
/// - keepAliveSeconds: unload the model after 60 s idle so VRAM returns.
/// - timeout: a stuck Ollama call can never wedge the queue forever.
/// - Single-flight: only one generate at a time; concurrent callers share
///   the in-flight result instead of spawning parallel model loads.
enum JarvisModel {
    static let name = "qwen2.5:1.5b-instruct"
    /// Alias kept for the ⌘⇧D polish pass (`DictationPolisher`) — the same
    /// model now serves the whole app, one resident model instead of two.
    static let formattingName = name
    static let unloadAfterIdleSeconds = 60
    static let requestTimeoutSeconds: TimeInterval = 60
}

final class OllamaClient {
    private let endpoint = URL(string: "http://127.0.0.1:11434/api/generate")!
    private let model: String

    // MARK: - Failure classification

    /// Stable prefix on every failure string `generate` returns. Callers use
    /// `isFailure` to tell a dead model from real output — without this, a
    /// transport error was shown and spoken as if it were the answer.
    static let failurePrefix = "Ollama error"

    static func isFailure(_ text: String) -> Bool {
        text.hasPrefix(failurePrefix)
    }

    /// One sentence the UI can show and speak; the raw transport detail goes
    /// to the log, never into a response card.
    static let unavailableMessage =
        "I can't reach the local model right now — Ollama isn't responding. "
        + "Commands still work; start Ollama (`ollama serve`) for answers and polish."

    private static func failure(_ detail: String) -> String {
        "\(failurePrefix): \(detail). Make sure Ollama is running."
    }

    /// Ollama reports failures as {"error": "model … not found"} — surface
    /// that reason instead of a generic HTTP failure.
    private static func httpFailureDetail(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["error"] as? String, !message.isEmpty {
            return message
        }
        return "unexpected HTTP response"
    }

    /// Single-flight lock: only one Ollama inference at a time app-wide.
    /// Parallel /generate calls each load a runner (~1-4 GB); without this,
    /// 3 queued voice commands = 3 concurrent loads = the 10 GB spike.
    private static let flightLock = NSLock()
    private static var inFlight: Task<String, Never>?
    /// Generation token: Task is a struct (no === identity) and hashValue
    /// is not identity — only clear inFlight when IDs match.
    private static var inFlightID: UUID?

    init(model: String = JarvisModel.name) {
        if model != JarvisModel.name && model != JarvisModel.formattingName {
            NSLog("[Ollama] WARNING: non-canonical model '%@' requested — forcing '%@' (7B+ models OOM this Mac)", model, JarvisModel.name)
            self.model = JarvisModel.name
        } else {
            self.model = model
        }
    }

    func generate(prompt: String) async -> String {
        // Migration cut-over: Rust owns the HTTP call, keep-alive unload,
        // timeout, and the process-wide single-flight guard.
        if JarvisFlags.useRustPipeline {
            let outcome = await RustPipeline.runBlocking { coreOllamaGenerate(prompt: prompt) }
            if let error = outcome.error {
                // Never return the raw reqwest text as the model's answer.
                NSLog("[Ollama] Rust call failed: %@", error)
                return Self.failure(error)
            }
            StatsRecorder.shared.recordLLM(promptChars: Int(outcome.promptChars),
                                           responseChars: Int(outcome.responseChars))
            return outcome.text
        }

        OllamaClient.flightLock.lock()
        if let shared = OllamaClient.inFlight {
            OllamaClient.flightLock.unlock()
            NSLog("[Ollama] Coalesced concurrent generate — sharing in-flight result")
            return await shared.value
        }
        let task = Task<String, Never> { [endpoint, model] in
            await Self.runGenerate(endpoint: endpoint, model: model, prompt: prompt)
        }
        let taskID = UUID()
        OllamaClient.inFlight = task
        OllamaClient.inFlightID = taskID
        OllamaClient.flightLock.unlock()

        let result = await task.value

        OllamaClient.flightLock.lock()
        if OllamaClient.inFlightID == taskID {
            OllamaClient.inFlight = nil
            OllamaClient.inFlightID = nil
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
                return Self.failure(Self.httpFailureDetail(data))
            }

            let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            let response = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
            StatsRecorder.shared.recordLLM(promptChars: prompt.count, responseChars: response.count)
            return response
        } catch {
            return Self.failure(error.localizedDescription)
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
