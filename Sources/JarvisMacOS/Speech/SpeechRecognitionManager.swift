import Foundation
import Speech
import AVFoundation

enum SpeechRecognitionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case missingUsageDescription

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition permission denied. Enable it in System Settings > Privacy & Security > Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognizer is unavailable for the selected locale."
        case .missingUsageDescription:
            return "Missing `NSSpeechRecognitionUsageDescription` in app Info.plist. Launch as an app bundle with this key."
        }
    }
}

final class SpeechRecognitionManager {
    var onLog: ((String) -> Void)?

    private var recognizer: SFSpeechRecognizer?
    private let locale: Locale
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: - Session ID (Root-cause fix for transcript accumulation)
    //
    // SFSpeechRecognizer accumulates ALL speech in one session into a growing
    // transcript. If we keep the session alive across multiple utterances, the
    // second utterance's transcript includes everything from the first.
    //
    // Fix: increment `currentSessionID` every time we start a fresh session.
    // Every task callback captures its session ID at creation time. When the ID
    // no longer matches `currentSessionID`, the callback returns silently.
    // This also prevents the task-cancel error from reaching handleSpeechRecognizerError
    // and triggering an infinite restart loop.
    private var currentSessionID: Int = 0

    // MARK: - Silence debounce
    private var debounceTimer: Timer?
    private let silenceDebounceInterval: TimeInterval = 0.85
    private var lastPartialTranscript: String = ""

    // MARK: - Debug + fail-fast timers
    private var noSpeechTimer: Timer?
    private let noSpeechTimeout: TimeInterval = 4.0
    private var hasReceivedTranscript = false
    private var appendedBufferCount = 0
    private var loggedInputFormat = false

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    func requestPermission() async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            emit("[Speech][ERROR] Missing NSSpeechRecognitionUsageDescription")
            return false
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                self.emit("[Speech] Authorization status: \(status.rawValue)")
                switch status {
                case .authorized:
                    continuation.resume(returning: true)
                case .denied, .restricted, .notDetermined:
                    self.emit("[Speech][ERROR] Speech authorization is not granted")
                    continuation.resume(returning: false)
                @unknown default:
                    self.emit("[Speech][ERROR] Unknown speech authorization state")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Start a NEW recognition session.
    ///
    /// Each call increments the session ID so any in-flight callbacks from
    /// the previous session are silently dropped — preventing transcript
    /// accumulation and error-restart loops.
    func startRecognition(
        onResult: @escaping (_ transcript: String, _ isFinal: Bool) -> Void,
        onError: @escaping (_ message: String) -> Void
    ) throws {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            emit("[Speech][ERROR] Speech recognizer not authorized")
            throw SpeechRecognitionError.notAuthorized
        }

        hardResetSession()
        recognizer = SFSpeechRecognizer(locale: locale)

        guard recognizer?.isAvailable == true else {
            emit("[Speech][ERROR] Speech recognizer unavailable")
            throw SpeechRecognitionError.recognizerUnavailable
        }

        // Increment session ID BEFORE creating task so stale callbacks are ignored.
        currentSessionID += 1
        let capturedID = currentSessionID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = false
        }

        recognitionRequest = request
        hasReceivedTranscript = false
        appendedBufferCount = 0
        loggedInputFormat = false
        startNoSpeechTimer()

        NSLog("[Speech] NEW SESSION %d started", capturedID)
        emit("[Speech] Recognizing...")

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            // Session ID guard — silently discard stale callbacks.
            guard self.currentSessionID == capturedID else { return }

            if let result {
                let transcript = result.bestTranscription.formattedString
                self.hasReceivedTranscript = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if self.hasReceivedTranscript {
                    self.cancelNoSpeechTimer()
                    self.emit("[Speech] Transcript: \(transcript)")
                }

                if result.isFinal {
                    NSLog("[Speech] ✅ isFinal=true (session %d) → '%@'", capturedID, transcript)
                    self.cancelDebounceTimer()
                    self.lastPartialTranscript = ""
                    onResult(transcript, true)
                } else {
                    onResult(transcript, false)
                    self.lastPartialTranscript = transcript
                    self.resetDebounceTimer(onFire: {
                        let captured = self.lastPartialTranscript
                        guard !captured.isEmpty else { return }
                        NSLog("[Speech] ⏱ Silence debounce fired (session %d) → '%@'", capturedID, captured)
                        self.lastPartialTranscript = ""
                        onResult(captured, true)
                    })
                }
            }

            if let error {
                self.cancelDebounceTimer()
                self.cancelNoSpeechTimer()
                self.emit("[Speech][ERROR] \(error.localizedDescription)")
                onError(error.localizedDescription)
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let recognitionRequest else { return }

        appendedBufferCount += 1
        if appendedBufferCount == 1 {
            emit("[Speech] Mic active")
        }

        if !loggedInputFormat {
            let fmt = buffer.format
            emit("[Speech] Input format: \(fmt.sampleRate)Hz / \(fmt.channelCount)ch")
            loggedInputFormat = true
        }

        recognitionRequest.append(buffer)
    }

    func stopRecognition() {
        currentSessionID += 1   // invalidate any in-flight callbacks
        cancelNoSpeechTimer()
        cancelDebounceTimer()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        lastPartialTranscript = ""
        hasReceivedTranscript = false
        appendedBufferCount = 0
        loggedInputFormat = false
    }

    private func hardResetSession() {
        cancelNoSpeechTimer()
        cancelDebounceTimer()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        lastPartialTranscript = ""
        hasReceivedTranscript = false
        appendedBufferCount = 0
        loggedInputFormat = false
    }

    // MARK: - Debounce helpers

    private func resetDebounceTimer(onFire: @escaping () -> Void) {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(
            withTimeInterval: silenceDebounceInterval,
            repeats: false
        ) { _ in
            onFire()
        }
    }

    private func cancelDebounceTimer() {
        debounceTimer?.invalidate()
        debounceTimer = nil
    }

    private func startNoSpeechTimer() {
        cancelNoSpeechTimer()
        noSpeechTimer = Timer.scheduledTimer(withTimeInterval: noSpeechTimeout, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard !self.hasReceivedTranscript else { return }
            self.emit("[Speech][ERROR] No speech detected")
        }
    }

    private func cancelNoSpeechTimer() {
        noSpeechTimer?.invalidate()
        noSpeechTimer = nil
    }

    private func emit(_ message: String) {
        if let onLog {
            onLog(message)
        } else {
            print(message)
        }
    }
}
