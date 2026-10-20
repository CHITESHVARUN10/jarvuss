import Foundation

// SQL work is serialized on queue; configuration and toggles use stateLock.
final class DBManager: @unchecked Sendable {
    private struct Config: Sendable {
        let host: String
        let port: String
        let database: String
        let user: String
        let password: String?

        static func fromEnvironment() -> Config? {
            fromValues(mergedEnv())
        }

        static func fromValues(_ env: [String: String]) -> Config? {
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
            RuntimeConfiguration.mergedValues()
        }
    }

    static var missingEnvKeys: [String] { Config.missingEnvKeys }

    private let queue = DispatchQueue(label: "jarvis.postgres.queue")
    private let stateLock = NSLock()
    private var storedConfig: Config?
    private var storedLoggingEnabled = true
    private var config: Config? { stateLock.withLock { storedConfig } }

    init(configuration: [String: String]? = nil) {
        if let configuration { storedConfig = Config.fromValues(configuration) }
        else { storedConfig = Config.fromEnvironment() }
    }

    /// Kill-switch for the event-logging toggle in the Connections pane.
    /// When false, all PG writes are no-ops (local stats buffer unaffected).
    var loggingEnabled: Bool {
        get { stateLock.withLock { storedLoggingEnabled } }
        set { stateLock.withLock { storedLoggingEnabled = newValue } }
    }

    /// Re-read process env + the discovered `.env` after credentials are
    /// saved through the Connections pane. Serializes on the PG queue so no
    /// in-flight write observes a half-replaced config.
    func reloadConfiguration() {
        let updated = Config.fromEnvironment()
        stateLock.withLock { storedConfig = updated }
        setup()
    }

    var isConfigured: Bool {
        config != nil
    }

    func setup() {
        guard loggingEnabled, let config else {
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
        CREATE TABLE IF NOT EXISTS jarvis_usage_batches (
            id UUID PRIMARY KEY,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
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
        guard loggingEnabled, let config else { return }

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

    /// The batch ID and its delta are committed in one statement. Retrying
    /// after a lost response cannot count the same usage twice.
    static func dailyStatsSQL(_ batch: StatsBatch) -> String {
        let bucket = batch.bucket
        return """
        WITH accepted AS (
            INSERT INTO jarvis_usage_batches (id) VALUES ('\(batch.id.uuidString)'::uuid)
            ON CONFLICT (id) DO NOTHING RETURNING id
        )
        INSERT INTO jarvis_usage_stats (
            day, talk_secs, sessions, chars_dictated,
            tokens_prompt_est, tokens_completion_est,
            copies, commands_run, commands_failed, time_saved_secs
        ) SELECT
            DATE '\(bucket.day.replacingOccurrences(of: "'", with: "''"))',
            \(bucket.talkSecs), \(bucket.sessions), \(bucket.charsDictated),
            \(bucket.tokensPromptEst), \(bucket.tokensCompletionEst),
            \(bucket.copies), \(bucket.commandsRun), \(bucket.commandsFailed), \(bucket.timeSavedSecs)
        FROM accepted WHERE true
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
    }

    func upsertDailyStats(_ batch: StatsBatch) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard loggingEnabled, let config else {
                    continuation.resume(returning: false)
                    return
                }
                let result = runSQL(Self.dailyStatsSQL(batch), config: config)
                if result.0 != 0 { NSLog("[Stats] Database upload failed: %@", result.1) }
                continuation.resume(returning: result.0 == 0)
            }
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
        let result = runPSQL(sql, config: config)
        return result.status == 0 ? result.stdout : ""
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
        let result = runPSQL(sql, config: config)
        return (result.status, result.stderr)
    }

    private func runSQLQueryValue(_ sql: String, config: Config) -> String {
        runSQLQueryRows(sql, config: config)
    }

    private func runPSQL(_ sql: String, config: Config) -> ProcessOutput {
        let process = Process()
        let candidates = ["/opt/homebrew/bin/psql", "/opt/homebrew/opt/postgresql@18/bin/psql",
                          "/usr/local/bin/psql", "/usr/local/opt/postgresql@18/bin/psql", "/usr/bin/psql"]
        let executable = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/psql"
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-h", config.host, "-p", config.port, "-d", config.database, "-U", config.user,
                             "-X", "-w", "-v", "ON_ERROR_STOP=1", "-tA", "-F", "|", "-c", sql]
        var env = ProcessInfo.processInfo.environment
        env["PGCONNECT_TIMEOUT"] = "5"
        env["PGOPTIONS"] = (env["PGOPTIONS"] ?? "") + " -c statement_timeout=8000 -c standard_conforming_strings=on"
        if let password = config.password { env["PGPASSWORD"] = password }
        process.environment = env
        do { return try process.runCapturingOutput(timeout: 20) }
        catch { return ProcessOutput(status: -1, stdout: "", stderr: error.localizedDescription) }
    }

    private func escapeSQL(_ value: String) -> String {
        value.replacingOccurrences(of: "\0", with: "").replacingOccurrences(of: "'", with: "''")
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

        var sanitized: [String: String] = [:]
        for (key, value) in metadata {
            sanitized[key.replacingOccurrences(of: "\0", with: "")] = value.replacingOccurrences(of: "\0", with: "")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "NULL" }
        return "'\(escapeSQL(json))'::jsonb"
    }
}
