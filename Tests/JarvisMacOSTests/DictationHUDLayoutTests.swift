import XCTest
@testable import JarvisMacOS

final class DictationHUDLayoutTests: XCTestCase {
    func testLongOriginalReservesStableSpaceWithoutGrowingBeyondTextLimit() {
        let long = Array(repeating: "A much longer original transcript to read and scroll.", count: 100).joined(separator: " ")
        let height = DictationHUDLayout.textHeight(transcript: "Short result.", original: long, showsOriginal: true)
        XCTAssertEqual(height, DictationHUDLayout.maximumTextHeight)
        let compact = DictationHUDLayout.transcriptSize(transcript: "Short result.", original: long, showsOriginal: false, notice: "")
        let expanded = DictationHUDLayout.transcriptSize(transcript: "Short result.", original: long, showsOriginal: true, notice: "")
        XCTAssertGreaterThan(expanded.height, compact.height)
        XCTAssertLessThan(expanded.height, 400)
        XCTAssertEqual(expanded.width, 460)
    }
    func testAccessibilityNoticeAddsItsFullMeasuredHeight() {
        let notice = "Automatic paste needs Accessibility. Enable Jarvis in macOS Settings, or copy the text to paste it yourself."
        let base = DictationHUDLayout.transcriptSize(transcript: "Hello.", original: "", showsOriginal: false, notice: "")
        let warning = DictationHUDLayout.transcriptSize(transcript: "Hello.", original: "", showsOriginal: false, notice: notice)
        XCTAssertEqual(warning.height - base.height, 12 + DictationHUDLayout.noticeHeight(notice))
        XCTAssertEqual(base.width, warning.width)
    }
}
