import Foundation

/// Editable Postgres connection form. The password field is write-only:
/// never filled from the backend, cleared after every save.
struct PostgresForm: Equatable {
    var host: String = ""
    var port: String = "5432"
    var database: String = ""
    var user: String = ""
    var password: String = ""
}

/// Presence-only Postgres status — never holds the password.
struct PostgresStatus {
    let configured: Bool
    let host: String
    let port: String
    let database: String
    let user: String
    let passwordPresent: Bool
    let missing: [String]
}

/// Backend Postgres endpoints: GET /postgres/status, POST /postgres/credentials,
/// POST /postgres/test. Mirrors the SpotifyClient shape.
final class PostgresClient {
    private let baseURL: URL

    init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!) {
        self.baseURL = baseURL
    }

    func status() async throws -> PostgresStatus {
        let data = try await get(path: "/postgres/status")
        let obj = try decode(data)
        return PostgresStatus(
            configured: obj["configured"] as? Bool ?? false,
            host: obj["host"] as? String ?? "",
            port: obj["port"] as? String ?? "",
            database: obj["database"] as? String ?? "",
            user: obj["user"] as? String ?? "",
            passwordPresent: obj["password_present"] as? Bool ?? false,
            missing: obj["missing"] as? [String] ?? []
        )
    }

    @discardableResult
    func save(host: String, port: String, database: String, user: String, password: String) async throws -> String {
        var payload: [String: String] = [
            "host": host.trimmingCharacters(in: .whitespaces),
            "port": port.trimmingCharacters(in: .whitespaces),
            "database": database.trimmingCharacters(in: .whitespaces),
            "user": user.trimmingCharacters(in: .whitespaces),
        ]
        if !password.isEmpty {
            payload["password"] = password
        }
        let data = try await post(path: "/postgres/credentials", payload: payload)
        let obj = try decode(data)
        if let detail = errorDetail(data) {
            throw PostgresClientError.server(detail)
        }
        return obj["message"] as? String ?? "Saved."
    }

    func test() async throws -> String {
        let data = try await post(path: "/postgres/test", payload: [:])
        let obj = try decode(data)
        if let detail = errorDetail(data) {
            throw PostgresClientError.server(detail)
        }
        return obj["message"] as? String ?? "OK."
    }

    // MARK: - Transport

    private func get(path: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PostgresClientError.transport("unexpected HTTP response")
            }
            return data
        } catch let error as PostgresClientError {
            throw error
        } catch {
            throw PostgresClientError.transport(error.localizedDescription)
        }
    }

    private func post(path: String, payload: [String: String]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw PostgresClientError.server(errorDetail(data) ?? "unexpected HTTP response")
            }
            return data
        } catch let error as PostgresClientError {
            throw error
        } catch {
            throw PostgresClientError.transport(error.localizedDescription)
        }
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PostgresClientError.transport("unparsable response")
        }
        return obj
    }

    private func errorDetail(_ data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
    }
}

enum PostgresClientError: Error, LocalizedError {
    case transport(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .transport(let msg): return "Backend unreachable: \(msg)"
        case .server(let msg):    return msg
        }
    }
}
