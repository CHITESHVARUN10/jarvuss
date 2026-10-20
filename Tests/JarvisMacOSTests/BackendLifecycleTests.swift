import XCTest
@testable import JarvisMacOS

/// Pins the backend lifecycle policy: mode persistence, the pure idle-stop
/// decision, and the Off-mode refusal of on-demand starts.
final class BackendLifecycleTests: XCTestCase {

    private func setTestMode(_ raw: String?) {
        if let raw {
            UserDefaults.standard.set(raw, forKey: BackendServiceManager.modeDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: BackendServiceManager.modeDefaultsKey)
        }
    }

    private var originalMode: String?

    override func setUp() {
        super.setUp()
        originalMode = UserDefaults.standard.string(forKey: BackendServiceManager.modeDefaultsKey)
    }

    override func tearDown() {
        setTestMode(originalMode)
        super.tearDown()
    }

    @MainActor
    func testConcurrentRequestsLaunchOnceAndRecoverAfterBackendDies() async {
        setTestMode(BackendMode.automatic.rawValue)
        var healthy = false
        var launches = 0
        let manager = BackendServiceManager(healthProbe: { healthy }, launcher: {
            launches += 1
            try? await Task.sleep(nanoseconds: 30_000_000)
            healthy = true
            return true
        })
        async let first = manager.startIfNeeded(log: { _ in })
        async let second = manager.startIfNeeded(log: { _ in })
        let results = await [first, second]
        XCTAssertTrue(results.allSatisfy(\.success))
        XCTAssertEqual(launches, 1)
        healthy = false
        let restarted = await manager.startIfNeeded(log: { _ in })
        XCTAssertTrue(restarted.success)
        XCTAssertEqual(launches, 2, "A dead backend must not be treated as still running")
    }

    @MainActor
    func testOffModeDoesNotProbeOrLaunch() async {
        setTestMode(BackendMode.off.rawValue)
        let manager = BackendServiceManager(healthProbe: {
            XCTFail("Off must not contact the backend")
            return true
        }, launcher: {
            XCTFail("Off must not launch Python")
            return true
        })
        let result = await manager.startIfNeeded(log: { _ in })
        XCTAssertFalse(result.success)
    }

    func testStalePidMustIdentifyTheJarvisHelperBeforeStopping() {
        XCTAssertTrue(BackendServiceManager.isBackendCommand("/path/python -m uvicorn voice_auth_service:app --port 8000"))
        XCTAssertFalse(BackendServiceManager.isBackendCommand("/path/python -m uvicorn another_app:app --port 8000"))
        XCTAssertFalse(BackendServiceManager.isBackendCommand("/Applications/Safari.app/Contents/MacOS/Safari"))
        XCTAssertFalse(BackendServiceManager.isBackendCommand("/path/python -m uvicorn voice_auth_service:app_wrong"))
    }

    func testDefaultModeIsAutomatic() {
        setTestMode(nil)
        XCTAssertEqual(BackendServiceManager.mode, .automatic)
    }

    func testModeRoundTripPerists() {
        setTestMode(BackendMode.off.rawValue)
        XCTAssertEqual(BackendServiceManager.mode, .off)
        setTestMode(BackendMode.always.rawValue)
        XCTAssertEqual(BackendServiceManager.mode, .always)
    }

    func testIdleStopDecisions() {
        let now = Date()
        let active = now.addingTimeInterval(-30)

        // Automatic + 30 s idle = keep running.
        XCTAssertFalse(BackendServiceManager.shouldIdleStop(mode: .automatic, lastActivity: active, now: now))
        // Automatic + past the interval = stop.
        XCTAssertTrue(
            BackendServiceManager.shouldIdleStop(
                mode: .automatic,
                lastActivity: now.addingTimeInterval(-BackendServiceManager.idleUnloadInterval - 1),
                now: now))
        // Always-running never idles out.
        XCTAssertFalse(
            BackendServiceManager.shouldIdleStop(
                mode: .always,
                lastActivity: now.addingTimeInterval(-10_000),
                now: now))
        // Off mode has nothing to idle out.
        XCTAssertFalse(
            BackendServiceManager.shouldIdleStop(
                mode: .off,
                lastActivity: now.addingTimeInterval(-10_000),
                now: now))
    }

    func testAncientActivityCountsAsIdle() {
        // .distantPast = no activity ever recorded — far past the interval.
        XCTAssertTrue(
            BackendServiceManager.shouldIdleStop(mode: .automatic, lastActivity: .distantPast))
    }
}

/// Postgres provisioning SQL: quoting and idempotency are contract-critical.
final class PostgresProvisionerTests: XCTestCase {

    func testExistingRolesArePreservedAndValuesStayOutsideDollarQuotedBlocks() {
        let sql = PostgresProvisioner.createRoleSQL(user: "u\"1", password: "p'$$w")
        XCTAssertTrue(sql.contains("format('CREATE ROLE %I LOGIN PASSWORD %L'"))
        XCTAssertTrue(sql.contains("'u\"1', 'p''$$w'"))
        XCTAssertTrue(sql.contains("WHERE NOT EXISTS"))
        XCTAssertTrue(sql.contains("\\gexec"))
        XCTAssertFalse(sql.contains("ALTER ROLE"))
        XCTAssertFalse(sql.contains("DO $$"))
    }

    func testRejectsTruncatedNamesAndNulBeforeProvisioning() {
        XCTAssertThrowsError(try PostgresProvisioner.validate(.init(database: String(repeating: "é", count: 32), user: "user", password: "p")))
        XCTAssertThrowsError(try PostgresProvisioner.validate(.init(database: "db", user: "u\0ser", password: "p")))
        XCTAssertNoThrow(try PostgresProvisioner.validate(.init(database: "db", user: "user", password: "p'$$\\q")))
    }

    /// Update path: after replacing the app the password field is blank and
    /// an existing role must be left untouched, so a blank password is valid.
    func testValidateAllowsBlankPasswordForExistingRoleUpdates() {
        XCTAssertNoThrow(try PostgresProvisioner.validate(.init(database: "db", user: "user", password: "")))
    }

    func testCreateDatabaseSQLEscapesIdentifiers() {
        let sql = PostgresProvisioner.createDatabaseSQL(database: "jar\"vis_db", user: "jarvis_user")
        XCTAssertEqual(sql, "CREATE DATABASE \"jar\"\"vis_db\" OWNER \"jarvis_user\";")
    }

    func testExistenceQueriesAreLiterals() {
        XCTAssertTrue(
            PostgresProvisioner.databaseExistsQuery(database: "jarvis_db")
                .contains("datname = 'jarvis_db'"))
        XCTAssertTrue(
            PostgresProvisioner.roleExistsQuery(user: "jarvis_user")
                .contains("rolname = 'jarvis_user'"))
    }

    func testGeneratedPasswordIsQuoteSafeAndSized() {
        for _ in 0..<20 {
            let password = PostgresProvisioner.generatedPassword()
            XCTAssertEqual(password.count, 24)
            XCTAssertFalse(password.contains("'"))
            XCTAssertFalse(password.contains("\""))
        }
        // Randomness sanity: two draws should differ.
        XCTAssertNotEqual(PostgresProvisioner.generatedPassword(),
                          PostgresProvisioner.generatedPassword())
    }
}
