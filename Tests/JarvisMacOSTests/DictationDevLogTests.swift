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

    func testConcurrentWritesKeepCompleteTimestampedLines() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            DictationDevLog.append(["event": "test", "index": index], fileName: "test.jsonl", directory: directory)
        }
        DictationDevLog.flush()
        let lines = try String(contentsOf: directory.appendingPathComponent("test.jsonl"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 200)
        var indices = Set<Int>()
        for line in lines {
            let row = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertNotNil(row["ts"] as? String)
            indices.insert(try XCTUnwrap(row["index"] as? Int))
        }
        XCTAssertEqual(indices.count, 200)
    }

    func testUnserializablePayloadReturnsNil() {
        XCTAssertNil(DictationDevLog.line(from: ["bad": Date()]))
    }
}
