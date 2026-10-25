import XCTest
@testable import JarvisMacOS

final class DatabaseIntegrationTests: XCTestCase {
    func testPasswordProtectedAdministratorAndGeneratedJarvisPassword() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JARVIS_TEST_PGHOST"], let data = env["JARVIS_TEST_PGDATA"] else {
            throw XCTSkip("Requires the disposable PostgreSQL test server.")
        }
        let psql = try XCTUnwrap(PostgresProvisioner.findPSQL())
        func execute(_ sql: String, as user: String = "jarvis_test", password: String = "") throws -> ProcessOutput {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: psql)
            process.arguments = ["-X", "-w", "-h", host, "-d", "postgres", "-U", user, "-v", "ON_ERROR_STOP=1", "-f", "-"]
            process.environment = ["PGPASSWORD": password, "PGCONNECT_TIMEOUT": "3"]
            return try process.runCapturingOutput(timeout: 10, input: Data(sql.utf8))
        }
        let admin = "jarvis_setup_admin"
        let user = "jarvis_setup_generated"
        XCTAssertEqual(try execute("CREATE ROLE \(admin) SUPERUSER LOGIN PASSWORD 'admin-test-password';").status, 0)
        let hba = URL(fileURLWithPath: data).appendingPathComponent("pg_hba.conf")
        let original = try String(contentsOf: hba, encoding: .utf8)
        defer {
            try? original.write(to: hba, atomically: true, encoding: .utf8)
            _ = try? execute("SELECT pg_reload_conf();")
        }
        try ("local all \(admin) scram-sha-256\nlocal all \(user) scram-sha-256\n" + original)
            .write(to: hba, atomically: true, encoding: .utf8)
        XCTAssertEqual(try execute("SELECT pg_reload_conf();").status, 0)
        var passwordRequired = false
        for _ in 0..<40 {
            if try execute("SELECT 1;", as: admin).status != 0 { passwordRequired = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(passwordRequired)
        var plan = PostgresProvisioner.Plan(database: "jarvis_setup_generated_db", user: user,
            password: "", host: host, administrator: admin)
        XCTAssertThrowsError(try PostgresProvisioner.provisionConnection(plan)) { error in
            XCTAssertTrue(error.localizedDescription.contains("administrator"))
        }
        plan.administratorPassword = "admin-test-password"
        let result = try PostgresProvisioner.provisionConnection(plan)
        XCTAssertEqual(result.password.count, 24, "Blank new-role passwords must generate usable credentials")
        plan.password = result.password
        XCTAssertNoThrow(try PostgresProvisioner.provisionConnection(plan))
        plan.password = "wrong-app-password"
        XCTAssertThrowsError(try PostgresProvisioner.provisionConnection(plan)) { error in
            XCTAssertTrue(error.localizedDescription.contains("existing Jarvis role"))
        }
        XCTAssertEqual(try execute("SELECT 1;", as: user, password: result.password).status, 0,
                       "Repeated setup must preserve the original role password")
    }

    func testSetupProvisioningHandlesQuotedValuesAndPreservesExistingRole() throws {
        guard let host = ProcessInfo.processInfo.environment["JARVIS_TEST_PGHOST"] else {
            throw XCTSkip("Requires the disposable PostgreSQL test server.")
        }
        XCTAssertTrue(PostgresProvisioner.serverReachable(host: host, administrator: "jarvis_test"))
        let plan = PostgresProvisioner.Plan(database: "setup\"db", user: "setup\"role",
            password: "p'$$\n\\quoted", host: host, administrator: "jarvis_test")
        try PostgresProvisioner.provision(plan)
        let psql = try XCTUnwrap(PostgresProvisioner.findPSQL())
        func passwordHash() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: psql)
            process.arguments = ["-X", "-w", "-h", host, "-U", "jarvis_test", "-d", "postgres", "-tAc",
                "SELECT rolpassword FROM pg_authid WHERE rolname = \(PostgresProvisioner.quoteLiteral(plan.user))"]
            let output = try process.runCapturingOutput(timeout: 10)
            XCTAssertEqual(output.status, 0)
            return output.stdout
        }
        let original = try passwordHash()
        XCTAssertFalse(original.isEmpty)
        var repeated = plan
        repeated.password = "a-different-password"
        try PostgresProvisioner.provision(repeated)
        XCTAssertEqual(try passwordHash(), original, "Repeating setup must preserve existing passwords")
    }

    func testAcknowledgedBatchRetryCountsOnceAndStatsQueryReturnsRows() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["JARVIS_TEST_PGHOST"] else {
            throw XCTSkip("Set JARVIS_TEST_PGHOST to an isolated test PostgreSQL socket directory.")
        }
        let manager = DBManager(configuration: ["PGHOST": host, "PGPORT": "5432",
                                                "PGDATABASE": "postgres", "PGUSER": "jarvis_test"])
        manager.setup()
        var day = DayBucket(day: DayBucket.dayString())
        day.commandsRun = 3
        let batch = StatsBatch(bucket: day)
        let first = await manager.upsertDailyStats(batch)
        let retry = await manager.upsertDailyStats(batch)
        XCTAssertTrue(first)
        XCTAssertTrue(retry)
        let rows = await manager.fetchDailyStats(sinceDays: 0)
        XCTAssertEqual(rows.first?.commandsRun, 3)

        manager.saveEvent(eventType: "enrollment_completed", transcript: "quotes ' and\nnewlines\0suffix",
                          metadata: ["line": "first\nsecond\0suffix", "quote": "a\"b\\c"])
        let eventSaved = await manager.hasEnrollmentCompletionEvent()
        XCTAssertTrue(eventSaved, "event metadata must be valid JSON even with control characters")

        manager.loggingEnabled = false
        let disabled = await manager.upsertDailyStats(StatsBatch(bucket: day))
        XCTAssertFalse(disabled, "disabled writes must not acknowledge pending usage")
    }
}
