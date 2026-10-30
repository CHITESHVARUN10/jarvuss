import Foundation

/// HTTP client for the learned intent parser (`POST /parse_intent` on the
/// local backend). The backend runs the fine-tuned t5-small model and returns
/// the ordered intent JSON plus a confidence score.
final class IntentModelClient {

    struct ParsedResponse {
        let actions: [[String: Any]]
        let confidence: Double
        let parseOK: Bool
        let raw: String
        let latencyMs: Int
    }

    enum ClientError: LocalizedError {
        case unavailable
        case badStatus(Int)
        case badPayload

        var errorDescription: String? {
            switch self {
            case .unavailable: return "The local intent backend is unavailable or disabled."
            case .badStatus(let status): return "The intent backend returned HTTP \(status). Check Setup and the backend diagnostic log."
            case .badPayload: return "The intent backend returned an invalid response."
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession
    private let backendIsRunning: () async -> Bool

    init(baseURL: URL? = nil, timeout: TimeInterval = 2, backendIsRunning: @escaping () async -> Bool = {
        await BackendServiceManager.isBackendResponding()
    }) {
        self.backendIsRunning = backendIsRunning
        let configured = ProcessInfo.processInfo.environment["JARVIS_BACKEND_URL"]
            ?? ProcessInfo.processInfo.environment["BACKEND_BASE_URL"]
            ?? "http://127.0.0.1:8000"
        self.baseURL = baseURL ?? URL(string: configured) ?? URL(string: "http://127.0.0.1:8000")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        self.session = URLSession(configuration: config)
    }

    func parse(text: String) async throws -> ParsedResponse {
        if baseURL.host == "127.0.0.1", baseURL.port == 8000 {
            guard BackendServiceManager.mode != .off, await backendIsRunning() else { throw ClientError.unavailable }
            BackendServiceManager.noteActivity()
        }
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("parse_intent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await BackendAccess.data(for: request, session: session)
        guard let http = response as? HTTPURLResponse else { throw ClientError.badPayload }
        guard http.statusCode == 200 else { throw ClientError.badStatus(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.badPayload
        }

        let actions = (obj["actions"] as? [[String: Any]]) ?? []
        let confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0
        let parseOK = (obj["parse_ok"] as? Bool) ?? false
        let raw = (obj["raw"] as? String) ?? ""
        let latencyMs = (obj["latency_ms"] as? NSNumber)?.intValue ?? 0
        return ParsedResponse(actions: actions, confidence: confidence, parseOK: parseOK,
                              raw: raw, latencyMs: latencyMs)
    }
}
