import Foundation

/// Single-owner arbitration for the Rust STT core.
///
/// The core supports ONE active recording. Two clients compete for it:
/// - `.pill` — push-to-talk dictation (⌘⇧D)
/// - `.command` — VAD-segmented voice-command utterances
///
/// All access happens on the main queue (VAD ticks, hotkey hops, and Rust
/// callbacks all land there), so no locking is needed.
final class STTRouter {
    static let shared = STTRouter()

    enum Owner {
        case none
        case pill
        case command
    }

    private(set) var owner: Owner = .none

    /// While true, command-mode VAD must not claim the STT core — the
    /// dictation pill owns it. Set by DictationController.startDictation,
    /// cleared by dismissTranscript. Level metering keeps running; only
    /// begin/endUtterance claims are suppressed. Lives here (not on the
    /// @MainActor AppState) so the nonisolated DictationController can
    /// flip it; all readers/writers already hop to main.
    var pillSuppressesCommandVAD = false

    /// Set when the pill preempts a command utterance: the in-flight
    /// command audio is finished silently and its result is dropped.
    private var suppressCommandResult = false
    /// Set alongside suppression: start the pill session once the core
    /// is free (i.e. when the suppressed result arrives).
    private var pendingPillAfterCommand = false

    /// Command-mode transcript sink (wired to AppState).
    var onCommandTranscript: ((String) -> Void)?
    /// Command-mode live partial sink (wired to AppState for the main-window
    /// "LIVE TRANSCRIPT" card). Fires per 6 s chunk while talking.
    var onCommandPartial: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    /// Throttled drop logging — VAD ticks fire ~20-45 Hz, so identical
    /// consecutive drops collapse to one line per 2 s.
    private var lastDropReason = ""
    private var lastDropAt = Date.distantPast

    func logCommandDrop(reason: String) {
        let now = Date()
        guard reason != lastDropReason || now.timeIntervalSince(lastDropAt) > 2.0 else { return }
        lastDropReason = reason
        lastDropAt = now
        onLog?("[STT] Command utterance dropped — \(reason)")
    }

    private init() {}

    // MARK: - Claims

    /// Pill wants to start. Returns true when ownership was granted.
    func claimForPill() -> Bool {
        guard owner == .none else { return false }
        owner = .pill
        return true
    }

    /// Command VAD wants to start an utterance. Returns true when granted.
    func claimForCommand() -> Bool {
        guard owner == .none else { return false }
        owner = .command
        return true
    }

    func releaseFromPill() {
        if owner == .pill { owner = .none }
    }

    func releaseFromCommand() {
        if owner == .command { owner = .none }
    }

    // MARK: - Preemption (pill steals an in-flight command utterance)

    /// Called from toggleDictation when a command utterance is recording.
    /// Finishes the command audio silently; the pill starts when the core
    /// reports back (suppressed result path below).
    /// Returns false if there was nothing to preempt.
    func preemptCommandForPill() -> Bool {
        guard owner == .command else { return false }
        suppressCommandResult = true
        pendingPillAfterCommand = true
        // Cancel the VAD listener first so no new begin/end fires mid-handoff,
        // then finish the in-flight audio silently.
        WhisperCommandListener.shared.cancelUtterance()
        WhisperCommandListener.shared.endUtteranceSilently()
        onLog?("[STT] Pill preempted a command utterance — finishing it silently.")
        // Fast path: short utterances produce NO final job (Rust empty-stop:
        // `needs_inference=false` emits no TranscribeChunk), so the
        // suppressed-result path below would never fire and the pill would
        // wait on the 1 s watchdog. When Rust isn't even recording, skip the
        // wait and start the pill immediately. Watchdog stays as backup.
        if get_app_phase() != .Recording {
            forceClearPreemption()
        }
        return true
    }

    /// Watchdog for the empty-stop wedge: when VAD produced too little audio
    /// the Rust core emits no final job (`needs_inference=false`), so the
    /// suppressed-result path above never fires. Call this after preemption
    /// to force-unwedge: clears the flags and starts the queued pill.
    /// Safe to call when no preemption is pending (no-op).
    func forceClearPreemption() {
        guard suppressCommandResult || pendingPillAfterCommand else { return }
        suppressCommandResult = false
        if owner == .command { owner = .none }
        startPendingPillIfNeeded()
    }

    // MARK: - Result routing (called from BridgeCallbacks on main)

    /// Route a final transcript. Returns the pill transcript when the
    /// result belongs to the pill, nil when consumed elsewhere/dropped.
    func routeTranscript(_ text: String) -> String? {
        switch owner {
        case .pill:
            return text
        case .command:
            owner = .none
            if suppressCommandResult {
                suppressCommandResult = false
                startPendingPillIfNeeded()
                return nil
            }
            onCommandTranscript?(text)
            return nil
        case .none:
            return nil
        }
    }

    /// Route a live partial (non-final chunk stitch). Pill shows the
    /// preview bubble; command mode forwards to the main-window card.
    /// Returns the pill preview text when the pill owns the core.
    func routePartial(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch owner {
        case .pill:
            return trimmed
        case .command:
            if suppressCommandResult { return nil }
            onCommandPartial?(trimmed)
            return nil
        case .none:
            return nil
        }
    }
    /// Route an error ("No speech detected", audio failures, ...).
    /// Returns the message when the pill should display it.
    func routeError(_ message: String) -> String? {
        switch owner {
        case .pill:
            return message
        case .command:
            owner = .none
            if suppressCommandResult {
                suppressCommandResult = false
                startPendingPillIfNeeded()
                return nil
            }
            // Silence blips must not pop error cards — just log.
            onLog?("[STT] Command utterance ended: \(message)")
            return nil
        case .none:
            return nil
        }
    }

    private func startPendingPillIfNeeded() {
        guard pendingPillAfterCommand else { return }
        pendingPillAfterCommand = false
        owner = .pill
        DictationController.shared.startPillRecording()
    }
}
