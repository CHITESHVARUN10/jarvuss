import XCTest
@testable import JarvisMacOS

final class PureMigrationParityTests: XCTestCase {
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    func testFrozenSwiftBehavior() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_PURE_PARITY"] != nil else {
            throw XCTSkip("Opt-in migration differential suite")
        }
        TestSupport.pinRustPipelineOff()
        defer { TestSupport.unpinRustPipeline() }
        let dir = root.appendingPathComponent(".build/pure-migration")
        let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: dir.appendingPathComponent("inputs.json")))
        func row(_ text: String) -> [String: Any] {
            let selection = LocalSearchParser.selection(text)
            return ["text": text,
                    "volume": SystemVolumeParser.route(text)?.description ?? "<nil>",
                    "workspace": WorkspaceCommandParser.plan(text)?.map(\.description) ?? [],
                    "workspaceParse": WorkspaceCommandParser.parse(text)?.description ?? "<nil>",
                    "shuffle": SpotifyShuffleParser.parse(text)?.description ?? "<nil>",
                    "search": LocalSearchParser.search(text)?.description ?? "<nil>",
                    "selection": selection.map { "\($0.operation.rawValue):\($0.index)" } ?? "<nil>",
                    "clean": LocalSearchParser.clean(text),
                    "compact": TranscriptSanitizer.normalizeCompact(text),
                    "tokens": TranscriptSanitizer.normalizedTokens(from: text),
                    "spoken": TranscriptSanitizer.sanitizeSpokenCommand(text),
                    "wake": TranscriptSanitizer.containsWakeWord(text),
                    "targets": TranscriptSanitizer.normalizeMisheardTargets(in: text),
                    "fragment": TranscriptSanitizer.removeTrailingWakeWordFragment(from: text),
                    "words": TranscriptSanitizer.collapseRepeatedWords(text),
                    "phrases": TranscriptSanitizer.collapseRepeatedPhrases(text)]
        }
        let current = texts.map(row)
        let path = dir.appendingPathComponent("baseline.json")
        do {
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [[String: Any]])
            XCTAssertEqual(current.count, before.count)
            for (old, new) in zip(before, current) {
                for key in old.keys {
                    XCTAssertEqual(NSDictionary(dictionary: [key: old[key]!]), NSDictionary(dictionary: [key: new[key]!]), "\(key): \(old["text"]!)")
                }
            }
        }
    }
    func testRoutineAndVoicePolicyBaseline() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_PURE_PARITY"] != nil else { throw XCTSkip("Opt-in differential suite") }
        TestSupport.pinRustPipelineOff()
        defer { TestSupport.unpinRustPipeline() }
        let values = ["", "   ", "example.com", "HTTP://example.com", "https://example.com/a?x=1", "https://example.com/hello world", "https://例子.测试/路径", "javascript:alert(1)", "file:///tmp/a", "ftp://example.com", "/tmp/My Notes.pdf", "~/Desktop/a.txt", "relative.txt", "Brave", "Chrome", "VS Code", "unknown app", "open a new tab in Chrome", "open portfolio project in Finder", "open a new tab in Chrome and open a new window in Brave", "https://user:pass@example.com:443", "http://localhost:3000", "foo:123", "https://[::1]:8000", "https://example.com/a%20b"]
        var rows: [[String: Any]] = []
        for type in AutomationActionType.allCases {
            for value in values {
                let action = AutomationAction(type: type, value: value)
                rows.append(["type":type.rawValue, "value":value, "error":action.validationMessage ?? "<nil>", "url":action.websiteURL ?? "<nil>"])
            }
        }
        let samples = ["jarvis open Safari", "please open chant gpt jarvis", "thank you", "a little bit of a little bit of a little bit of", "Very good very good", "open Brief project in Finder", "open Chrome and open Safari", "set volume to twenty five percent", "open the file and then search for notes", "café café café", "hello, hello hello", "  ", "!!!open Notes"]
        for text in samples {
            var logs: [String] = []
            let segment = TranscriptSanitizer.cleanVoiceSegment(text, onLog: { logs.append($0) })
            rows.append(["voice":text, "result":segment ?? "<nil>", "logs":logs])
        }
        for batch in [["open Notes", "close Notes", "open Safari", "next", "next"], ["volume up", "volume up", "open Chrome", "close Chrome"], []] {
            var logs: [String] = []
            let result = TranscriptSanitizer.sanitizeBatch(batch, onLog: { logs.append($0) })
            rows.append(["batch":batch, "result":result, "logs":logs])
        }
        let path = root.appendingPathComponent(".build/pure-migration/routine-baseline.json")
        do {
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [[String:Any]])
            XCTAssertEqual(before.count, rows.count)
            for (a,b) in zip(before,rows) { XCTAssertEqual(NSDictionary(dictionary:a),NSDictionary(dictionary:b)) }
        }
    }

    func testUnicodeAndRepetitionBaseline() throws {
        guard ProcessInfo.processInfo.environment["JARVIS_PURE_PARITY"] != nil else { throw XCTSkip("Opt-in differential suite") }
        let texts = ["cafe\u{301} café cafe\u{301}", "ᾀ ᾀ ᾀ", "a\u{301}a a\u{301}a a\u{301}a", "go now GO NOW go now", "👩🏽‍💻 👩🏽‍💻 👩🏽‍💻", "--- café! --- café! --- café!", "alpha\tbeta alpha\tbeta alpha\tbeta", "Jarvis\nopen Notes", "𐐀 𐐨 𐐀", "a² a² a²", "aⅧ aⅧ aⅧ", "👩🏽‍💻 open Chrome", "¡¿open Notes", "𝄞open Notes", "go\nnow go\nnow go\nnow"]
        var rows:[[String:Any]] = []
        for text in texts {
            rows.append(["text":text,"tokens":TranscriptSanitizer.normalizedTokens(from:text),"spoken":TranscriptSanitizer.sanitizeSpokenCommand(text),"words":TranscriptSanitizer.collapseRepeatedWords(text),"phrases":TranscriptSanitizer.collapseRepeatedPhrases(text)])
        }
        let path = root.appendingPathComponent(".build/pure-migration/unicode-baseline.json")
        do {
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:path)) as? [[String:Any]])
            XCTAssertEqual(before.count,rows.count)
            for (a,b) in zip(before,rows) { XCTAssertEqual(NSDictionary(dictionary:a),NSDictionary(dictionary:b)) }
        }
    }

}
