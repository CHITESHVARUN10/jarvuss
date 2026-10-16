import XCTest
@testable import JarvisMacOS

final class DatabaseIntegrationTests: XCTestCase {
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

        manager.saveEvent(eventType: "enrollment_completed", transcript: "quotes ' and\nnewlines",
                          metadata: ["line": "first\nsecond", "quote": "a\"b\\c"])
        let eventSaved = await manager.hasEnrollmentCompletionEvent()
        XCTAssertTrue(eventSaved, "event metadata must be valid JSON even with control characters")

        manager.loggingEnabled = false
        let disabled = await manager.upsertDailyStats(StatsBatch(bucket: day))
        XCTAssertFalse(disabled, "disabled writes must not acknowledge pending usage")
    }
}
