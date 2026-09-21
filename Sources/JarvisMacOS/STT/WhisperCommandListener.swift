import Foundation

/// Command-mode voice capture: VAD-segmented Whisper utterances.
///
/// AppState's existing voice-activity detector (MicManager levels) decides
/// utterance boundaries. This listener only owns the STT-core session:
/// - `beginUtterance()` on voice start → `start_recording()` (if core free)
/// - `endUtterance()` on silence → `stop_recording()` → final transcript
///   routes via STTRouter to AppState.handleTranscript(_, isFinal: true)
///
/// Enrollment matching, wake-word splitting, verification, and execution
/// all stay exactly as before — only the transcript source changed
/// (discrete Whisper finals instead of the Apple streaming recognizer).
final class WhisperCommandListener {
    static let shared = WhisperCommandListener()

    private var utteranceActive = false
    /// When the current utterance began (failsafe cap below).
    private var utteranceStartedAt: Date?
    /// Max seconds a command utterance may hold the core before it is
    /// force-finalized (prevents an abandoned claim wedging the pill).
    private let maxUtteranceSeconds: TimeInterval = 30

    private init() {}

    /// Voice detected. Starts a core recording unless the pill owns the core.
    /// Safe to call repeatedly: re-entrant while recording just extends the
    /// failsafe window check (no double-start, no wedge).
    func beginUtterance() {
        if utteranceActive {
            // Failsafe: a stuck utterance (VAD never saw silence) must not
            // hold the core forever — force-finalize so the transcript (or
            // error) routes and the claim releases.
            if let startedAt = utteranceStartedAt,
               Date().timeIntervalSince(startedAt) > maxUtteranceSeconds {
                endUtterance()
            }
            return
        }
        guard STTRouter.shared.claimForCommand() else {
            STTRouter.shared.logCommandDrop(reason: "core busy (owner: \(STTRouter.shared.owner), phase: \(get_app_phase()))")
            return
        }
        let phase = get_app_phase()
        guard phase == .Ready else {
            // Core busy or still loading — recover instead of wedging:
            // a stale TranscriptReady/Error (missed dismiss) is dismissed
            // once and the utterance retried on the next VAD tick.
            if phase == .TranscriptReady || phase == .Error {
                dismiss_transcript()
            } else {
                STTRouter.shared.logCommandDrop(reason: "model not ready (phase: \(phase))")
            }
            STTRouter.shared.releaseFromCommand()
            return
        }
        utteranceActive = start_recording()
        utteranceStartedAt = utteranceActive ? Date() : nil
        if !utteranceActive {
            STTRouter.shared.releaseFromCommand()
        }
    }

    /// Silence detected. Finishes the utterance; the transcript arrives
    /// asynchronously through BridgeCallbacks → STTRouter.
    func endUtterance() {
        guard utteranceActive else { return }
        utteranceActive = false
        utteranceStartedAt = nil
        stop_recording()
    }

    /// Pill preemption path: same as endUtterance (the router suppresses
    /// the result and starts the pill when it arrives).
    func endUtteranceSilently() {
        endUtterance()
    }

    /// Abandon path (mic stop / mode toggle): drops the audio with NO
    /// inference and NO callback — the utterance never existed. Also
    /// releases the router claim so the pill can claim immediately.
    /// NOTE: the preempt path calls endUtteranceSilently() right after this
    /// to finish the Rust-side audio — this only stops the VAD listener
    /// from firing further begins during the handoff.
    func cancelUtterance() {
        utteranceActive = false
        utteranceStartedAt = nil
    }

    /// Hard reset (mic stop / shutdown): cancels the Rust recording with NO
    /// inference and NO callback, then releases the claim. Use when the
    /// utterance must never produce a transcript (mic off, app exit).
    /// The pill-preempt path must NOT use this — it needs the silent final
    /// to trigger the pill start (see STTRouter.preemptCommandForPill).
    func reset() {
        if utteranceActive {
            utteranceActive = false
            utteranceStartedAt = nil
            cancel_recording()
        }
        STTRouter.shared.releaseFromCommand()
    }
}
