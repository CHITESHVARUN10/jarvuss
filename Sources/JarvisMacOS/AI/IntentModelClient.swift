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

    enum ClientError: Error {
        case unavailable
        case badStatus(Int)
        case badPayload
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil) {
        let configured = ProcessInfo.processInfo.environment["JARVIS_BACKEND_URL"]
            ?? ProcessInfo.processInfo.environment["BACKEND_BASE_URL"]
            ?? "http://127.0.0.1:8000"
        self.baseURL = baseURL ?? URL(string: configured) ?? URL(string: "http://127.0.0.1:8000")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        self.session = URLSession(configuration: config)
    }

    func parse(text: String) async throws -> ParsedResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("parse_intent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text])

        let (data, response) = try await session.data(for: request)
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
