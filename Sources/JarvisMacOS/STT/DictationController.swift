import AppKit
import Combine
import SwiftUI

/// Dictation state + pill panel management (macOS 13 compatible).
///
/// Mirrors the proven AgentTalk HUD behavior:
/// ⌘⇧D toggles Recording → Transcribing → transcript card (Copy/Close),
/// copy auto-dismisses after 0.6 s. The Rust STT core owns the phase
/// machine; this controller mirrors it for UI and forwards user actions.
/// Which push-to-talk pill is active. Dictate (⌘⇧D) is voice-to-text
/// only — it never executes. Action (⌘⇧A) transcribes then runs the result
/// as a command (no wake word; verify per the user setting).
enum PillMode {
    case dictate
    case action
}

final class DictationController: ObservableObject {
    static let shared = DictationController()

    @Published var mode: PillMode = .dictate
    @Published var phase: AppPhase = .Idle
    @Published var modelPhase: ModelPhase = .NotInstalled
    @Published var transcript: String = ""
    @Published var partialTranscript: String = ""
    @Published var errorMessage: String = ""
    @Published var downloadProgress: Float = 0.0
    @Published var downloadSpeed: String = ""
    @Published var downloadRemaining: String = ""
    @Published var audioLevel: Float = 0.0
    @Published var copied = false
    @Published var livePreviewEnabled: Bool = false
    // ⌘⇧D Wispr-Flow additions: the LLM polish may still be running when the
    // card shows, a failed insert carries the notice, and `insertedAtCursor`
    // is what makes the card offer Undo.
    @Published var formattingInProgress: Bool = false
    @Published var insertedAtCursor: Bool = false
    @Published var insertNotice: String = ""

    /// Raw STT text before any formatting — the "Copy original" source.
    @Published var originalTranscript: String = ""

    /// Paste-at-cursor vs the copy-card behaviour. Default ON (Wispr).
    /// Off returns to the show-and-copy flow. Persisted; toggled from the
    /// System pane alongside `copyOriginalEnabled`.
    @Published var insertAtCursorEnabled: Bool {
        didSet {
            UserDefaults.standard.set(insertAtCursorEnabled, forKey: Self.insertAtCursorDefaultsKey)
        }
    }

    /// Offer "Copy original" on the ⌘⇧D card (and in the System pane's
    /// last-dictation card). Default ON.
    @Published var copyOriginalEnabled: Bool {
        didSet {
            UserDefaults.standard.set(copyOriginalEnabled, forKey: Self.copyOriginalDefaultsKey)
        }
    }

    /// The most recent dictation, original + polished. Persisted as a PAIR:
    /// each new dictation overwrites both, so the previous text is gone for
    /// good (no history, no recovery — by request). Survives restarts.
    @Published var lastOriginal: String = ""
    @Published var lastPolished: String = ""

    private static let insertAtCursorDefaultsKey = "jarvis.dictation.insertAtCursor"
    private static let copyOriginalDefaultsKey = "jarvis.dictation.copyOriginal"
    private static let lastOriginalDefaultsKey = "jarvis.dictation.lastOriginal"
    private static let lastPolishedDefaultsKey = "jarvis.dictation.lastPolished"

    private var insertLatencyStart: Date?
    private var insertAutoDismiss: DispatchWorkItem?
    private var hardCapDismiss: DispatchWorkItem?

    /// True once `receiveDictationTranscript` has replaced the raw STT text
    /// with the formatted version — `on_state_changed(TranscriptReady)` must
    /// not re-clobber the card with raw after that (callback race).
    private(set) var transcriptIsFormatted = false

    private var panel: NSPanel?
    private var panelHost: NSHostingView<DictationHUDView>?
    private var recordingStartedAt: Date?
    private var pendingStartOnReady = false
    private var pendingStartMode: PillMode = .dictate

    /// Sticky anchor for the pill — computed once per run, bottom-center.
    private var recordingAnchor: NSPoint?

    private var levelTimer: Timer?
    private var watchdogTimer: Timer?
    var pendingSpeechSecs: Double = 0

    private init() {
        let defaults = UserDefaults.standard
        // Init assignments bypass didSet — load persisted settings directly.
        insertAtCursorEnabled = defaults.object(forKey: Self.insertAtCursorDefaultsKey) as? Bool ?? true
        copyOriginalEnabled = defaults.object(forKey: Self.copyOriginalDefaultsKey) as? Bool ?? true
        lastOriginal = defaults.string(forKey: Self.lastOriginalDefaultsKey) ?? ""
        lastPolished = defaults.string(forKey: Self.lastPolishedDefaultsKey) ?? ""
    }

