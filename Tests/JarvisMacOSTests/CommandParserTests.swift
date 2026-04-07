import XCTest
@testable import JarvisMacOS

final class CommandParserTests: XCTestCase {
    private let parser = CommandParser()

    func testOpenApp() {
        XCTAssertEqual(parser.parse("open chrome"), .openApp("chrome"))
    }

    func testCreateFile() {
        XCTAssertEqual(parser.parse("create file test.txt"), .createFile("test.txt"))
    }

    func testOpenFolder() {
        XCTAssertEqual(parser.parse("open folder downloads"), .openFolder("downloads"))
    }

    func testFallsBackToAIQuery() {
        XCTAssertEqual(parser.parse("explain recursion"), .aiQuery("explain recursion"))
    }
}
