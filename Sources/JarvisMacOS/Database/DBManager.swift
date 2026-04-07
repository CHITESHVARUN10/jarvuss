import Foundation

final class DBManager {
    private struct Config {
        let host: String
        let port: String
        let database: String
        let user: String
        let password: String?

        static func fromEnvironment() -> Config? {
            let env = ProcessInfo.processInfo.environment
            guard
                let host = env["PGHOST"],
                let port = env["PGPORT"],
                let database = env["PGDATABASE"],
                let user = env["PGUSER"]
            else {
                return nil
            }

            return Config(
                host: host,
                port: port,
                database: database,
                user: user,
                password: env["PGPASSWORD"]
            )
        }
    }

    private let queue = DispatchQueue(label: "jarvis.postgres.queue")
    private let config = Config.fromEnvironment()

    var isConfigured: Bool {
        config != nil
    }

    func setup() {
        guard let config else {
            return
        }

        let sql = """
        CREATE TABLE IF NOT EXISTS jarvis_recognition_events (
            id BIGSERIAL PRIMARY KEY,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            event_type TEXT NOT NULL,
            transcript TEXT,
            target_phrase TEXT,
            score DOUBLE PRECISION,
            matched BOOLEAN,
            phrase_index INT,
            normalized_command TEXT,
            execution_result TEXT,
            metadata JSONB
        );
        """

        queue.async {
            _ = self.runSQL(sql, config: config)
        }
    }

    func saveEvent(
        eventType: String,
        transcript: String? = nil,
        targetPhrase: String? = nil,
        score: Double? = nil,
        matched: Bool? = nil,
        phraseIndex: Int? = nil,
        normalizedCommand: String? = nil,
        executionResult: String? = nil,
        metadata: [String: String]? = nil
    ) {
        guard let config else { return }

        let sql = """
        INSERT INTO jarvis_recognition_events (
            event_type,
            transcript,
            target_phrase,
            score,
            matched,
            phrase_index,
            normalized_command,
            execution_result,
            metadata
        ) VALUES (
            \(sqlString(eventType)),
            \(sqlOptionalString(transcript)),
            \(sqlOptionalString(targetPhrase)),
            \(sqlOptionalDouble(score)),
            \(sqlOptionalBool(matched)),
            \(sqlOptionalInt(phraseIndex)),
            \(sqlOptionalString(normalizedCommand)),
            \(sqlOptionalString(executionResult)),
            \(sqlOptionalJSON(metadata))
        );
        """

        queue.async {
            _ = self.runSQL(sql, config: config)
        }
    }

    func hasEnrollmentCompletionEvent() -> Bool {
        guard let config else { return false }

        let sql = "SELECT EXISTS (SELECT 1 FROM jarvis_recognition_events WHERE event_type = 'enrollment_completed');"
        let result = queue.sync {
            runSQLQueryValue(sql, config: config)
        }

        return result == "t" || result == "true" || result == "1"
    }

    private func runSQL(_ sql: String, config: Config) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/psql")
        if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/psql") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/psql")
        }

        process.arguments = [
            "-h", config.host,
            "-p", config.port,
            "-d", config.database,
            "-U", config.user,
            "-v", "ON_ERROR_STOP=1",
            "-c", sql
        ]

        var env = ProcessInfo.processInfo.environment
        if let password = config.password {
            env["PGPASSWORD"] = password
        }
        process.environment = env

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
            return (process.terminationStatus, errorOutput)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    private func runSQLQueryValue(_ sql: String, config: Config) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/psql")
        if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/psql") {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/psql")
        }

        process.arguments = [
            "-h", config.host,
            "-p", config.port,
            "-d", config.database,
            "-U", config.user,
            "-tAc", sql
        ]

        var env = ProcessInfo.processInfo.environment
        if let password = config.password {
            env["PGPASSWORD"] = password
        }
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return ""
        }
    }

    private func escapeSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func escapeJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func sqlString(_ value: String) -> String {
        "'\(escapeSQL(value))'"
    }

    private func sqlOptionalString(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return sqlString(value)
    }

    private func sqlOptionalDouble(_ value: Double?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    private func sqlOptionalBool(_ value: Bool?) -> String {
        guard let value else { return "NULL" }
        return value ? "TRUE" : "FALSE"
    }

    private func sqlOptionalInt(_ value: Int?) -> String {
        guard let value else { return "NULL" }
        return String(value)
    }

    private func sqlOptionalJSON(_ metadata: [String: String]?) -> String {
        guard let metadata, !metadata.isEmpty else {
            return "NULL"
        }

        let jsonBody = metadata
            .map { key, value in "\"\(escapeJSON(key))\":\"\(escapeJSON(value))\"" }
            .sorted()
            .joined(separator: ",")

        let json = "{\(jsonBody)}"
        return "'\(escapeSQL(json))'::jsonb"
    }
}
