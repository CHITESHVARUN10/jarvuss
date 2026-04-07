import Foundation

// MARK: - Response types

struct VoiceAuthVerifyResponse: Codable {
    let similarity: Double
    let max_similarity: Double?
    let avg_similarity: Double?
    let confidence: String?       // "strong", "low", "rejected", "none"
    let samples_compared: Int?
}

struct VoiceAuthEnrollResponse: Codable {
    let enrolled_count: Int
}

struct VoiceAuthStatsResponse: Codable {
    let enrolled_count: Int
}

// MARK: - Verification result (app-side)

struct VoiceVerificationResult {
    let similarity: Double          // weighted final score
    let maxSimilarity: Double
    let avgSimilarity: Double
    let confidence: VoiceConfidence
    let samplesCompared: Int
}

enum VoiceConfidence: String {
    case strong   = "strong"
    case low      = "low"
    case rejected = "rejected"
    case none     = "none"

    var displayLabel: String {
        switch self {
        case .strong:   return "Verified (Strong)"
        case .low:      return "Verified (Low Confidence)"
        case .rejected: return "Rejected"
        case .none:     return "No Profile"
        }
    }

    var emoji: String {
        switch self {
        case .strong:   return "✅"
        case .low:      return "⚠️"
        case .rejected: return "❌"
        case .none:     return "❌"
        }
    }
}

// MARK: - Errors

enum VoiceAuthClientError: LocalizedError {
    case invalidResponse
    case backendUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Voice auth service returned an invalid response."
        case .backendUnavailable:
            return "Voice auth service is unavailable at localhost:8000."
        }
    }
}

// MARK: - Client

final class VoiceAuthClient {
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!) {
        self.baseURL = baseURL
    }

    func enroll(audioFileURL: URL) async throws -> Int {
        let data = try await sendMultipartAudio(endpoint: "enroll", audioFileURL: audioFileURL)
        let decoded = try JSONDecoder().decode(VoiceAuthEnrollResponse.self, from: data)
        return decoded.enrolled_count
    }

    /// Legacy simple verify — returns just the similarity score.
    func verify(audioFileURL: URL) async throws -> Double {
        let result = try await verifyDetailed(audioFileURL: audioFileURL)
        return result.similarity
    }

    /// Detailed verify — returns weighted score, breakdown, and confidence.
    func verifyDetailed(audioFileURL: URL) async throws -> VoiceVerificationResult {
        let data = try await sendMultipartAudio(endpoint: "verify", audioFileURL: audioFileURL)
        let decoded = try JSONDecoder().decode(VoiceAuthVerifyResponse.self, from: data)

        let confidence: VoiceConfidence
        switch decoded.confidence {
        case "strong":   confidence = .strong
        case "low":      confidence = .low
        case "rejected": confidence = .rejected
        default:         confidence = .none
        }

        return VoiceVerificationResult(
            similarity: decoded.similarity,
            maxSimilarity: decoded.max_similarity ?? decoded.similarity,
            avgSimilarity: decoded.avg_similarity ?? decoded.similarity,
            confidence: confidence,
            samplesCompared: decoded.samples_compared ?? 0
        )
    }

    func reset() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("reset"))
        request.httpMethod = "POST"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw VoiceAuthClientError.invalidResponse
            }
        } catch {
            throw VoiceAuthClientError.backendUnavailable
        }
    }

    func enrolledCount() async throws -> Int {
        var request = URLRequest(url: baseURL.appendingPathComponent("stats"))
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw VoiceAuthClientError.invalidResponse
            }
            let decoded = try JSONDecoder().decode(VoiceAuthStatsResponse.self, from: data)
            return decoded.enrolled_count
        } catch {
            throw VoiceAuthClientError.backendUnavailable
        }
    }

    private func sendMultipartAudio(endpoint: String, audioFileURL: URL) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(endpoint))
        request.httpMethod = "POST"

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"sample.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw VoiceAuthClientError.invalidResponse
            }
            return responseData
        } catch {
            throw VoiceAuthClientError.backendUnavailable
        }
    }
}
