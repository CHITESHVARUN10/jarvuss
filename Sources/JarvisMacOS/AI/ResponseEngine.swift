import Foundation
import AVFoundation

/// Generates human-readable text feedback and optional spoken responses.
///
/// Usage:
///   ResponseEngine.shared.respond(to: "Opening Chrome", speak: appState.voiceResponseEnabled)
@MainActor
final class ResponseEngine: ObservableObject {
    static let shared = ResponseEngine()

    @Published var lastResponse: String = ""
    @Published var isSpeaking: Bool = false

    private let synthesizer = AVSpeechSynthesizer()
    private var delegate: SpeechDelegate?

    private init() {
        delegate = SpeechDelegate(engine: self)
        synthesizer.delegate = delegate
    }

    /// Called with the text immediately before it is spoken aloud.
    /// AppState uses this to suppress TTS echo capture in the microphone.
    var onSpeak: ((String) -> Void)?

    /// Called when TTS finishes or is cancelled.
    /// AppState uses this to clear isTTSSpeaking and re-enable mic command processing.
    var onSpeakEnd: (() -> Void)?

    // MARK: - Public API

    /// Produce a text response (always) and optional spoken response.
    func respond(to text: String, speak: Bool = false) {
        lastResponse = text
        if speak && !text.isEmpty {
            speakText(text)
        }
    }

    /// Generate a natural response for a PlannedAction result.
    func respond(action: PlannedAction, result: ActionResult, speak: Bool) {
        let text = naturalResponse(for: action, result: result)
        respond(to: text, speak: speak)
    }

    /// Cancel any ongoing speech.
    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // MARK: - Natural language responses

    func naturalResponse(for action: PlannedAction, result: ActionResult) -> String {
        guard result.success else {
            return result.message
        }
        switch action {
        case .openApp(let name):        return "Opening \(name)"
        case .closeApp(let name):       return "Closing \(name)"
        case .openURL(let url):
            if let host = URL(string: url)?.host {
                return "Opening \(host)"
            }
            return "Opening website"
        case .searchWeb(_, let query):  return "Searching for \(query)"
        case .openFolder(let name):     return "Opening \(name) folder"
        case .openLatestFile(let f):    return "Opening latest file in \(f)"
        case .mediaControl(let a):
            switch a {
            case .play:                 return "Playing music"
            case .pause:                return "Music paused"
            case .nextTrack:            return "Next track"
            case .previousTrack:        return "Previous track"
            case .playLikedSongs:       return "Playing liked songs"
            case .playPlaylist(let n):  return "Playing \(n)"
            }
        case .volumeControl(let a):     return a.responseText
        case .createFile(let n):        return "Created file \(n)"
        case .createFolder(let n):      return "Created folder \(n)"
        case .aiQuery:                  return result.message
        case .installPreview(let p, _): return "Install preview for \(p)"
        }
    }

    // MARK: - TTS

    private func speakText(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        // Notify observer BEFORE speaking so the echo window starts in time.
        onSpeak?(text)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate  = 0.52
        utterance.pitchMultiplier = 1.05
        utterance.volume = 0.9
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        isSpeaking = true
        synthesizer.speak(utterance)
    }
}

// MARK: - Private delegate (keeps isSpeaking in sync)

private final class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    weak var engine: ResponseEngine?
    init(engine: ResponseEngine) { self.engine = engine }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            engine?.isSpeaking = false
            engine?.onSpeakEnd?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            engine?.isSpeaking = false
            engine?.onSpeakEnd?()
        }
    }
}
