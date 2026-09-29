import Foundation

final class DBManager {
    private struct Config {
        let host: String
        let port: String
        let database: String
        let user: String
        let password: String?

        static func fromEnvironment() -> Config? {
            let env = mergedEnv()
            guard
                let host = env["PGHOST"], !host.isEmpty,
                let port = env["PGPORT"], !port.isEmpty,
                let database = env["PGDATABASE"], !database.isEmpty,
                let user = env["PGUSER"], !user.isEmpty
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

        static var missingEnvKeys: [String] {
            let env = mergedEnv()
            return ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER"].filter { env[$0]?.isEmpty ?? true }
        }

        private static func mergedEnv() -> [String: String] {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in dotEnvValues() where merged[key]?.isEmpty ?? true {
                merged[key] = value
            }
            return merged
        }

        private static func dotEnvValues() -> [String: String] {
            let fm = FileManager.default
            var candidates: [URL] = []
            if let resourcePath = Bundle.main.resourcePath {
                candidates.append(URL(fileURLWithPath: resourcePath).appendingPathComponent("backend/.env"))
                candidates.append(URL(fileURLWithPath: resourcePath).appendingPathComponent(".env"))
            }
            if let executableURL = Bundle.main.executableURL {
                var dir = executableURL.deletingLastPathComponent()
                for _ in 0..<4 {
                    candidates.append(dir.appendingPathComponent(".env"))
                    dir = dir.deletingLastPathComponent()
                }
            }
            var cwdURL = URL(fileURLWithPath: fm.currentDirectoryPath)
            for _ in 0..<10 {
                candidates.append(cwdURL.appendingPathComponent(".env"))
                let parent = cwdURL.deletingLastPathComponent()
                if parent.path == cwdURL.path { break }
                cwdURL = parent
            }
            for fileURL in candidates {
                guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                var values: [String: String] = [:]
                for line in text.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
                }
                if !values.isEmpty { return values }
            }
            return [:]
        }
    }

    static var missingEnvKeys: [String] { Config.missingEnvKeys }

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
        CREATE TABLE IF NOT EXISTS jarvis_usage_stats (
            day DATE PRIMARY KEY,
            talk_secs DOUBLE PRECISION NOT NULL DEFAULT 0,
            sessions INT NOT NULL DEFAULT 0,
            chars_dictated INT NOT NULL DEFAULT 0,
            tokens_prompt_est INT NOT NULL DEFAULT 0,
            tokens_completion_est INT NOT NULL DEFAULT 0,
            copies INT NOT NULL DEFAULT 0,
            commands_run INT NOT NULL DEFAULT 0,
            commands_failed INT NOT NULL DEFAULT 0,
            time_saved_secs DOUBLE PRECISION NOT NULL DEFAULT 0
        );
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

    func upsertDailyStats(_ bucket: DayBucket) {
        guard let config else { return }
        let sql = """
        INSERT INTO jarvis_usage_stats (
            day, talk_secs, sessions, chars_dictated,
            tokens_prompt_est, tokens_completion_est,
            copies, commands_run, commands_failed, time_saved_secs
        ) VALUES (
            DATE '\(escapeSQL(bucket.day))',
            \(bucket.talkSecs), \(bucket.sessions), \(bucket.charsDictated),
            \(bucket.tokensPromptEst), \(bucket.tokensCompletionEst),
            \(bucket.copies), \(bucket.commandsRun), \(bucket.commandsFailed), \(bucket.timeSavedSecs)
        )
        ON CONFLICT (day) DO UPDATE SET
            talk_secs = jarvis_usage_stats.talk_secs + EXCLUDED.talk_secs,
            sessions = jarvis_usage_stats.sessions + EXCLUDED.sessions,
            chars_dictated = jarvis_usage_stats.chars_dictated + EXCLUDED.chars_dictated,
            tokens_prompt_est = jarvis_usage_stats.tokens_prompt_est + EXCLUDED.tokens_prompt_est,
            tokens_completion_est = jarvis_usage_stats.tokens_completion_est + EXCLUDED.tokens_completion_est,
            copies = jarvis_usage_stats.copies + EXCLUDED.copies,
            commands_run = jarvis_usage_stats.commands_run + EXCLUDED.commands_run,
            commands_failed = jarvis_usage_stats.commands_failed + EXCLUDED.commands_failed,
            time_saved_secs = jarvis_usage_stats.time_saved_secs + EXCLUDED.time_saved_secs;
        """
        queue.async {
            _ = self.runSQL(sql, config: config)
        }
    }

    func fetchDailyStats(sinceDays: Int) async -> [DayBucket] {
        guard let config else { return [] }
        let sql = "SELECT day::text, talk_secs, sessions, chars_dictated, tokens_prompt_est, tokens_completion_est, copies, commands_run, commands_failed, time_saved_secs FROM jarvis_usage_stats WHERE day >= CURRENT_DATE - INTERVAL '\(sinceDays) days' ORDER BY day ASC;"
        // NEVER queue.sync from @MainActor (boot deadlock: MainActor parks
        // behind a stalled psql on this serial queue). Async hop instead.
        let raw: String = await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.runSQLQueryRows(sql, config: config))
            }
        }
        var out: [DayBucket] = []
        for line in raw.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|")
            guard parts.count == 10 else { continue }
            out.append(DayBucket(
                day: parts[0],
                talkSecs: Double(parts[1]) ?? 0,
                sessions: Int(parts[2]) ?? 0,
                charsDictated: Int(parts[3]) ?? 0,
                tokensPromptEst: Int(parts[4]) ?? 0,
                tokensCompletionEst: Int(parts[5]) ?? 0,
                copies: Int(parts[6]) ?? 0,
                commandsRun: Int(parts[7]) ?? 0,
                commandsFailed: Int(parts[8]) ?? 0,
                timeSavedSecs: Double(parts[9]) ?? 0
            ))
        }
        return out
    }

    private func runSQLQueryRows(_ sql: String, config: Config) -> String {
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
            "--set", "connect_timeout=5",
            "--set", "statement_timeout=8000",
            "-tA", "-F", "|", sql
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

    /// Async (never blocks @MainActor): UserDefaults fast-path decides
    /// immediately; the DB check reconciles in the background via bootstrap.
    func hasEnrollmentCompletionEvent() async -> Bool {
        guard let config else { return false }

        let sql = "SELECT EXISTS (SELECT 1 FROM jarvis_recognition_events WHERE event_type = 'enrollment_completed');"
        let result: String = await withCheckedContinuation { cont in
            queue.async {
                cont.resume(returning: self.runSQLQueryValue(sql, config: config))
            }
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
            // Timeouts so a dead PG can't wedge the serial queue forever
            // (boot deadlock: MainActor parked behind a stalled psql).
            "-v", "connect_timeout=5",
            "-v", "statement_timeout=8000",
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
            "--set", "connect_timeout=5",
            "--set", "statement_timeout=8000",
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
