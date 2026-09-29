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

    private init() {}

    func launch() {
        let ok = initialize_core()
        NSLog("[Jarvis][STT] Core initialized: \(ok)")
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
        // Panel FIRST (agentTalk order): the press must always produce
        // something visible, even if the core then refuses to record.
        showPanel()
        let ok = start_recording()
        NSLog("[Jarvis][STT] start_recording returned: \(ok)")
        if ok {
            recordingStartedAt = Date()
            copied = false
            partialTranscript = ""
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
        stopActivityTimers()
        hidePanel()
        STTRouter.shared.releaseModalOwner()
        STTRouter.shared.pillSuppressesCommandVAD = false
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
            return CGSize(width: 300, height: 170)
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
