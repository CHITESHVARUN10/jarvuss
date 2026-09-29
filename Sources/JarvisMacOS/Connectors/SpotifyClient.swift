import Foundation

struct SpotifyStatus: Decodable {
    let clientPresent: Bool
    let accessPresent: Bool
    let expired: Bool
    let redirectUri: String?

    enum CodingKeys: String, CodingKey {
        case clientPresent = "client_id_present"
        case accessPresent = "access_token_present"
        case expired
        case redirectUri = "redirect_uri"
    }
}

struct SpotifyConnectURL: Decodable {
    let url: String
    let redirectUri: String?

    enum CodingKeys: String, CodingKey {
        case url
        case redirectUri = "redirect_uri"
    }
}

enum SpotifyClientError: LocalizedError {
    case backendUnavailable
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .backendUnavailable:
            return "Backend is unreachable at localhost:8000."
        case .saveFailed(let detail):
            return detail
        }
    }
}

final class SpotifyClient {
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!) {
        self.baseURL = baseURL
    }

    func status() async throws -> SpotifyStatus {
        var request = URLRequest(url: baseURL.appendingPathComponent("spotify/status"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SpotifyClientError.backendUnavailable
            }
            return try JSONDecoder().decode(SpotifyStatus.self, from: data)
        } catch is DecodingError {
            throw SpotifyClientError.backendUnavailable
        } catch {
            throw SpotifyClientError.backendUnavailable
        }
    }

    func saveCredentials(clientID: String, clientSecret: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("spotify/credentials"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            "client_secret": clientSecret.trimmingCharacters(in: .whitespacesAndNewlines),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? ""
            throw SpotifyClientError.saveFailed(detail.isEmpty ? "Save rejected." : detail)
        }
    }

    func connectURL() async throws -> URL {
        var request = URLRequest(url: baseURL.appendingPathComponent("spotify/connect-url"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SpotifyClientError.backendUnavailable
        }
        let decoded = try JSONDecoder().decode(SpotifyConnectURL.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw SpotifyClientError.backendUnavailable
        }
        return url
    }
}
