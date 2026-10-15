import XCTest
@testable import JarvisMacOS

private final class TestDate: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    func read() -> Date { lock.withLock { date } }
    func advance() { lock.withLock { date.addTimeInterval(86_400) } }
}

private actor StatsUpload {
    private var continuation: CheckedContinuation<Bool, Never>?
    private(set) var submitted: [StatsBatch] = []
    func accept(_ batch: StatsBatch, started: XCTestExpectation) async -> Bool {
        submitted.append(batch)
        return await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish(_ success: Bool) { continuation?.resume(returning: success); continuation = nil }
}

final class StatsPersistenceTests: XCTestCase {
    private var directory: URL!
    private var store: StatsBufferStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = StatsBufferStore(fileURL: directory.appendingPathComponent("stats.json"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testMidnightRolloverPersistsBothDaysWithoutDeadlocking() throws {
        let clock = TestDate(Date(timeIntervalSince1970: 1_700_000_000))
        let recorder = StatsRecorder(buffer: store, now: { clock.read() }, retryInterval: 0)
        recorder.recordCommand(success: true)
        clock.advance()
        recorder.recordCommand(success: false)
        recorder.flush()
        let days = recorder.bufferedDays()
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days.map(\.commandsRun).reduce(0, +), 1)
        XCTAssertEqual(days.map(\.commandsFailed).reduce(0, +), 1)
        XCTAssertEqual(recorder.snapshot().day, DayBucket.dayString(clock.read()))
        XCTAssertEqual(try store.load().count, 2)
    }

    func testFailedUploadRetainsStableBatchForRelaunch() async throws {
        let recorder = StatsRecorder(buffer: store, retryInterval: 0)
        let attempted = expectation(description: "upload failed")
        recorder.onFlush = { _ in attempted.fulfill(); return false }
        recorder.recordCommand(success: true)
        recorder.flush()
        let original = try store.load()
        await fulfillment(of: [attempted], timeout: 1)
        XCTAssertEqual(recorder.bufferedDays().first?.commandsRun, 1)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded.map(\.id), original.map(\.id))
        XCTAssertEqual(reloaded.first?.bucket.commandsRun, 1)
    }

    func testAcknowledgementKeepsUsageRecordedDuringUpload() async throws {
        let recorder = StatsRecorder(buffer: store, retryInterval: 0)
        let upload = StatsUpload()
        let started = expectation(description: "first batch uploading")
        recorder.onFlush = { await upload.accept($0, started: started) }
        recorder.recordCommand(success: true)
        recorder.flush()
        await fulfillment(of: [started], timeout: 1)
        let firstID = try XCTUnwrap(store.load().first?.id)
        recorder.recordDictation(speechSecs: 2, chars: 10)
        recorder.flush()
        await upload.finish(true)
        for _ in 0..<100 {
            if recorder.bufferedDays().first?.commandsRun == 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let retained = try store.load()
        XCTAssertFalse(retained.contains { $0.id == firstID })
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.bucket.charsDictated, 10)
    }

    func testLegacyMigrationAssignsPersistentUploadIdentity() throws {
        let url = directory.appendingPathComponent("legacy.json")
        var day = DayBucket(day: "2026-10-15")
        day.commandsRun = 3
        try JSONEncoder().encode([day]).write(to: url)
        let legacy = StatsBufferStore(fileURL: url)
        let first = try legacy.load()
        XCTAssertEqual(first.first?.bucket.commandsRun, 3)
        XCTAssertEqual(try legacy.load().map(\.id), first.map(\.id))
    }

    func testPersistenceFailureRetainsInMemoryUsage() throws {
        let blocker = directory.appendingPathComponent("file")
        try Data().write(to: blocker)
        let recorder = StatsRecorder(buffer: StatsBufferStore(fileURL: blocker.appendingPathComponent("stats.json")),
                                     retryInterval: 0)
        recorder.recordCommand(success: true)
        recorder.flush()
        XCTAssertEqual(recorder.bufferedDays().first?.commandsRun, 1)
    }

    func testDatabaseRetryUsesSameBatchIDAndAtomicAcceptance() {
        let batch = StatsBatch(bucket: DayBucket(day: "2026-10-15"))
        let sql = DBManager.dailyStatsSQL(batch)
        XCTAssertTrue(sql.contains(batch.id.uuidString))
        XCTAssertTrue(sql.contains("ON CONFLICT (id) DO NOTHING RETURNING id"))
        XCTAssertTrue(sql.contains("FROM accepted"))
        XCTAssertEqual(DBManager.dailyStatsSQL(batch), sql)
    }
}
