import XCTest
@testable import JarvisMacOS

final class RuntimeConfigurationTests: XCTestCase {
    func testSavedSettingsAndKeychainOverrideOldLaunchEnvironment() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(["PGHOST": "new-host", "PGPASSWORD": "must-not-be-read"])
            .write(to: file)
        let values = RuntimeConfiguration.mergedValues(
            defaults: ["PGHOST": "old-host", "PGPASSWORD": "old-password"],
            settingsURL: file, secretReader: { $0 == "PGPASSWORD" ? "new-password" : nil })
        XCTAssertEqual(values["PGHOST"], "new-host")
        XCTAssertEqual(values["PGPASSWORD"], "new-password")
    }
}
