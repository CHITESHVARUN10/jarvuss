import Foundation

/// Single-owner arbitration for the Rust STT core.
///
/// The core supports ONE active recording. Three clients compete for it:
/// - `.pill` — push-to-talk dictation (⌘⇧D, voice-to-text only)
/// - `.action` — push-to-talk action pill (⌘⇧A, voice-to-command)
/// - `.command` — VAD-segmented voice-command utterances
///
/// All access happens on the main queue (VAD ticks, hotkey hops, and Rust
/// callbacks all land there), so no locking is needed.
final class STTRouter {
    static let shared = STTRouter()

    enum Owner {
        case none
        case pill
        case action
        case command
    }

    private(set) var owner: Owner = .none

    /// Either push-to-talk pill owns the core (dictate or action).
    var isModalOwner: Bool { owner == .pill || owner == .action }

    /// While true, command-mode VAD must not claim the STT core — a
    /// push-to-talk pill (dictate OR action) owns it. Set by
    /// DictationController.startDictation, cleared by dismissTranscript.
    /// Level metering keeps running; only begin/endUtterance claims are
    /// suppressed. Lives here (not on the @MainActor AppState) so the
    /// nonisolated DictationController can flip it; all readers/writers
    /// already hop to main.
    var pillSuppressesCommandVAD = false

    /// Set when the pill preempts a command utterance: the in-flight
    /// command audio is abandoned and its result (if any) is dropped.
    private var suppressCommandResult = false
    /// Set alongside suppression: start the pill session once the core
    /// is free (i.e. immediately after the cancel, or when the suppressed
    /// final of an already-inferring utterance arrives).
    private var pendingPillAfterCommand = false
    /// Bounded retries while waiting for the core to become Ready after
    /// a preempt (a command final may still be inferring).
    private var pendingPillRetries = 0
    /// Same, for the action pill (⌘⇧A). Only one modal can be pending —
    /// the controller abandons the other before setting these.
    private var pendingActionAfterCommand = false
    private var pendingActionRetries = 0
    /// VAD claims stay muted until this date (quiet-period after a preempt
    /// so the 8 s split's immediate re-begin can't steal the core back
    /// before the modal claim lands). Checked in claimForCommand.
    var suppressCommandClaimsUntil = Date.distantPast

    /// Action-pill transcript sink (wired to AppState — runs the command).
    var onActionTranscript: ((String) -> Void)?
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
    /// Refuses during the post-preempt quiet-period (VAD split re-begin
    /// racing the pill's claimForPill) and while the pill mutes VAD.
    func claimForCommand() -> Bool {
        guard Date() >= suppressCommandClaimsUntil else { return false }
        guard !pillSuppressesCommandVAD else { return false }
        guard owner == .none else { return false }
        owner = .command
        return true
    }

    func releaseFromPill() {
        if owner == .pill { owner = .none }
    }

    /// Action pill wants to start. Returns true when ownership was granted.
    func claimForAction() -> Bool {
        guard owner == .none else { return false }
        owner = .action
        return true
    }

    func releaseFromAction() {
        if owner == .action { owner = .none }
    }

    /// Release whichever modal owns the core (used when abandoning one
    /// pill to start the other).
    func releaseModalOwner() {
        if owner == .pill || owner == .action { owner = .none }
    }

    func releaseFromCommand() {
        if owner == .command { owner = .none }
    }

    // MARK: - Preemption (pill steals an in-flight command utterance)

    /// Called from toggleDictation/toggleAction when a command utterance
    /// is recording. AgentTalk parity: cancel the in-flight command audio
    /// instantly with NO inference (like AgentTalk's single-owner toggle —
    /// the old session is just abandoned), drop any late result, and start
    /// the pill now. Returns false if there was nothing to preempt.
    func preemptCommandForPill() -> Bool {
        guard owner == .command else { return false }
        suppressCommandResult = true
        pendingPillAfterCommand = true
        pendingPillRetries = 0
        // Mute VAD FIRST (before touching the utterance): the 4 s split's
        // immediate re-begin would otherwise re-claim .command before the
        // pill's claimForPill lands (seen in logs: preempt → split →
        // "core busy (owner: command)"). Meters keep running; claims don't.
        pillSuppressesCommandVAD = true
        // Quiet-period doubles the guard inside claimForCommand itself.
        suppressCommandClaimsUntil = Date().addingTimeInterval(0.5)
        // Abandon the VAD session AND the Rust-side audio instantly — NO
        // inference, NO callback wait. Waiting for a silent final (the old
        // behavior) left the pill dead whenever the empty-stop path emitted
        // no job; AgentTalk never waits, it just starts.
        WhisperCommandListener.shared.cancelUtterance()
        cancel_recording()
        owner = .none
        onLog?("[STT] Pill preempted a command utterance — abandoned instantly, starting pill.")
        startPendingPillIfNeeded()
        return true
    }

