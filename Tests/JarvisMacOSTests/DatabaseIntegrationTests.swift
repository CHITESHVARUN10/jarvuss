import XCTest
@testable import JarvisMacOS

final class DatabaseIntegrationTests: XCTestCase {
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
