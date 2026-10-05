import XCTest
@testable import JarvisMacOS

final class DotEnvLoaderTests: XCTestCase {
    func testParseSkipsCommentsAndBlanks() {
        let parsed = DotEnvLoader.parse("# comment\n\nPGHOST=127.0.0.1\n")
        XCTAssertEqual(parsed, ["PGHOST": "127.0.0.1"])
    }

    func testParseTrimsKeysAndValues() {
        let parsed = DotEnvLoader.parse("  PGHOST  =  127.0.0.1  \n")
        XCTAssertEqual(parsed["PGHOST"], "127.0.0.1")
    }

    func testParseKeepsEqualsInsideValues() {
        let parsed = DotEnvLoader.parse("TOKEN=abc=def\n")
        XCTAssertEqual(parsed["TOKEN"], "abc=def")
    }

    func testParseSkipsMalformedLines() {
        let parsed = DotEnvLoader.parse("NOEQUALS\n=novalue\nGOOD=yes\n")
        XCTAssertEqual(parsed, ["GOOD": "yes"])
    }

    func testValuesReadsFromExtraSearchDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "JARVIS_TEST_DOTENV_KEY=hunter2\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let values = DotEnvLoader.values(extraSearchDirs: [dir])
        XCTAssertEqual(values["JARVIS_TEST_DOTENV_KEY"], "hunter2")
    }

    func testValuePrefersProcessEnvironment() {
        let key = "JARVIS_TEST_DOTENV_PRECEDENCE"
        setenv(key, "from-env", 1)
        defer { unsetenv(key) }

        let value = DotEnvLoader.value(for: key, extraSearchDirs: [])
        XCTAssertEqual(value, "from-env")
    }
}
