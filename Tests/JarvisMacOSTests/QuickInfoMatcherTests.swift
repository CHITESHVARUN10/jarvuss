import XCTest
@testable import JarvisMacOS

final class QuickInfoMatcherTests: XCTestCase {
    func testTimeQueries() {
        XCTAssertEqual(QuickInfoMatcher.match("what time is it"), .time)
        XCTAssertEqual(QuickInfoMatcher.match("tell me the time"), .time)
        XCTAssertEqual(QuickInfoMatcher.match("current time"), .time)
    }

    func testDateQueries() {
        XCTAssertEqual(QuickInfoMatcher.match("what is today's date"), .date)
        XCTAssertEqual(QuickInfoMatcher.match("todays date"), .date)
    }

    func testDayMonthYearQueries() {
        XCTAssertEqual(QuickInfoMatcher.match("what day is it"), .day)
        XCTAssertEqual(QuickInfoMatcher.match("what month is it"), .month)
        XCTAssertEqual(QuickInfoMatcher.match("what year is it"), .year)
    }

    func testDateBeatsDayOnOverlap() {
        // "what day is today" sits in both tables — date wins (historical).
        XCTAssertEqual(QuickInfoMatcher.match("what day is today"), .date)
    }

    func testNonQueriesReturnNil() {
        XCTAssertNil(QuickInfoMatcher.match("open chrome"))
        XCTAssertNil(QuickInfoMatcher.match("play some jazz"))
        XCTAssertNil(QuickInfoMatcher.match(""))
    }

    func testLooksCompound() {
        XCTAssertTrue(QuickInfoMatcher.looksCompound("what time is it and open chrome"))
        XCTAssertTrue(QuickInfoMatcher.looksCompound("tell me the time then pause"))
        XCTAssertFalse(QuickInfoMatcher.looksCompound("what time is it"))
        XCTAssertFalse(QuickInfoMatcher.looksCompound("tell me the time, please"))
    }

    func testSystemInfoMapping() {
        XCTAssertEqual(QuickInfoMatcher.systemInfoAction(for: .time), .currentTime)
        XCTAssertEqual(QuickInfoMatcher.systemInfoAction(for: .date), .currentDate)
        XCTAssertEqual(QuickInfoMatcher.systemInfoAction(for: .day), .currentDay)
        XCTAssertEqual(QuickInfoMatcher.systemInfoAction(for: .month), .currentMonth)
        XCTAssertEqual(QuickInfoMatcher.systemInfoAction(for: .year), .currentYear)
    }
}
