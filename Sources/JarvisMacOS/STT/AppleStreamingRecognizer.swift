import AVFoundation
import Speech

/// Results replace overlapping hypotheses; finalized words are never appended twice.
struct SpeechSegments {
    struct Segment { var start: Double; var end: Double; var text: String }
    private(set) var segments: [Segment] = []
    mutating func update(start: Double, end: Double, text: String) {
        guard start.isFinite, end.isFinite, end >= start else { return }
        segments.removeAll { $0.start == start || ($0.start < end && start < $0.end) }
        segments.append(Segment(start: start, end: end, text: text))
        segments.sort { $0.start < $1.start }
    }
    var text: String { segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// The audio tap never waits for recognition. Buffers are copied before the tap
/// returns, converted on one queue, and bounded at both admission and delivery.
final class SpeechAudioInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "jarvis.apple-speech.audio", qos: .userInitiated)
    private let slots = DispatchSemaphore(value: 16)
    private let lock = NSLock()
    private var active = true
    private var failed = false
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let format: AVAudioFormat
    private let failure: @Sendable (String) -> Void
    private var converter: AVAudioConverter?
    let stream: AsyncStream<AnalyzerInput>

    init(format: AVAudioFormat, failure: @escaping @Sendable (String) -> Void) {
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(64))
        stream = pair.stream; continuation = pair.continuation
        self.format = format; self.failure = failure
    }

    func ingest(_ source: AVAudioPCMBuffer) {
        lock.lock(); let accepts = active; lock.unlock()
        guard accepts else { return }
        // SpeechTranscriber's advertised formats are signed 16-bit mono.
        // AnalyzerInput traps on unsupported layouts instead of throwing.
        guard format.commonFormat == .pcmFormatInt16, format.channelCount == 1 else {
            fail("Unsupported Apple speech audio format."); return
        }
        guard slots.wait(timeout: .now()) == .success else { fail("Speech input could not keep up. Please try again."); return }
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            slots.signal(); fail("Could not copy microphone audio."); return
        }
        copy.frameLength = source.frameLength
        let sourceList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let targetList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (sourceBuffer, targetBuffer) in zip(sourceList, targetList) {
            if let src = sourceBuffer.mData, let dst = targetBuffer.mData {
                memcpy(dst, src, Int(sourceBuffer.mDataByteSize))
            }
        }
        queue.async { [self] in
            defer { slots.signal() }
            lock.lock(); let failed = failed; lock.unlock()
            guard !failed else { return }
            do {
                let output: AVAudioPCMBuffer
                if copy.format == format { output = copy }
                else {
                    if converter?.inputFormat != copy.format { converter = AVAudioConverter(from: copy.format, to: format) }
                    converter?.primeMethod = .none
                    guard let converter,
                          let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(copy.frameLength) * format.sampleRate / copy.format.sampleRate)) + 32)
                    else { throw MicManagerError.inputFailure("Unsupported speech audio format.") }
                    var supplied = false
                    var error: NSError?
                    let status = converter.convert(to: converted, error: &error) { _, inputStatus in
                        if supplied { inputStatus.pointee = .noDataNow; return nil }
                        supplied = true; inputStatus.pointee = .haveData; return copy
                    }
                    if let error { throw error }
                    guard status != .error else { throw MicManagerError.inputFailure("Speech audio conversion failed.") }
                    output = converted
                }
                guard output.frameLength > 0 else { return }
                if case .dropped = continuation.yield(AnalyzerInput(buffer: output)) {
                    fail("Speech recognition could not keep up with microphone audio. Please try again.")
                }
            } catch { fail(error.localizedDescription) }
        }
    }

    private func fail(_ message: String) {
        lock.lock(); let notify = !failed; failed = true; active = false; lock.unlock()
        if notify { continuation.finish(); failure(message) }
    }

    func finish() {
        // Stop accepting immediately, but drain previously accepted audio.
        lock.lock(); active = false; lock.unlock()
        queue.async { [continuation] in continuation.finish() }
    }
}

/// Apple on-device streaming for live commands. Push-to-talk keeps the existing
/// Whisper adapter. No cloud recognizer or third-party model is downloaded.
@MainActor
final class AppleStreamingRecognizer {
    static let shared = AppleStreamingRecognizer()
    private(set) var available = false
    private(set) var active = false
    private var locale: Locale?
    private var format: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var input: SpeechAudioInput?
    private var analysisTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var generation = UUID()
    private var preparationGeneration = UUID()
    private var segments = SpeechSegments()
    private var trace: PipelineTrace?
    private var reportedPartial = false
    var onPartial: ((String) -> Void)?
    var onFinal: ((String, PipelineTrace) -> Void)?
    var onError: ((String) -> Void)?

    static var preferred: Bool {
        (ProcessInfo.processInfo.environment["JARVIS_LIVE_SPEECH"] ?? UserDefaults.standard.string(forKey: "jarvis.liveSpeech.engine") ?? "apple") != "whisper"
    }

