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
    private let recognizer: SFSpeechRecognizer?
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

    init(locale: Locale = Locale(identifier: "en-US")) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func requestPermission() async -> Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            return false
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
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
        guard recognizer?.isAvailable == true else {
            throw SpeechRecognitionError.recognizerUnavailable
        }

        // Increment session ID BEFORE cancelling old task so the old task's
        // cancel-error callback sees a stale ID and exits silently.
        currentSessionID += 1
        let capturedID = currentSessionID

        cancelDebounceTimer()
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if #available(macOS 13.0, *) {
            request.requiresOnDeviceRecognition = false
        }

        recognitionRequest = request

        NSLog("[Speech] NEW SESSION %d started", capturedID)

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            // Session ID guard — silently discard stale callbacks.
            guard self.currentSessionID == capturedID else { return }

            if let result {
                let transcript = result.bestTranscription.formattedString

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
                onError(error.localizedDescription)
            }
        }
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        recognitionRequest?.append(buffer)
    }

    func stopRecognition() {
        currentSessionID += 1   // invalidate any in-flight callbacks
        cancelDebounceTimer()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        lastPartialTranscript = ""
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
}