    /// Watchdog for the empty-stop wedge: when VAD produced too little audio
    /// the Rust core emits no final job (`needs_inference=false`), so the
    /// suppressed-result path above never fires. Call this after preemption
    /// to force-unwedge: clears the flags and starts the queued pill.
    /// Safe to call when no preemption is pending (no-op).
    func forceClearPreemption() {
        guard suppressCommandResult || pendingPillAfterCommand || pendingActionAfterCommand else { return }
        suppressCommandResult = false
        if owner == .command { owner = .none }
        startPendingPillIfNeeded()
        startPendingActionIfNeeded()
    }

    // MARK: - Result routing (called from BridgeCallbacks on main)

    /// Abandon whichever push-to-talk pill owns the core so the other
    /// can start now (switching ⌘⇧D → ⌘⇧A mid-recording or vice versa).
    /// No inference, no callback — the old session never existed. The
    /// caller claims its own ownership and starts fresh right after.
    func abandonModalForOtherPill() {
        pendingPillAfterCommand = false
        pendingPillRetries = 0
        pendingActionAfterCommand = false
        pendingActionRetries = 0
        suppressCommandResult = false
        WhisperCommandListener.shared.cancelUtterance()
        cancel_recording()
        releaseModalOwner()
    }

    /// Route a final transcript. Returns the pill transcript when the
    /// result belongs to a pill (dictate or action), nil when consumed
    /// elsewhere/dropped.
    func routeTranscript(_ text: String) -> String? {
        switch owner {
        case .pill, .action:
            return text
        case .command:
            owner = .none
            if suppressCommandResult {
                suppressCommandResult = false
                startPendingPillIfNeeded()
                startPendingActionIfNeeded()
                return nil
            }
            onCommandTranscript?(text)
            return nil
        case .none:
            return nil
        }
    }

    /// Route a live partial (non-final chunk stitch). Either pill shows
    /// the preview bubble; command mode forwards to the main-window card.
    /// Returns the pill preview text when a pill owns the core.
    func routePartial(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        switch owner {
        case .pill, .action:
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
    /// Returns the message when a pill should display it.
    func routeError(_ message: String) -> String? {
        switch owner {
        case .pill, .action:
            return message
        case .command:
            owner = .none
            if suppressCommandResult {
                suppressCommandResult = false
                startPendingPillIfNeeded()
                startPendingActionIfNeeded()
                return nil
            }
            // Silence blips must not pop error cards — just log.
            onLog?("[STT] Command utterance ended: \(message)")
            return nil
        case .none:
            return nil
        }
    }

    /// Action-pill twin of startPendingPillIfNeeded (⌘⇧A after preempt).
    func startPendingActionIfNeeded() {
        guard pendingActionAfterCommand else { return }
        guard get_app_phase() == .Ready else {
            pendingActionRetries += 1
            if pendingActionRetries > 20 {
                onLog?("[STT] Action start timed out waiting for Ready (phase: \(get_app_phase())) — press ⌘⇧A again.")
                pendingActionAfterCommand = false
                pendingActionRetries = 0
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startPendingActionIfNeeded()
            }
            return
        }
        pendingActionAfterCommand = false
        pendingActionRetries = 0
        owner = .action
        DictationController.shared.startActionRecording()
    }

    /// Preempt a command utterance for the ACTION pill (⌘⇧A twin of
    /// preemptCommandForPill). Instant abandon, no inference wait.
    func preemptCommandForAction() -> Bool {
        guard owner == .command else { return false }
        suppressCommandResult = true
        pendingActionAfterCommand = true
        pendingActionRetries = 0
        pillSuppressesCommandVAD = true
        suppressCommandClaimsUntil = Date().addingTimeInterval(0.5)
        WhisperCommandListener.shared.cancelUtterance()
        cancel_recording()
        owner = .none
        onLog?("[STT] Action preempted a command utterance — abandoned instantly, starting action pill.")
        startPendingActionIfNeeded()
        return true
    }

    private func startPendingPillIfNeeded() {
        guard pendingPillAfterCommand else { return }
        // Core may still be finishing (a command final already inferring):
        // cancel_recording dismisses Recording/Processing/Error → Ready, but
        // the callback round-trips async. Retry briefly instead of dying on
        // the first non-Ready poll — the pill must appear on this press.
        guard get_app_phase() == .Ready else {
            pendingPillRetries += 1
            if pendingPillRetries > 20 {
                onLog?("[STT] Pill start timed out waiting for Ready (phase: \(get_app_phase())) — press ⌘⇧D again.")
                pendingPillAfterCommand = false
                pendingPillRetries = 0
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startPendingPillIfNeeded()
            }
            return
        }
        pendingPillAfterCommand = false
        pendingPillRetries = 0
        owner = .pill
        DictationController.shared.startPillRecording()
    }
}
