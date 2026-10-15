import AppKit
import Foundation

extension AppState {
    func refreshSpotifyStatus() async {
        do {
            let st = try await spotifyClient.status()
            spotifyExpired = st.expired
            spotifyLinked = st.clientPresent && st.accessPresent && !st.expired
            spotifyStatusText = !st.clientPresent ? "Keys missing"
                : st.expired ? "Token expired — reconnect"
                : "Connected"
            appendLog("[Spotify] Status: \(spotifyStatusText)")
        } catch {
            spotifyLinked = false
            spotifyStatusText = "Backend unreachable"
            appendLog("[Spotify] Status check failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connectors (PostgreSQL)

    /// Refresh from GET /postgres/status; prefills the Connections form
    /// (host/port/db/user — never the password) for editing.
    func refreshPostgresStatus() async {
        do {
            let st = try await postgresClient.status()
            postgresConfigured = st.configured
            postgresMissingKeys = st.missing
            postgresStatusText = st.configured ? "Configured"
                : st.missing.isEmpty ? "Not configured"
                : "Missing: \(st.missing.joined(separator: ", "))"
            if postgresConfigured {
                postgresForm = PostgresForm(
                    host: st.host, port: st.port,
                    database: st.database, user: st.user,
                    password: ""
                )
            }
            dbManager.reloadConfiguration()
            appendLog("[Postgres] Status: \(postgresStatusText)")
        } catch {
            postgresConfigured = false
            postgresStatusText = "Backend unreachable"
            appendLog("[Postgres] Status check failed: \(error.localizedDescription)")
        }
    }

    func savePostgresCredentials() async -> String {
        do {
            let msg = try await postgresClient.save(
                host: postgresForm.host, port: postgresForm.port,
                database: postgresForm.database, user: postgresForm.user,
                password: postgresForm.password
            )
            postgresForm.password = ""
            dbManager.reloadConfiguration()
            await refreshPostgresStatus()
            return msg
        } catch {
            return error.localizedDescription
        }
    }

    func testPostgresConnection() async -> String {
        do {
            return try await postgresClient.test()
        } catch {
            return error.localizedDescription
        }
    }

    /// Probe GET /api/tags (2 s timeout) — drives the Ollama chip.
    func refreshOllamaStatus() async {
        guard let url = URL(string: "http://127.0.0.1:11434/api/tags") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            ollamaReachable = ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
        } catch {
            ollamaReachable = false
        }
        ollamaStatusText = ollamaReachable ? "qwen2.5 · 1.5b instruct" : "Offline — commands still work"
    }

}