    func prepare() async throws {
        guard Self.preferred else { available = false; return }
        let preparation = UUID(); preparationGeneration = preparation
        available = false
        guard SpeechTranscriber.isAvailable else { throw MicManagerError.inputFailure("Apple on-device speech is unavailable on this Mac. Select Whisper in System settings.") }
        let requested = Locale(identifier: UserDefaults.standard.string(forKey: "jarvis.liveSpeech.locale") ?? "en-IN")
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw MicManagerError.inputFailure("Apple speech does not support \(requested.identifier). Choose a supported speech language or Whisper.")
        }
        guard preparationGeneration == preparation, !Task.isCancelled else { throw CancellationError() }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard preparationGeneration == preparation else { throw CancellationError() }
        guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MicManagerError.inputFailure("Apple speech has no compatible audio format.")
        }
        guard preparationGeneration == preparation, !Task.isCancelled else { throw CancellationError() }
        locale = supported; format = audioFormat; available = true
    }

    func begin() {
        guard available, !active, analyzer == nil, let locale, let format,
              !STTRouter.shared.pillSuppressesCommandVAD else { return }
        let token = UUID(); generation = token; active = true; segments = SpeechSegments(); reportedPartial = false
        Task { await InferenceBudget.shared.setSpeechActive(true) }
        let trace = PipelineTrace(source: "apple_live"); self.trace = trace
        trace.event("capture_started", fields: ["engine": "apple", "locale": locale.identifier])
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        self.analyzer = analyzer
        let input = SpeechAudioInput(format: format) { [weak self] error in
            Task { @MainActor in self?.fail(error, token: token) }
        }
        self.input = input
        // Include the onset preceding VAD without opening a second microphone.
        let samples = MicManager.shared.snapshotRecentSamples(durationSeconds: 0.5, targetSampleRate: 16_000)
        if !samples.isEmpty, let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
           let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) {
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            input.ingest(buffer)
        }
        // Prime before making the input visible to the tap: a concurrent tap
        // must never enqueue live audio ahead of the pre-roll.
        AppleSpeechAudioBridge.shared.set(input)
        resultTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.generation == token, !Task.isCancelled else { return }
                    if !self.reportedPartial {
                        self.reportedPartial = true; trace.event("first_partial")
                    }
                    self.segments.update(start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds, text: String(result.text.characters))
                    self.onPartial?(self.segments.text)
                }
            } catch { self?.fail(error.localizedDescription, token: token) }
        }
        analysisTask = Task { [weak self] in
            do { try await analyzer.prepareToAnalyze(in: format); try await analyzer.start(inputSequence: input.stream) }
            catch { self?.fail(error.localizedDescription, token: token) }
        }
    }

    func end() {
        guard active, let analyzer, let input else { return }
        active = false; AppleSpeechAudioBridge.shared.set(nil); input.finish()
        let token = generation
        trace?.event("capture_stopped")
        finishTask = Task { [weak self] in
            guard let self else { return }
            await self.analysisTask?.value
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                await self.resultTask?.value
                guard self.generation == token, !Task.isCancelled else { return }
                let text = self.segments.text
                let trace = self.trace ?? PipelineTrace(source: "apple_live")
                self.analyzer = nil; self.input = nil
                await InferenceBudget.shared.setSpeechActive(false)
                trace.event("transcript_final", fields: ["characters": String(text.count)], text: text)
                if !text.isEmpty { self.onFinal?(text, trace) }
            } catch { self.fail(error.localizedDescription, token: token) }
        }
        // A stuck OS service must not hold the session forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.generation == token, self.analyzer != nil else { return }
            self.fail("Apple speech did not finalize. Please try again.", token: token)
        }
    }

    func cancel() {
        preparationGeneration = UUID()
        generation = UUID(); active = false; AppleSpeechAudioBridge.shared.set(nil)
        Task { await InferenceBudget.shared.setSpeechActive(false) }
        input?.finish(); input = nil
        analysisTask?.cancel(); resultTask?.cancel(); finishTask?.cancel()
        let old = analyzer; analyzer = nil
        if let old { Task { await old.cancelAndFinishNow() } }
        trace?.event("capture_cancelled"); trace = nil
    }

    private func fail(_ message: String, token: UUID) {
        guard generation == token else { return }
        trace?.event("speech_failed", fields: ["reason": message])
        cancel(); onError?(message)
    }
}

/// Thread-safe handoff from MicManager's existing tap; never touches UI there.
final class AppleSpeechAudioBridge: @unchecked Sendable {
    static let shared = AppleSpeechAudioBridge()
    private let lock = NSLock()
    private var input: SpeechAudioInput?
    func set(_ input: SpeechAudioInput?) { lock.lock(); self.input = input; lock.unlock() }
    func ingest(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let current = input; lock.unlock(); current?.ingest(buffer)
    }
}
