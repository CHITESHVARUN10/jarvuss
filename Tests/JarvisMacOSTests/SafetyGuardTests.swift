import XCTest
@testable import JarvisMacOS

final class SafetyGuardTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestSupport.pinRustPipelineOff()
    }

    override func tearDown() {
        TestSupport.unpinRustPipeline()
        super.tearDown()
    }

    func testSudoBlocked() {
        assertBlocked(SafetyGuard.validate(rawCommand: "sudo rm -rf /"))
    }

    func testSuVariantsBlocked() {
        assertBlocked(SafetyGuard.validate(rawCommand: "su root"))
        assertBlocked(SafetyGuard.validate(rawCommand: "runas admin open chrome"))
    }

    func testDestructiveBlocked() {
        assertBlocked(SafetyGuard.validate(rawCommand: "delete my files"))
        assertBlocked(SafetyGuard.validate(rawCommand: "empty the trash"))
        assertBlocked(SafetyGuard.validate(rawCommand: "run mkfs on disk"))
    }

    func testInstallBecomesPreview() {
        switch SafetyGuard.validate(rawCommand: "brew install wget") {
        case .installPreview(let cmd, _):
            XCTAssertTrue(cmd.contains("wget"))
        default:
            XCTFail("expected installPreview")
        }
    }

    func testProtectedPathsBlocked() {
        assertBlocked(SafetyGuard.validate(rawCommand: "open /System/Library/file"))
        assertBlocked(SafetyGuard.validate(rawCommand: "create file /etc/passwd"))
    }

    func testBenignCommandsAllowed() {
        assertAllowed(SafetyGuard.validate(rawCommand: "open chrome"))
        assertAllowed(SafetyGuard.validate(rawCommand: "what time is it"))
        assertAllowed(SafetyGuard.validate(rawCommand: "play some jazz"))
    }

    func testPerActionValidation() {
        assertBlocked(SafetyGuard.validate(action: .aiQuery("sudo ls /")))
        assertAllowed(SafetyGuard.validate(action: .openApp("Spotify")))
        assertAllowed(SafetyGuard.validate(action: .mediaControl(.play)))
        assertAllowed(SafetyGuard.validate(action: .volumeControl(.mute)))
    }

    // MARK: - Helpers

    private func assertBlocked(_ verdict: SafetyVerdict, file: StaticString = #filePath, line: UInt = #line) {
        if case .blocked = verdict { return }
        XCTFail("expected blocked, got \(verdict)", file: file, line: line)
    }

    private func assertAllowed(_ verdict: SafetyVerdict, file: StaticString = #filePath, line: UInt = #line) {
        if case .allowed = verdict { return }
        XCTFail("expected allowed, got \(verdict)", file: file, line: line)
    }
}
