import XCTest
@testable import JarvisMacOS

final class CrashDiagnosticsTests: XCTestCase {
    private var root: URL!
    private var diagnostics: CrashDiagnostics!
    private var apple: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-diagnostics-\(UUID().uuidString)")
        apple = root.appendingPathComponent("apple")
        try FileManager.default.createDirectory(at: apple, withIntermediateDirectories: true)
        diagnostics = CrashDiagnostics(directory: root.appendingPathComponent("logs"), appleDirectory: apple,
                                       processIsAlive: { $0 == 456 })
        diagnostics.start(captureOutput: false, installExceptionHandler: false, scheduleMaintenance: false)
    }
    override func tearDownWithError() throws {
        diagnostics = nil
        try FileManager.default.removeItem(at: root)
    }
    private func manifest(_ id: String) -> URL {
        diagnostics.directory.appendingPathComponent("sessions/\(id)/session.json")
    }
    private func writeSession(_ id: String, pid: Int32, status: String = "running", uuid: String = "ABC-123") throws {
        let session = DiagnosticSession(id: id, pid: pid, startedAt: .distantPast,
            build: DiagnosticBuild(revision: "old", builtAt: "yesterday", executableUUID: uuid,
                                   executablePath: "/Jarvis.app/Contents/MacOS/Jarvis", os: "macOS"), status: status)
        try FileManager.default.createDirectory(at: manifest(id).deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: manifest(id))
    }
    private func loadSession(_ id: String) throws -> DiagnosticSession {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticSession.self, from: Data(contentsOf: manifest(id)))
    }
    private func crash(pid: Int32 = 123, uuid: String = "abc-123", name: String = "Jarvis") throws -> Data {
        let body: [String: Any] = ["procName": name, "pid": pid,
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV"],
            "termination": ["indicator": "Segmentation fault: 11"],
            "usedImages": [["name": name, "uuid": uuid]], "faultingThread": 0,
            "threads": [["frames": [["symbol": "swift_getObjectType"], ["symbol": "NSViewResponder.platformCurrentEvent.getter"]]]]]
        return Data("{\"app_name\":\"Jarvis\"}\n".utf8) + (try JSONSerialization.data(withJSONObject: body))
    }

    func testParsesNativeMultiDocumentReportAndRejectsUnrelatedOrBrokenInput() throws {
        let parsed = try XCTUnwrap(AppleCrashSummary.parse(crash(), filename: "Jarvis-test.ips"))
        XCTAssertEqual(parsed.pid, 123)
        XCTAssertEqual(parsed.exception, "EXC_BAD_ACCESS")
        XCTAssertEqual(parsed.signal, "SIGSEGV")
        XCTAssertTrue(parsed.frames.contains("NSViewResponder.platformCurrentEvent.getter"))
        XCTAssertNil(AppleCrashSummary.parse(Data("broken".utf8), filename: "Jarvis-test.ips"))
        XCTAssertNil(try AppleCrashSummary.parse(crash(name: "OtherApp"), filename: "Jarvis-test.ips"))
    }

    func testExecutableIdentityIsFromTheLoadedMachO() {
        XCTAssertNotNil(UUID(uuidString: DiagnosticBuild.current.executableUUID))
    }

    func testEventsAreWrittenBeforeReturnAndStartIsIdempotent() throws {
        diagnostics.record("capture_requested", fields: ["mode": "dictate"])
        diagnostics.start(captureOutput: false, installExceptionHandler: false, scheduleMaintenance: false)
        let folders = try FileManager.default.contentsOfDirectory(at: diagnostics.directory.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        let data = try Data(contentsOf: folders[0].appendingPathComponent("events.jsonl"))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        XCTAssertEqual(event["event"] as? String, "capture_requested")
        let attributes = try FileManager.default.attributesOfItem(atPath: folders[0].appendingPathComponent("events.jsonl").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testNormalTerminationPersistsACleanExit() throws {
        diagnostics.markExit()
        let folders = try FileManager.default.contentsOfDirectory(at: diagnostics.directory.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try loadSession(folders[0].lastPathComponent).status, "clean_exit")
    }

    func testCleanAndMemoryGuardExitsRemainDistinct() throws {
        diagnostics.markExit(reason: "memory_guard")
        diagnostics.markExit()
        let folders = try FileManager.default.contentsOfDirectory(at: diagnostics.directory.appendingPathComponent("sessions"), includingPropertiesForKeys: nil)
        let record = try loadSession(folders[0].lastPathComponent)
        XCTAssertEqual(record.status, "planned_exit")
        XCTAssertEqual(record.exitReason, "memory_guard")
    }

    func testRecoveryAssociatesByPIDAndUUIDAndLeavesOtherLiveOrCleanSessionsAlone() throws {
        try writeSession("crashed", pid: 123)
        try writeSession("same-pid-other-binary", pid: 123, uuid: "different")
        try writeSession("killed-without-report", pid: 789)
        try writeSession("live", pid: 456)
        try writeSession("clean", pid: 777, status: "clean_exit")
        let filename = "Jarvis-2026-10-26-210446.ips"
        try crash().write(to: apple.appendingPathComponent(filename))
        diagnostics.collectReportsAndRecoverSessions()
        XCTAssertEqual(try loadSession("crashed").status, "crashed")
        XCTAssertEqual(try loadSession("crashed").crashReports, [filename])
        XCTAssertEqual(try loadSession("same-pid-other-binary").status, "unclean_exit")
        XCTAssertEqual(try loadSession("killed-without-report").status, "unclean_exit")
        XCTAssertEqual(try loadSession("live").status, "running")
        XCTAssertEqual(try loadSession("clean").status, "clean_exit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnostics.directory.appendingPathComponent("crashes/\(filename)").path))
        XCTAssertTrue(diagnostics.summary.contains("EXC_BAD_ACCESS / SIGSEGV"))
    }

    func testDelayedAppleReportUpgradesUncleanExitAndSurvivesSourceRotation() throws {
        try writeSession("late", pid: 123)
        diagnostics.collectReportsAndRecoverSessions()
        XCTAssertEqual(try loadSession("late").status, "unclean_exit")
        let file = apple.appendingPathComponent("Jarvis-2026-10-26-210446.ips")
        try crash().write(to: file)
        diagnostics.collectReportsAndRecoverSessions()
        XCTAssertEqual(try loadSession("late").status, "crashed")
        try FileManager.default.removeItem(at: file)
        diagnostics.collectReportsAndRecoverSessions()
        XCTAssertTrue(diagnostics.summary.contains("EXC_BAD_ACCESS"))
    }
}
