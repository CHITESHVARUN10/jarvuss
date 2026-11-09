import XCTest
@testable import JarvisMacOS

final class RuntimeConfigurationTests: XCTestCase {
    func testRetiredSpotifySettingsAreIgnoredWithoutCredentialReads() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(["SPOTIFY_CLIENT_ID": "retired", "SPOTIFY_ACCESS_TOKEN": "retired-token"])
            .write(to: file)
        var reads: [String] = []
        let values = RuntimeConfiguration.mergedValues(defaults: ["SPOTIFY_CLIENT_SECRET": "retired-secret"],
            settingsURL: file, secretReader: { reads.append($0); return nil })
        XCTAssertFalse(values.keys.contains { $0.hasPrefix("SPOTIFY_") })
        XCTAssertEqual(reads, ["PGPASSWORD"])
    }
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
