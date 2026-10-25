import Foundation

/// Creates the local Jarvis role + database on an already-running PostgreSQL
/// server. The administrator credentials are used only for provisioning;
/// the Jarvis role credentials are verified independently and saved by the UI.
enum PostgresProvisioner {
    struct Plan: Sendable {
        var database: String
        var user: String
        var password: String
        var port: String = "5432"
        var host: String = "127.0.0.1"
        var administrator: String = NSUserName()
        /// Credentials for the existing server, distinct from the new Jarvis role.
        var administratorPassword: String = ""
    }

    struct ProvisionedConnection {
        let message: String
        let password: String
    }

    enum ProvisionError: LocalizedError {
        case psqlNotFound
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .psqlNotFound:
                return "psql not found — install PostgreSQL first (brew install postgresql@18)."
            case .commandFailed(let detail):
                return detail
            }
        }
    }

    // MARK: - SQL builders (pure, unit-tested)

    /// Generate a command only when missing. Existing roles and passwords
    /// belong to the user and must survive a repeated setup attempt.
    static func createRoleSQL(user: String, password: String) -> String {
        """
        SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', \(quoteLiteral(user)), \(quoteLiteral(password)))
        WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = \(quoteLiteral(user)))
        \\gexec
        """
    }

    /// `CREATE DATABASE` must run outside a transaction. The wizard checks
    /// existence first and calls this only when missing.
    static func createDatabaseSQL(database: String, user: String) -> String {
        "CREATE DATABASE \(quoteIdentifier(database)) OWNER \(quoteIdentifier(user));"
    }

    static func databaseExistsQuery(database: String) -> String {
        "SELECT 1 FROM pg_catalog.pg_database WHERE datname = \(quoteLiteral(database));"
    }

    static func roleExistsQuery(user: String) -> String {
        "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = \(quoteLiteral(user));"
    }

    static func quoteIdentifier(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func quoteLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    /// Random, human-typeable password (no quote-unsafe characters).
    static func generatedPassword() -> String {
        // Ambiguous characters excluded so the wizard's editable field is
        // readable when the user wants to copy it elsewhere.
        let alphabet = Array("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<24).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Execution

    /// First-match psql discovery — same layout Homebrew uses, mirroring
    /// DBManager's candidate list plus initdb's (scripts/test_postgres.py).
    static func findPSQL() -> String? {
        let candidates = [
            "/opt/homebrew/bin/psql",
            "/opt/homebrew/opt/postgresql@18/bin/psql",
            "/usr/local/bin/psql",
            "/usr/local/opt/postgresql@18/bin/psql",
            "/usr/bin/psql",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? authorizedBinary(named: "psql")
    }

    private static func authorizedBinary(named name: String) -> String? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [name]
        guard let out = try? which.runCapturingOutput(timeout: 5),
              out.status == 0 else { return nil }
        let path = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Convenience check so the wizard renders the right row: is any local
    /// server answering on this host/port using trust auth?
    static func serverReachable(host: String = "127.0.0.1", port: String = "5432", administrator: String = NSUserName()) -> Bool {
        guard let psql = findPSQL() else { return false }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: psql)
        probe.arguments = [
            "-h", host, "-p", port, "-d", "postgres", "-U", administrator,
            "-X", "-w", "-tAc", "SELECT 1",
        ]
        probe.environment = ["PGCONNECT_TIMEOUT": "3", "PATH": "/usr/bin:/bin:/opt/homebrew/bin"]
        do {
            let result = try probe.runCapturingOutput(timeout: 8)
            let detail = result.stderr.lowercased()
            return (result.status == 0 && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1")
                || detail.contains("no password supplied") || detail.contains("password authentication failed")
                || (detail.contains("fatal:") && detail.contains("does not exist"))
        } catch {
            return false
        }
    }

    /// Compatibility entry point for callers that only need a summary.
    /// Setup uses provisionConnection so generated credentials can be saved.
    @discardableResult
    static func provision(_ plan: Plan) throws -> String {
        try provisionConnection(plan).message
    }

    static func provisionConnection(_ requested: Plan) throws -> ProvisionedConnection {
        var plan = requested
        guard let psql = findPSQL() else { throw ProvisionError.psqlNotFound }

        try validate(plan)

        let roleOutput = try run(psql, plan: plan, sql: roleExistsQuery(user: plan.user))
        let roleExists = roleOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        let dbOutput = try run(psql, plan: plan, sql: databaseExistsQuery(database: plan.database))
        let databaseExists = dbOutput.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"

        if !roleExists {
            if plan.password.isEmpty { plan.password = generatedPassword() }
            try run(psql, plan: plan, sql: createRoleSQL(user: plan.user, password: plan.password))
        }

        if !databaseExists {
            try run(psql, plan: plan, sql: createDatabaseSQL(database: plan.database, user: plan.user))
        }

        // Do not report success unless the application role can connect.
        // Existing passwords are preserved; Setup reuses saved credentials.
        try run(psql, plan: plan, sql: "SELECT 1;", verifyLogin: true)

        if roleExists && databaseExists {
            return ProvisionedConnection(message: "Verified role '\(plan.user)' and database '\(plan.database)' — nothing changed.", password: plan.password)
        }
        return ProvisionedConnection(message: "Created role '\(plan.user)' and database '\(plan.database)' (or verified they exist).", password: plan.password)
    }

    static func validate(_ plan: Plan) throws {
        guard [plan.database, plan.user].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 && !$0.contains("\0") }),
              !plan.password.contains("\0"),
              !plan.administrator.isEmpty, !plan.administrator.contains("\0"),
              !plan.administratorPassword.contains("\0"),
              let port = Int(plan.port), (1...65535).contains(port) else {
            throw ProvisionError.commandFailed(
                "Use database and role names of 1–63 bytes, a password without NUL bytes, and a valid port.")
        }
    }

    @discardableResult
    private static func run(_ psql: String, plan: Plan, sql: String, verifyLogin: Bool = false) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: psql)
        // SQL travels over stdin: passwords never appear in process arguments.
        process.arguments = ["-h", plan.host, "-p", plan.port,
            "-d", verifyLogin ? plan.database : "postgres", "-U", verifyLogin ? plan.user : plan.administrator,
            "-X", "-w", "-v", "ON_ERROR_STOP=1", "-tA", "-f", "-"]
        var environment = [
            "PGCONNECT_TIMEOUT": "5",
            "PGOPTIONS": "-c statement_timeout=15000 -c standard_conforming_strings=on",
            "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
        ]
        let password = verifyLogin ? plan.password : plan.administratorPassword
        if !password.isEmpty { environment["PGPASSWORD"] = password }
        process.environment = environment
        do {
            let result = try process.runCapturingOutput(timeout: 25, input: Data((sql + "\n").utf8))
            guard result.status == 0 else {
                let detail = [result.stderr, result.stdout].filter { !$0.isEmpty }.joined(separator: "\n")
                throw ProvisionError.commandFailed(connectionFailure(detail: detail, plan: plan, verifyLogin: verifyLogin))
            }
            return (result.stdout, result.stderr)
        } catch let error as ProvisionError {
            throw error
        } catch {
            throw ProvisionError.commandFailed(error.localizedDescription)
        }
    }

    static func connectionFailure(detail: String, plan: Plan, verifyLogin: Bool) -> String {
        let lower = detail.lowercased()
        if !verifyLogin && (lower.contains("no password supplied") || lower.contains("password authentication failed")) {
            return "PostgreSQL requires the existing server administrator's credentials. Enter the PostgreSQL administrator name and password in Setup. The Jarvis password field belongs to the application account, not the administrator."
        }
        if verifyLogin && (lower.contains("no password supplied") || lower.contains("password authentication failed")) {
            return "The existing Jarvis role '\(plan.user)' rejected this password. Enter its current password; setup preserves existing role passwords."
        }
        var redacted = detail
        for secret in [plan.password, plan.administratorPassword] where !secret.isEmpty {
            redacted = redacted.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return redacted.isEmpty ? "PostgreSQL command failed." : redacted
    }
}
