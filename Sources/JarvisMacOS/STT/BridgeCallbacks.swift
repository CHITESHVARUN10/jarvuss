import AppKit
import SwiftUI

// MARK: - swift-bridge callbacks (called from the Rust STT core)
//
// These globals satisfy the `extern "Swift"` block in stt-core/src/lib.rs.
// Rust invokes them on background threads — every handler hops to the main
// queue before touching UI or the router (all STT ownership lives on main).

func on_state_changed(phase: AppPhase, model: ModelPhase) {
    DispatchQueue.main.async {
        let controller = DictationController.shared

        // ALWAYS mirror Rust truth — the toggle state machine, the pill,
        // and the command path all depend on a live phase. (A previous
        // version only mirrored for the pill owner, which wedged the
        // controller at Idle forever when callbacks arrived unowned.)
        controller.phase = phase
        controller.modelPhase = model

        // Panel side-effects are pill-only: command utterances must never
        // pop the pill.
        guard STTRouter.shared.isModalOwner else {
            // Core became ready with no owner (app launch): allow a
            // queued pill press to fire.
            if phase == .Ready {
                controller.flushPendingStart()
            }
            return
        }

        // Reloading after an idle-unload surfaces as Loading/Unloading (see
        // lib.rs TranscribeChunk + Unload arms) — show the panel so the user
        // sees "Downloading/Loading…" instead of a hung Transcribing pill.
        // showPanel (create), not showPanelIfNeeded (nil-guard no-op): the
        // panel may have been destroyed mid-flight, and the card must appear
        // regardless. Command utterances never reach here (owner guard above).
        if phase == .Preparing || model == .Loading || model == .Unloading || model == .Downloading {
            controller.showPanel()
        } else if phase == .Processing || phase == .TranscriptReady {
            controller.showPanel()
        } else if phase == .Error {
            controller.showPanel()
        }

        if phase == .TranscriptReady {
            // `receiveDictationTranscript` may have already replaced the raw
            // text with formatted text (rules pass runs synchronously) — the
            // mirror must not re-clobber it with raw on the state callback.
            if !controller.transcriptIsFormatted {
                controller.transcript = get_transcript().toString()
                NSLog("[Jarvis][STT] state→TranscriptReady route=\(STTRouter.shared.owner) chars=\(controller.transcript.count)")
            }
        }

        // A press during model load is queued; fire it now that Ready arrived.
        if phase == .Ready {
            controller.flushPendingStart()
        }
    }
}

func on_transcript_ready(text: RustString) {
    let t = text.toString()
    DispatchQueue.main.async {
        // Router decides: pill transcript, command sink, or dropped.
        // Dictate path is pure STT (voice-to-text into the panel) — it
        // never touches onCommandTranscript, so no AI/command execution
        // can fire from a ⌘⇧D dictation. That separation is load-bearing;
        // keep it. The ACTION pill (⌘⇧A) forwards to onActionTranscript.
        if let pillText = STTRouter.shared.routeTranscript(t) {
            let controller = DictationController.shared
            // Owner is ground truth for routing (not controller.mode, which
            // can go stale if a previous run ended without a reset — that
            // staleness was the ⌘⇧D-executes-commands bug).
            let actionMode = STTRouter.shared.owner == .action
            NSLog("[Jarvis][STT] transcript route=\(actionMode ? "action" : "pill") chars=\(pillText.count)")
            let speechSecs = controller.pendingSpeechSecs
            StatsRecorder.shared.recordDictation(speechSecs: speechSecs, chars: pillText.count)
            controller.pendingSpeechSecs = 0
            if actionMode {
                // Action pill: hand the text to AppState (verifies per the
                // user setting, then runs) and close the pill. The command
                // result surfaces in the main window; the pill is done.
                controller.partialTranscript = ""
                controller.phase = .Ready
                STTRouter.shared.onActionTranscript?(pillText)
                controller.dismissTranscript()
            } else {
                // ⌘⇧D dictate: format (rules, plus the LLM pass when messy)
                // then insert at the cursor. The card always shows what was
                // inserted so text and card can never diverge. Ownership copy
                // of the transcript is intact here (`dismiss_transcript()`
                // must NOT run yet — per the agentTalk parity note below).
                controller.receiveDictationTranscript(pillText, speechSeconds: speechSecs)
            }
        } else {
            // Command-mode (or dropped): ready the core for the next
            // utterance — set_transcript() left Rust at TranscriptReady,
            // which would reject the next begin (can_record allows Ready).
            // (The VAD listener also self-heals a stale TranscriptReady, so
            // this is just the fast path.)
            NSLog("[Jarvis][STT] transcript route=command/dropped owner=\(STTRouter.shared.owner) chars=\(t.count)")
            dismiss_transcript()
        }
    }
}

func on_partial_transcript(text: RustString) {
    let t = text.toString()
    DispatchQueue.main.async {
        // Live partials route by owner: pill → preview bubble,
        // command → main-window LIVE TRANSCRIPT card (new).
        if let pillText = STTRouter.shared.routePartial(t) {
            let controller = DictationController.shared
            controller.partialTranscript = pillText
            // Panel may need to grow to fit the preview bubble above the pill
            controller.showPanelIfNeeded()
        }
    }
}

func on_error(message: RustString) {
    let msg = message.toString()
    NSLog("[Jarvis][STT] Error: \(msg)")
    DispatchQueue.main.async {
        // Router decides: pill error card or command-mode log.
        if let pillMsg = STTRouter.shared.routeError(msg) {
            let controller = DictationController.shared
            controller.errorMessage = pillMsg
            controller.phase = .Error
            // showPanel (create), not showPanelIfNeeded (nil-guard no-op):
            // audio-start failures (permission, no device) must surface the
            // Error card instead of leaving no visible pill at all.
            controller.showPanel()
        }
    }
}

func on_download_progress(progress: Float, speed: RustString, remaining: RustString) {
    DispatchQueue.main.async {
        let controller = DictationController.shared
        controller.downloadProgress = progress
        controller.downloadSpeed = speed.toString()
        controller.downloadRemaining = remaining.toString()
    }
}
