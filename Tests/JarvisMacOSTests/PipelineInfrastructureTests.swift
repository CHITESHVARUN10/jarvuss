import AVFoundation
import XCTest
@testable import JarvisMacOS

final class PipelineInfrastructureTests: XCTestCase {
    func testStreamingHypothesesReplaceOverlapsAndKeepAdjacentSegments() {
        var segments = SpeechSegments()
        segments.update(start: 0, end: 1, text: "open")
        segments.update(start: 0, end: 1, text: "Open Chrome.")
        segments.update(start: 1, end: 2, text: "Then play music.")
        XCTAssertEqual(segments.text, "Open Chrome. Then play music.")
        segments.update(start: 0, end: 2, text: "Open Chrome, then play music.")
        XCTAssertEqual(segments.text, "Open Chrome, then play music.")
    }

    func testAudioIsCopiedAndFinishDrainsAcceptedBuffers() async throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let input = SpeechAudioInput(format: target) { _ in XCTFail("Unexpected conversion failure") }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for i in 0..<160 { buffer.floatChannelData![0][i] = 0.25 }
        input.ingest(buffer)
        for i in 0..<160 { buffer.floatChannelData![0][i] = 0.5 }
        input.ingest(buffer)
        input.finish()
        var values: [Float] = []
        for await audio in input.stream {
            let pcm = audio.buffer
            withExtendedLifetime(pcm) { values.append(Float(pcm.int16ChannelData![0][0]) / 32768) }
        }
        XCTAssertEqual(values, [0.25, 0.5])
    }

    func testBudgetCancellationDoesNotLeakCapacity() async throws {
        let budget = InferenceBudget(capacity: 1)
        let first = try await budget.acquire()
        let waiting = Task { try await budget.acquire() }
        await Task.yield()
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled admission succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        await budget.release(first)
        let next = try await budget.acquire()
        await budget.release(next)
    }

    func testOptionalInferenceRefusedDuringSpeechAndPressure() async throws {
        let budget = InferenceBudget()
        await budget.setSpeechActive(true)
        do { _ = try await budget.acquire(.optional); XCTFail("Formatting admitted during speech") } catch {}
        let interactive = try await budget.acquire(.interactive)
        await budget.release(interactive)
        await budget.setSpeechActive(false)
        await budget.setPressure(true)
        do { _ = try await budget.acquire(.optional); XCTFail("Formatting admitted under memory pressure") } catch {}
        await budget.setPressure(false)
        let optional = try await budget.acquire(.optional)
        await budget.release(optional)
    }

    func testDiagnosticRotationAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PipelineEventStore(directory: directory, limit: 1)
        store.append(["stage": "first"]); store.flush()
        store.append(["stage": "second"]); store.flush()
        let current = directory.appendingPathComponent("pipeline.jsonl")
        let previous = directory.appendingPathComponent("pipeline.previous.jsonl")
        XCTAssertTrue(try String(contentsOf: current).contains("second"))
        XCTAssertTrue(try String(contentsOf: previous).contains("first"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testReviewedCorrectionPersistsWithoutOverwriting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let correction = CommandCorrection(heard: "open chant gpt", intended: "open ChatGPT", cause: .transcription)
        try await correction.save(directory: directory)
        do { try await correction.save(directory: directory); XCTFail("Overwrote reviewed correction") } catch {}
        let url = directory.appendingPathComponent(correction.id.uuidString + ".json")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        XCTAssertEqual(saved["intended"] as? String, "open ChatGPT")
    }

    func testAcceptedRequestsAreNotReportedAsVerified() {
        XCTAssertEqual(ActionResult(action: .openURL("https://example.com"), success: true, message: "Opening").verification, .submitted)
        XCTAssertEqual(ControllerResult(message: "Failed", success: false, verification: .verified).verification, .failed)
    }

    func testGeneratedModelArgumentsCannotReplaceExplicitSongOrFilename() {
        XCTAssertEqual(IntentActionMapper.map([["name": "media.play_song", "args": ["title": "Invented"]]], sourceText: "play Rare Song by AB"), [.mediaControl(.playSong("Rare Song by AB"))])
        XCTAssertEqual(IntentActionMapper.map([["name": "file.create", "args": ["name": "wrong.txt"]]], sourceText: "create file CaseSensitive.TXT"), [.createFile("CaseSensitive.TXT")])
        XCTAssertEqual(IntentActionMapper.map([["name": "web.search", "args": ["engine": "Google", "query": "wrong"]]], sourceText: "search Google for CaseSensitive_API"), [.searchWeb(engine: "Google", query: "CaseSensitive_API")])
        XCTAssertEqual(IntentActionMapper.map([["name": "app.open", "args": ["name": "Spotify"]]], sourceText: "open Chrome"), [.openApp("Google Chrome")])
    }

    func testOldRoutineDefaultsToIndependentSteps() throws {
        let id = UUID()
        let data = Data("{\"id\":\"\(id)\",\"type\":\"pause\",\"value\":\"\"}".utf8)
        XCTAssertFalse(try JSONDecoder().decode(AutomationAction.self, from: data).requiresPreviousSuccess)
        let action = AutomationAction(type: .pause, requiresPreviousSuccess: true)
        XCTAssertTrue(try JSONDecoder().decode(AutomationAction.self, from: JSONEncoder().encode(action)).requiresPreviousSuccess)
    }

    @MainActor
    func testAppleStreamingFromSyntheticFileWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["JARVIS_APPLE_SPEECH_TEST_WAV"] else {
            throw XCTSkip("Set JARVIS_APPLE_SPEECH_TEST_WAV for the opt-in Apple service integration test.")
        }
        let recognizer = AppleStreamingRecognizer.shared
        let finished = expectation(description: "Apple streaming final")
        var transcript = ""
        recognizer.onFinal = { text, _ in transcript = text; finished.fulfill() }
        recognizer.onError = { error in XCTFail(error); finished.fulfill() }
        defer { recognizer.cancel(); recognizer.onFinal = nil; recognizer.onError = nil }
        try await recognizer.prepare()
        recognizer.begin()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            AppleSpeechAudioBridge.shared.ingest(buffer)
            try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
        }
        recognizer.end()
        await fulfillment(of: [finished], timeout: 12)
        XCTAssertTrue(transcript.lowercased().contains("portfolio"), transcript)
        XCTAssertTrue(transcript.lowercased().contains("brave"), transcript)
    }
}