    func launch() {
        let ok = initialize_core()
        NSLog("[Jarvis][STT] Core initialized: \(ok)")
        // Loud, early, and in the app log: this is THE diagnostic for "paste
        // silently does nothing". Toggle ON in System Settings can still mean
        // untrusted when the grant was issued for an older build's signature
        // (see package_jarvis_app.zsh — sign with a stable identity).
        NSLog("[Jarvis][STT] Accessibility (auto-paste) trusted: \(has_accessibility_permission())")
        phase = get_app_phase()
        modelPhase = get_model_phase()
        livePreviewEnabled = get_live_preview_enabled()
        NSLog("[Jarvis][STT] Initial phase: \(phase), model: \(modelPhase)")

        // Timers start/stop around each Recording (see startDictation /
        // stopActivityTimers) — never polling at idle, so App Nap works
        // and SwiftUI isn't re-rendered 30×/s forever.
    }

    /// 30 Hz FFI meter — runs ONLY while a pill owns a recording.
    /// Started by startDictation, stopped when the recording ends
    /// (stopDictation / dismiss / retry). The in-guard double-checks
    /// phase+owner so a stale fire after stop is a no-op.
    private func startLevelPolling() {
        stopLevelPolling()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.phase == .Recording, STTRouter.shared.isModalOwner else { return }
            self.audioLevel = get_audio_level()
        }
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func startWatchdog() {
        stopWatchdog()
        // Max recording duration watchdog — auto-stops at the 300 s ring cap.
        // Pill-owned only: command utterances have their own 30 s failsafe
        // (WhisperCommandListener) and must never be stopped from here.
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self,
                  self.phase == .Recording,
                  STTRouter.shared.isModalOwner else { return }
            let elapsed = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if elapsed > 300 {
                NSLog("[Jarvis][STT] Recording timeout — auto stop")
                self.stopDictation()
            }
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Stops both activity timers. Called whenever a pill recording ends
    /// (stop sent, transcript dismissed/retried) so nothing polls at idle.
    private func stopActivityTimers() {
        stopLevelPolling()
        stopWatchdog()
    }

    // ── SINGLE dictation entry point ─────────────────────────
    // Carbon hotkey and any UI button both call this.
    // Behavior is driven entirely by the current phase.

    func toggleDictation() {
        NSLog("[Jarvis][STT] toggleDictation — phase: \(phase), model: \(modelPhase), owner: \(STTRouter.shared.owner)")

        switch STTRouter.shared.owner {
        case .command:
            // A command utterance is recording — abandon it instantly and
            // start the pill (AgentTalk parity: no waiting on a silent
            // final; the old wait left the pill dead on empty-stop).
            if !STTRouter.shared.preemptCommandForPill() {
                NSLog("[Jarvis][STT] toggleDictation result: ignored (command busy)")
            } else {
                NSLog("[Jarvis][STT] toggleDictation result: preempted command, pill starting")
            }
            return
        case .action:
            // Action pill owns the core — hand over to it: ⌘⇧D abandons
            // the action session and starts dictation fresh.
            NSLog("[Jarvis][STT] toggleDictation result: abandoning action pill, starting dictation")
            STTRouter.shared.abandonModalForOtherPill()
            mode = .dictate
            guard STTRouter.shared.claimForPill() else { return }
            startDictation()
            return
        case .pill:
            break // owned by us — phase switch below
        case .none:
            break // core free — phase switch below
        }

        // Stale-mirror guard: our `phase` may lag Rust (missed dismiss after
        // a command result routed). can_record only allows Ready, so sync
        // before deciding — otherwise a Ready core looks wedged.
        if (phase == .TranscriptReady || phase == .Error), get_app_phase() == .Ready {
            dismiss_transcript()
            phase = .Ready
        }

        switch phase {
        case .Ready:
            // Quiet-period BEFORE the claim lands: a VAD tick between this
            // press and start_recording must not steal the core for command
            // mode (auto-expires in 0.5 s; harmless if the claim fails).
            STTRouter.shared.suppressCommandClaimsUntil = Date().addingTimeInterval(0.5)
            guard STTRouter.shared.claimForPill() else {
                NSLog("[Jarvis][STT] toggleDictation result: ignored (core busy, owner: \(STTRouter.shared.owner))")
                return
            }
            mode = .dictate
            NSLog("[Jarvis][STT] toggleDictation result: claimed, starting pill")
            startDictation()
        case .Recording:
            // Only reachable when WE own the recording (command-owned
            // recordings divert to preemption above).
            NSLog("[Jarvis][STT] toggleDictation result: stopping pill recording")
            stopDictation()
        case .TranscriptReady:
            // One press: close the transcript AND immediately start
            // a new recording.
            NSLog("[Jarvis][STT] toggleDictation result: close + new recording")
            dismissTranscript()
            guard STTRouter.shared.claimForPill() else { return }
            mode = .dictate
            startDictation()
        case .Idle, .Preparing:
            // Model still loading/downloading. Queue a start for when
            // Ready arrives so the press is not lost.
            NSLog("[Jarvis][STT] toggleDictation result: queued on Ready (model: \(modelPhase))")
            mode = .dictate
            pendingStartOnReady = true
            pendingStartMode = .dictate
            showPanel()
        default:
            // Processing, Error
            NSLog("[Jarvis][STT] toggleDictation result: ignored in phase \(phase)")
        }
    }

    // ── SINGLE action entry point (⌘⇧A) ───────────────────────
    // Same lifecycle as toggleDictation, but the final transcript RUNS as
    // a command (no wake word) instead of landing on a Copy/Close card.

    func toggleAction() {
        NSLog("[Jarvis][STT] toggleAction — phase: \(phase), model: \(modelPhase), owner: \(STTRouter.shared.owner)")

        switch STTRouter.shared.owner {
        case .command:
            if !STTRouter.shared.preemptCommandForAction() {
                NSLog("[Jarvis][STT] toggleAction result: ignored (command busy)")
            } else {
                NSLog("[Jarvis][STT] toggleAction result: preempted command, action starting")
            }
            return
        case .pill:
            // Dictation owns the core — hand over: ⌘⇧A abandons dictation
            // and starts the action session fresh.
            NSLog("[Jarvis][STT] toggleAction result: abandoning dictate pill, starting action")
            STTRouter.shared.abandonModalForOtherPill()
            mode = .action
            guard STTRouter.shared.claimForAction() else { return }
            startDictation()
            return
        case .action:
            break // owned by us — phase switch below
        case .none:
            break // core free — phase switch below
        }

        if (phase == .TranscriptReady || phase == .Error), get_app_phase() == .Ready {
            dismiss_transcript()
            phase = .Ready
        }

        switch phase {
        case .Ready:
            STTRouter.shared.suppressCommandClaimsUntil = Date().addingTimeInterval(0.5)
            guard STTRouter.shared.claimForAction() else {
                NSLog("[Jarvis][STT] toggleAction result: ignored (core busy, owner: \(STTRouter.shared.owner))")
                return
            }
            mode = .action
            NSLog("[Jarvis][STT] toggleAction result: claimed, starting action")
            startDictation()
        case .Recording:
            NSLog("[Jarvis][STT] toggleAction result: stopping action recording")
            stopDictation()
        case .TranscriptReady:
            NSLog("[Jarvis][STT] toggleAction result: close + new action recording")
            dismissTranscript()
            mode = .action
            guard STTRouter.shared.claimForAction() else { return }
            startDictation()
        case .Idle, .Preparing:
            NSLog("[Jarvis][STT] toggleAction result: queued on Ready (model: \(modelPhase))")
            mode = .action
            pendingStartOnReady = true
            pendingStartMode = .action
            showPanel()
        default:
            NSLog("[Jarvis][STT] toggleAction result: ignored in phase \(phase)")
        }
    }

    /// Starts an action recording session. The caller must hold action
    /// ownership (via claimForAction, or the router's pending-start path).
    func startActionRecording() {
        mode = .action
        startDictation()
    }

    /// Starts a pill recording session. The caller must hold pill ownership
    /// (via claimForPill, or the router's pending-start path).
    func startPillRecording() {
        mode = .dictate
        startDictation()
    }

    private func startDictation() {
        // Clear the card's state BEFORE the panel exists: showPanel() renders
        // whatever the last phase/transcript was, so a fresh run that skipped
        // this could flash — or, if start_recording then failed, strand — the
        // PREVIOUS dictation's text (the ⌘⇧D residue that showed up during a
        // following ⌘⇧A). Every field the card reads is reset here, including
        // the "Original" source and any half-finished polish flags.
        transcript = ""
        partialTranscript = ""
        transcriptIsFormatted = false
        originalTranscript = ""
        insertNotice = ""
        formattingInProgress = false
        insertedAtCursor = false
        copied = false
        errorMessage = ""

        // Panel FIRST (agentTalk order): the press must always produce
        // something visible, even if the core then refuses to record.
        showPanel()
        let ok = start_recording()
        NSLog("[Jarvis][STT] start_recording returned: \(ok)")
        if ok {
            recordingStartedAt = Date()
            // Warm the small instruct model for the polish pass so the first
            // messy dictation of a session wins its race. Utility priority;
            // keep-alive unloads it again after 60 s if the dictation ends up
            // short and clean (rules-only).
            DictationPolisher.warmUp()
            // Optimistic mirror: the second press must see .Recording even
            // before the Rust callback round-trips, or it lands on
            // `ignored (core busy, owner: pill)` instead of the stop arm.
            phase = .Recording
            resizePanelForCurrentState()
            // Activity timers live exactly as long as this recording.
            startLevelPolling()
            startWatchdog()
            // Mute command-mode VAD claims while the pill owns the core —
            // otherwise every voiced tick re-claims for command mode and the
            // next toggle loses the race. Level meter keeps running.
            STTRouter.shared.pillSuppressesCommandVAD = true
        } else {
            // Core refused (race with command mode) — surface the failure as
            // an Error card instead of an invisible panel, then release.
            phase = .Error
            errorMessage = mode == .action
                ? "Could not start recording — core busy. Press ⌘⇧A again."
                : "Could not start recording — core busy. Press ⌘⇧D again."
            resizePanelForCurrentState()
            positionPanelForCurrentState()
            panel?.orderFrontRegardless()
            STTRouter.shared.pillSuppressesCommandVAD = false
            if mode == .action {
                STTRouter.shared.releaseFromAction()
            } else {
                STTRouter.shared.releaseFromPill()
            }
        }
    }

    /// Called when the model finishes loading and phase becomes Ready.
    /// Starts a queued dictation if the user pressed the shortcut early.
    func flushPendingStart() {
        guard pendingStartOnReady, phase == .Ready else { return }
        pendingStartOnReady = false
        let queuedMode = pendingStartMode
        pendingStartMode = .dictate
        NSLog("[Jarvis][STT] Flushing queued start (model now Ready)")
        if queuedMode == .action {
            mode = .action
            guard STTRouter.shared.claimForAction() else { return }
        } else {
            mode = .dictate
            guard STTRouter.shared.claimForPill() else { return }
        }
        startDictation()
    }

    private func stopDictation() {
        NSLog("[Jarvis][STT] Recording stopped — starting inference")
        let speechSecs = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        pendingSpeechSecs = speechSecs
        recordingStartedAt = nil
        stopActivityTimers()
        let rustPhase = get_app_phase()
        guard rustPhase == .Recording else {
            // Stale mirror (e.g. a command result just routed and freed
            // the core) — nothing to stop; release so we can't wedge.
            // Also unmute VAD: with owner .none and the mute still set,
            // command mode would go deaf.
            NSLog("[Jarvis][STT] stop ignored — core not recording (mirror: \(phase), rust: \(rustPhase))")
            STTRouter.shared.pillSuppressesCommandVAD = false
            if mode == .action {
                STTRouter.shared.releaseFromAction()
            } else {
                STTRouter.shared.releaseFromPill()
            }
            return
        }
        // FFI runs on main thread: captures audio (thread_local),
        // transitions to Processing, then spawns its own inference thread.
        stop_recording()
        // Optimistic flip: the SAME panel shows Transcribing instantly while
        // inference runs (the user waits on the pill). The Rust
        // Recording → Processing callback confirms and re-syncs.
        phase = .Processing
        showPanelIfNeeded()
    }

    // ── Transcript actions ──────────────────────────────────

    /// The ⌘⇧D entry point. Rules format first (sync, ~0 ms); the LLM polish
    /// (`DictationPolisher`) runs only when the rules say the input is messy,
    /// and what lands at the cursor is what the card shows — nothing diverges.
    func receiveDictationTranscript(_ raw: String) {
        insertLatencyStart = Date()
        insertNotice = ""
        insertedAtCursor = false
        copied = false
        originalTranscript = raw

        let rules = TranscriptFormatter.format(raw)
        transcript = rules.text
        transcriptIsFormatted = true

        guard !transcript.isEmpty else {
            // Everything spoken was a filler — there is nothing to paste and
            // nothing to show. Free the core and close so a next press is not
            // blocked by a lingering empty card.
            NSLog("[Jarvis][Dictate] nothing usable captured — card skipped")
            dismissTranscript()
            return
        }

        // Latest-pair persistence: original known now; the polished half of
        // the pair lands when the final text is known (rules-only path
        // immediately, polish path on completion). Each dictation overwrites
        // both keys — the previous pair is unrecoverable, by request.
        persistLastDictation(original: raw)

        partialTranscript = ""
        phase = .TranscriptReady
        showPanel()
        scheduleHardCapDismiss()

        if TranscriptFormatter.shouldUseLLM(rules) {
            formattingInProgress = true
            resizePanelForCurrentState()
            positionPanelForCurrentState()
            // Main-actor, deliberately: the finalize path touches Published
            // state, AppKit (pasteboard, panels) and the AX paste — all of it
            // main-thread territory; a background-task polish that jumps
            // straight back to mutating UI crashed (AXIsProcessTrusted*
            // through objc_msgSend on a nil on a bare thread).
            Task { @MainActor [weak self] in
                let polished = await DictationPolisher.polish(rulesOutput: rules)
                guard let self, STTRouter.shared.owner == .pill else { return }
                self.formattingInProgress = false
                self.transcript = polished
                self.persistLastDictation(polished: polished)
                self.insertFormattedText()
            }
        } else {
            persistLastDictation(polished: rules.text)
            insertFormattedText()
        }
    }

    /// Paste the final text at the cursor. Insert failure is never silent:
    /// the formatted text is copied so the user still has it, and the card
    /// carries the permission notice with a one-tap grant.
    private func insertFormattedText() {
        let elapsed = insertLatencyStart.map { Date().timeIntervalSince($0) } ?? 0

        guard insertAtCursorEnabled else {
            NSLog("[Jarvis][Dictate] insert disabled — card ready (stop→ready %.0f ms)", elapsed * 1000)
            return
        }

        let trusted = has_accessibility_permission()
        let canPost = has_event_posting_permission()
        let ok = insert_text(transcript)
        NSLog("[Jarvis][Dictate] insert: %d (stop→insert %.0f ms, %d chars, ax=%d cg=%d)",
              ok ? 1 : 0, elapsed * 1000, transcript.count, trusted ? 1 : 0, canPost ? 1 : 0)
        logInsertAttempt(ok: ok, trusted: trusted, canPost: canPost, chars: transcript.count)

        if ok {
            insertedAtCursor = true
            scheduleInsertAutoDismiss()
        } else {
            silentlyCopyTranscript()
            if trusted || canPost {
                // Both gates said yes yet the paste did not land — not a
                // permission problem; the JSONL above has the details.
                insertNotice = "Auto-paste did not land — text copied instead (logged)."
            } else {
                insertNotice = "Auto-paste needs Accessibility — approve the prompt, or add Jarvis in Privacy & Security → Accessibility. Text copied instead."
                requestEventPostingAccessIfStale()
            }
        }

        resizePanelForCurrentState()
        positionPanelForCurrentState()
    }

    /// The Apple-supported grant request (CGRequestPostEventAccess) — shows
    /// the system prompt and registers the app in the Accessibility list.
    /// Main thread by construction (this path runs on main). Throttled: the
    /// OS may re-prompt when the stored grant is stale, and a nagging prompt
    /// on every dictation would be worse than the problem.
    private var lastEventAccessRequestAt = Date.distantPast

    private func requestEventPostingAccessIfStale() {
        guard Date().timeIntervalSince(lastEventAccessRequestAt) > 300 else { return }
        lastEventAccessRequestAt = Date()
        _ = request_event_posting_permission()
    }

    /// One JSONL line per insert attempt — the answer to "why didn't it
    /// paste" without needing a console.
    private func logInsertAttempt(ok: Bool, trusted: Bool, canPost: Bool, chars: Int) {
        let fields: [String: String] = [
            "event": ok ? "inserted" : "failed",
            "ax_trusted": trusted ? "1" : "0",
            "cg_can_post": canPost ? "1" : "0",
            "chars": String(chars),
        ]
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return }
            guard let dir = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Jarvis/logs") else { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("dictation_insert.jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data + [0x0A])
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Copies without flipping the Copy button — on this path the copy is a
    /// fallback, not an action the user took, and the button must stay live.
    private func silentlyCopyTranscript() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
        StatsRecorder.shared.recordCopy(chars: transcript.count)
    }

    /// After a successful paste the card must not demand a mouse click to go
    /// away; it lingers long enough for Copy/Undo, then leaves on its own.
    private func scheduleInsertAutoDismiss() {
        insertAutoDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .TranscriptReady else { return }
            self.dismissTranscript()
        }
        insertAutoDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    /// Hard cap: whatever happened (paste failed, insert disabled, nobody
    /// clicked anything), the card closes itself 10 s after it appears. The
    /// 6 s success-dismiss above is a nicety; THIS is the guarantee that the
    /// card never lingers forever.
    private func scheduleHardCapDismiss() {
        hardCapDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .TranscriptReady else { return }
            NSLog("[Jarvis][Dictate] card auto-closed (10 s cap)")
            self.dismissTranscript()
        }
        hardCapDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    /// Overwrite-in-place persistence for the latest dictation pair. No
    /// history is kept: the previous values are gone the moment new ones
    /// land, which is exactly the contract the user asked for.
    private func persistLastDictation(original: String? = nil, polished: String? = nil) {
        let defaults = UserDefaults.standard
        if let original {
            lastOriginal = original
            defaults.set(original, forKey: Self.lastOriginalDefaultsKey)
        }
        if let polished {
            lastPolished = polished
            defaults.set(polished, forKey: Self.lastPolishedDefaultsKey)
        }
    }

    /// "Copy original" on the card — copies the raw STT text (before rules
    /// and before the polish pass), leaving the card open so the polished
    /// version can still be copied too.
    func copyOriginalTranscript() {
        guard !originalTranscript.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(originalTranscript, forType: .string)
        NSLog("[Jarvis][Dictate] Copied ORIGINAL to clipboard (\(originalTranscript.count) chars)")
        StatsRecorder.shared.recordCopy(chars: originalTranscript.count)
    }

    /// Runs ⌘Z in the frontmost app — a paste is the target app's editable
    /// prop, so ITS undo stack is the right tool for backing it out.
    func undoInsert() {
        let ok = undo_last_insert()
        NSLog("[Jarvis][Dictate] undo insert: %d", ok ? 1 : 0)
        insertNotice = ""
        if ok {
            // Keep the text available for Copy — the undo only removed it
            // from the document, not from the card.
            insertedAtCursor = false
        }
    }

    func openAccessibilityPane() {
        open_accessibility_pane()
    }

    func copyTranscript() {
        // Direct NSPasteboard write — one atomic clipboard event.
        // clearContents() then setString(_:forType:) bumps changeCount once,
        // so clipboard managers record the transcript as a single new entry.
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
        NSLog("[Jarvis][STT] Copied to clipboard (\(transcript.count) chars)")

        copied = true
        StatsRecorder.shared.recordCopy(chars: transcript.count)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.dismissTranscript()
        }
    }

    func closeTranscript() {
        dismissTranscript()
    }

    func dismissTranscript() {
        dismiss_transcript()
        insertAutoDismiss?.cancel()
        insertAutoDismiss = nil
        hardCapDismiss?.cancel()
        hardCapDismiss = nil
        stopActivityTimers()
        hidePanel()
        STTRouter.shared.releaseModalOwner()
        STTRouter.shared.pillSuppressesCommandVAD = false
        // One-shot pills that started the mic transiently hand it back:
        // listening is manual, so a ⌘⇧A/⌘⇧D press must not leave the app
        // live-listening afterwards (no-op when the user had listening on).
        // AppState is main-actor isolated and this controller is not — hop.
        Task { @MainActor in
            AppState.shared?.restoreMicAfterTransientStartIfNeeded()
        }
        resetDictationHotkeyHeldState()
        resetActionHotkeyHeldState()
    }

    func retryRecording() {
        stopActivityTimers()
        retry_recording()
    }

    // ── Panel management ────────────────────────────────────

    /// Creates (if needed) and fronts the panel. Public so the error path
    /// (`BridgeCallbacks.on_error`) can show the Error card for pill-owned
    /// failures instead of leaving a stale/invisible state.
    func showPanel() {
        if panel == nil {
            createPanel()
        }
        // setFrame only when the size actually changed: every setFrame on a
        // borderless NSPanel hosting SwiftUI re-runs the constraint solver,
        // and resize-while-content-resizes is what threw NSGenericException
        // ("more Update Constraints passes than views") → SIGABRT on
        // 2026-09-29. Positioning (setFrameOrigin) is always safe.
        if let panel, panel.frame.size != panelSizeForCurrentState() {
            resizePanelForCurrentState()
        }
        positionPanelForCurrentState()
        panel?.orderFrontRegardless()
    }

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = false
        p.becomesKeyOnlyIfNeeded = true
        p.isMovable = false
        p.isMovableByWindowBackground = false

        p.contentView?.wantsLayer = true
        p.contentView?.layer?.backgroundColor = NSColor.clear.cgColor

        let host = NSHostingView(rootView: DictationHUDView())
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.layer?.masksToBounds = false
        p.contentView = host

        panelHost = host
        panel = p
    }

    private func panelSizeForCurrentState() -> CGSize {
        // Reload states (model Loading/Unloading after an idle-unload) reuse
        // the Preparing card — DictationHUDView renders Preparing for any
        // non-Ready model phase while Recording hasn't started.
        if modelPhase == .Loading || modelPhase == .Unloading {
            return CGSize(width: 300, height: 120)
        }
        switch phase {
        case .Recording:
            let previewVisible = livePreviewEnabled && !partialTranscript.isEmpty
            if previewVisible {
                return CGSize(width: 400, height: 120)
            }
            return CGSize(width: 240, height: 44)
        case .Processing:
            return CGSize(width: 240, height: 44)
        case .TranscriptReady:
            // Keep in sync with DictationTranscriptOverlayView
            // (baseHeight / noticeHeight / cardWidth). 400pt wide: four
            // equal-width actions sit on one row without clipping.
            if !insertNotice.isEmpty {
                return CGSize(width: DictationTranscriptOverlayView.cardWidth,
                              height: DictationTranscriptOverlayView.noticeHeight)
            }
            return CGSize(width: DictationTranscriptOverlayView.cardWidth,
                          height: DictationTranscriptOverlayView.baseHeight)
        case .Error, .Preparing:
            return CGSize(width: 300, height: 120)
        default:
            return CGSize(width: 240, height: 44)
        }
    }

    private func resizePanelForCurrentState() {
        guard let panel else { return }
        let size = panelSizeForCurrentState()
        let frame = NSRect(origin: panel.frame.origin, size: size)
        panel.setFrame(frame, display: true, animate: false)
        panelHost?.frame = NSRect(origin: .zero, size: size)
    }

    private func positionPanelForCurrentState() {
        guard let panel else { return }
        // NSScreen.main is nil during Spaces transitions / display sleep —
        // fall back to the first screen, then the last anchor, then bottom-center.
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            if let anchor = recordingAnchor {
                panel.setFrameOrigin(anchor)
            }
            return
        }
        let visible = visibleFrame

        // Anchor: computed once (bottom-center), sticky for the whole run.
        if recordingAnchor == nil {
            recordingAnchor = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.minY + 24
            )
        }

        switch phase {
        case .TranscriptReady:
            // Float above the anchor, horizontally aligned to it — but never
            // off-screen: if the pill is near the top, put the transcript
            // BELOW the pill instead. Clamp X too so the wider 300pt card
            // never runs off the right edge.
            let anchor = recordingAnchor ?? NSPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 24)
            let aboveY = anchor.y + panel.frame.height + 24
            let fitsAbove = aboveY + panel.frame.height <= visible.maxY
            let y = fitsAbove ? aboveY : anchor.y - panel.frame.height - 24
            let x = min(max(anchor.x, visible.minX), max(visible.minX, visible.maxX - panel.frame.width))
            panel.setFrameOrigin(NSPoint(x: x, y: min(max(y, visible.minY), max(visible.minY, visible.maxY - panel.frame.height))))
        default:
            panel.setFrameOrigin(recordingAnchor ?? .zero)
        }
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
        panelHost = nil
    }

    /// Called from Rust callbacks when phase changes while panel may exist.
    func showPanelIfNeeded() {
        if panel != nil {
            // Same crash guard as showPanel: never setFrame redundantly.
            if let panel, panel.frame.size != panelSizeForCurrentState() {
                resizePanelForCurrentState()
            }
            positionPanelForCurrentState()
            panel?.orderFrontRegardless()
        }
    }
}
