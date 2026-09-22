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
        guard STTRouter.shared.owner == .pill else {
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
        // Preparing/Loading/Error create (showPanel); Processing/TranscriptReady
        // only resize an existing panel (showPanelIfNeeded).
        if phase == .Preparing || model == .Loading || model == .Unloading || model == .Downloading {
            controller.showPanel()
        } else if phase == .Processing || phase == .TranscriptReady {
            controller.showPanelIfNeeded()
        } else if phase == .Error {
            controller.showPanel()
        }

        if phase == .TranscriptReady {
            controller.transcript = get_transcript().toString()
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
        // Pill path is pure STT (voice-to-text into the panel) — it never
        // touches onCommandTranscript, so no AI/command execution can fire
        // from a ⌘⇧D dictation. That separation is load-bearing; keep it.
        if let pillText = STTRouter.shared.routeTranscript(t) {
            DictationController.shared.transcript = pillText
            DictationController.shared.partialTranscript = ""
            DictationController.shared.phase = .TranscriptReady
        }
        // Ready the core for the next utterance — set_transcript() left
        // the Rust phase at TranscriptReady, which would reject the next
        // begin (can_record only allows Ready).
        dismiss_transcript()
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
