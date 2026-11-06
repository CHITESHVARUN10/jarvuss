import XCTest
import CryptoKit
@testable import JarvisMacOS

/// Offline mapping of saved serving predictions. Never opens apps or executes
/// actions. Raw model accuracy remains independently reported by Python.
final class GeneralizationServingTests: XCTestCase {
    func testMapSavedServingPredictions() throws {
        guard let list = ProcessInfo.processInfo.environment["JARVIS_INTENT_EVALUATIONS"] else {
            throw XCTSkip("Set JARVIS_INTENT_EVALUATIONS to a JSON array of evaluation paths")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(list.utf8))
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let suites = report["suites"] as! [String: [String: Any]]
            var output: [String: Any] = [:]
            for (name, suite) in suites {
                var correct = 0, mappable = 0, recovered = 0, lost = 0
                var results: [[String: Any]] = []
                for row in suite["rows"] as! [[String: Any]] {
                    let text = row["text"] as! String
                    let expected = IntentActionMapper.map(row["expected"] as! [[String: Any]], sourceText: text)
                    let predicted = (row["predicted"] as? [[String: Any]]).flatMap { IntentActionMapper.map($0, sourceText: text) }
                    let raw = row["exact"] as! Bool
                    let match = expected != nil && predicted == expected
                    mappable += expected == nil ? 0 : 1
                    correct += match ? 1 : 0
                    recovered += match && !raw ? 1 : 0
                    lost += raw && !match ? 1 : 0
                    results.append(["text": text, "mapped_exact": match, "gold_mappable": expected != nil,
                                    "expected": expected.map { $0.map(\.description) } ?? [],
                                    "predicted": predicted.map { $0.map(\.description) } ?? []])
                }
                output[name] = ["count": results.count, "gold_mappable": mappable, "mapped_exact": correct,
                                "recovered_by_native": recovered, "raw_correct_but_unmappable": lost, "rows": results]
            }
            let artifact: [String: Any] = ["source_sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                           "suites": output, "scope": "Offline intent-to-action mapping; no actions executed"]
            let destination = URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("mapped.json")
            try JSONSerialization.data(withJSONObject: artifact, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
        }
    }
}
