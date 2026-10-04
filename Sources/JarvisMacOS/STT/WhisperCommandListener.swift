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
    /// True while a Rust recording is live — read by the AppState VAD tick to
    /// decide whether a core-busy retry is still needed.
    var isUtteranceActive: Bool { utteranceActive }
    /// Max seconds a command utterance may hold the core before it is
    /// force-finalized (prevents an abandoned claim wedging the pill).
    /// 30 s > longest legit enrollment phrase, < Rust 300 s ring cap.
    private let maxUtteranceSeconds: TimeInterval = 30

    private init() {}

    /// Voice detected. Starts a core recording unless a pill owns the core.
    /// Safe to call repeatedly: re-entrant while recording just extends the
    /// failsafe window check (no double-start, no wedge).
    /// While DictationController holds a pill (⌘⇧D / ⌘⇧A), VAD claims are
    /// muted at the AppState.handleAudioLevel layer and never reach here —
    /// that mute is what lets the pills win the core race. This guard is
    /// belt and braces for any direct caller.
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
            // Quiet-period after a pill preempt refuses inside claimForCommand
            // — don't spam the drop log for the expected race; VAD resumes
            // on the next ticks once the pill owns or releases the core.
            if Date() < STTRouter.shared.suppressCommandClaimsUntil { return }
            STTRouter.shared.logCommandDrop(reason: "core busy (owner: \(STTRouter.shared.owner), phase: \(get_app_phase()))")
            return
        }
        // A pill owns the core (⌘⇧D / ⌘⇧A active): never steal it back.
        // The VAD mute in handleAudioLevel normally prevents reaching here.
        guard STTRouter.shared.owner == .command else {
            STTRouter.shared.releaseFromCommand()
            return
        }
        // Reloading after an idle-unload (model Loading/Unloading): the core
        // will be Ready in seconds — release and retry on the next VAD tick
        // instead of logging a "not ready" drop.
        let modelPhase = get_model_phase()
        if modelPhase == .Loading || modelPhase == .Unloading {
            STTRouter.shared.logCommandDrop(reason: "model reloading (phase: \(modelPhase)) — retrying")
            STTRouter.shared.releaseFromCommand()
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
        let startBegan = Date()
        let started = start_recording()
        // Measured around the call: the tail of the pre-roll that the Rust
        // stream already captured — dropping exactly this span is what makes
        // the splice gap-free AND duplicate-free.
        let startLatency = Date().timeIntervalSince(startBegan)
        utteranceActive = started
        utteranceStartedAt = utteranceActive ? Date() : nil
        if utteranceActive {
            primeWithPreRoll(startLatency: startLatency)
        } else {
            STTRouter.shared.logCommandDrop(reason: "start_recording refused (phase: \(get_app_phase()))")
            STTRouter.shared.releaseFromCommand()
        }
    }

    // MARK: - Pre-roll splice

    /// 0.7 s covers the measured 250–400 ms VAD onset latency plus stream
    /// build time with margin; tune from the log line below on real use.
    private static let preRollSeconds: Double = 0.7
    private static let sttSampleRate: Double = 16_000

    /// The wake path starts recording REACTIVELY — the VAD only fires after
    /// the smoothed level crosses the threshold, so the audio before that
    /// moment exists only in MicManager's ring. Without this splice the "Jar-"
    /// of "Jarvis" is gone and the transcript reads "vis open chrome".
    private func primeWithPreRoll(startLatency: TimeInterval) {
        let preRoll = MicManager.shared.snapshotRecentSamples(
            durationSeconds: Self.preRollSeconds,
            targetSampleRate: Self.sttSampleRate)
        guard !preRoll.isEmpty else {
            NSLog("[Voice] pre-roll: empty snapshot (mic ring not warm?) — proceeding unprimed")
            return
        }

        // Drop the last `startLatency` seconds of the snapshot: the Rust
        // stream already has that span (it started when start_recording()
        // returned), so [pre-roll minus tail] ++ [stream] is contiguous.
        let duplicateCount = min(preRoll.count, Int(startLatency * Self.sttSampleRate))
        let splice = duplicateCount > 0 ? Array(preRoll.dropLast(duplicateCount)) : preRoll
        guard !splice.isEmpty else {
            NSLog("[Voice] pre-roll: fully overlapped by stream (latency %.0f ms) — nothing to inject",
                  startLatency * 1000)
            return
        }

        let injected = splice.withUnsafeBufferPointer { buffer -> UInt32 in
            guard let base = buffer.baseAddress else { return 0 }
            return prime_recording(base, UInt(buffer.count))
        }
        NSLog("[Voice] pre-roll: injected %d/%d samples (start latency %.0f ms, %.0f ms of audio)",
              Int(injected), preRoll.count, startLatency * 1000, Double(injected) / (Self.sttSampleRate / 1000))
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

    /// Abandon path (mic stop / mode toggle / pill preempt): drops the VAD
    /// session flags with NO inference and NO callback — the utterance never
    /// existed. The router calls cancel_recording() itself to finish the
    /// Rust-side audio and release the claim so the pill can start now.
    func cancelUtterance() {
        utteranceActive = false
        utteranceStartedAt = nil
    }

    /// Hard reset (mic stop / shutdown): cancels the Rust recording with NO
    /// inference and NO callback, then releases the claim. Use when the
    /// utterance must never produce a transcript (mic off, app exit).
    func reset() {
        if utteranceActive {
            utteranceActive = false
            utteranceStartedAt = nil
            cancel_recording()
        }
        STTRouter.shared.releaseFromCommand()
    }
}
