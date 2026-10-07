import XCTest
@testable import JarvisMacOS

/// The diagnostics line format: timestamped JSONL, nulls allowed (a pause
/// segment has no stop→transcript stamp), and a non-serializable payload
/// must fail closed instead of writing a broken line.
final class DictationDevLogTests: XCTestCase {

    func testLineIsTimestampedJSON() throws {
        let data = try XCTUnwrap(DictationDevLog.line(from: [
            "event": "dictation",
            "raw": "um so we ship friday",
            "words": 12,
            "polish_ms": 840,
            "stt_ms": NSNull(),
        ]))
        XCTAssertEqual(data.last, 0x0A, "one line per dictation")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["event"] as? String, "dictation")
        XCTAssertEqual(object["raw"] as? String, "um so we ship friday")
        XCTAssertEqual(object["words"] as? Int, 12)
        XCTAssertEqual(object["polish_ms"] as? Int, 840)
        XCTAssertTrue(object["stt_ms"] is NSNull, "pause segments have no STT stamp")
        XCTAssertNotNil(object["ts"] as? String)
    }

    func testUnserializablePayloadReturnsNil() {
        XCTAssertNil(DictationDevLog.line(from: ["bad": Date()]))
    }
}
