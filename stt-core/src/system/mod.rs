//! System-level operations: clipboard access and auto-paste (macOS only).

use core_graphics::event::{CGEvent, CGEventTapLocation};
use core_graphics::event_source::CGEventSource;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    /// Returns a `Boolean` (unsigned char) — declared as u8 and compared
    /// `!= 0` so the ABI matches regardless of sign conventions.
    fn AXIsProcessTrusted() -> u8;
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    /// True when this process may post synthetic events (⌘V/⌘Z). This is the
    /// PRECISE permission auto-paste needs, checked in addition to
    /// AXIsProcessTrusted so an odd/stale AX answer can never veto a working
    /// paste path. C99 `bool` — Rust bool is the correct ABI here.
    fn CGPreflightPostEventAccess() -> bool;
    /// Apple-supported prompt for the event-posting permission. Also
    /// registers the app in the Accessibility list when the user approves,
    /// which fixes the "granted but not matching" dance in the common case.
    /// MAIN THREAD ONLY (it presents UI) — the old AX-with-options variant
    /// crashed partly because it was called off-thread.
    fn CGRequestPostEventAccess() -> bool;
}

/// Either gate may say yes — both are the same TCC service under the hood,
/// and the pair protects against one API returning a stale/odd answer.
pub fn is_accessibility_trusted() -> bool {
    let ax = unsafe { AXIsProcessTrusted() != 0 };
    let cg = unsafe { CGPreflightPostEventAccess() };
    ax || cg
}

/// CoreGraphics' event-posting preflight alone — the second opinion logged
/// with every insert attempt.
pub fn can_post_events() -> bool {
    unsafe { CGPreflightPostEventAccess() }
}

/// Prompts for event-posting access (main thread!). Returns the current
/// state, which stays false until the user acts — the grant lands async.
pub fn request_event_posting_access() -> bool {
    unsafe { CGRequestPostEventAccess() }
}

/// Real check used by paste paths: without Accessibility trust macOS drops
/// posted key events silently, which looks like "nothing pasted".
pub fn check_accessibility_permission() -> anyhow::Result<()> {
    if is_accessibility_trusted() {
        Ok(())
    } else {
        tracing::warn!("Accessibility permission missing — paste will not land");
        Err(anyhow::anyhow!(
            "Accessibility permission missing — grant it in System Settings"
        ))
    }
}

pub fn open_accessibility_settings() -> std::io::Result<()> {
    std::process::Command::new("open")
        .args(["x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
        .spawn()?;
    Ok(())
}

pub fn open_microphone_settings() -> std::io::Result<()> {
    std::process::Command::new("open")
        .args(["x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"])
        .spawn()?;
    Ok(())
}

/// Runs ⌘Z in the frontmost app — the dictation's undo contract: a paste is
/// an editable prop the target app owns, and its undo stack backs it out.
pub fn undo_last_insert() -> anyhow::Result<()> {
    check_accessibility_permission()?;

    let source = CGEventSource::new(core_graphics::event_source::CGEventSourceStateID::Private)
        .map_err(|_| anyhow::anyhow!("Failed to create event source"))?;

    let cmd_down = CGEvent::new_keyboard_event(source.clone(), 55, true)
        .map_err(|_| anyhow::anyhow!("Failed to create Cmd key-down event"))?;
    let z_down = CGEvent::new_keyboard_event(source.clone(), 6, true)
        .map_err(|_| anyhow::anyhow!("Failed to create Z key-down event"))?;
    let z_up = CGEvent::new_keyboard_event(source.clone(), 6, false)
        .map_err(|_| anyhow::anyhow!("Failed to create Z key-up event"))?;
    let cmd_up = CGEvent::new_keyboard_event(source, 55, false)
        .map_err(|_| anyhow::anyhow!("Failed to create Cmd key-up event"))?;

    z_down.set_flags(core_graphics::event::CGEventFlags::CGEventFlagCommand);

    cmd_down.post(CGEventTapLocation::HID);
    z_down.post(CGEventTapLocation::HID);
    z_up.post(CGEventTapLocation::HID);
    cmd_up.post(CGEventTapLocation::HID);

    tracing::info!("Sent ⌘Z to frontmost app — dictation undo");
    Ok(())
}

pub fn copy_to_clipboard(text: &str) -> anyhow::Result<()> {
    let mut clipboard = arboard::Clipboard::new()
        .map_err(|e| anyhow::anyhow!("Failed to access clipboard: {}", e))?;

    clipboard.set_text(text).map_err(|e| anyhow::anyhow!("Failed to set clipboard text: {}", e))?;

    tracing::info!(chars = text.len(), "Copied to clipboard");
    Ok(())
}

pub fn get_clipboard() -> anyhow::Result<Option<String>> {
    let mut clipboard = arboard::Clipboard::new()
        .map_err(|e| anyhow::anyhow!("Failed to access clipboard: {}", e))?;

    match clipboard.get_text() {
        Ok(text) => Ok(Some(text)),
        Err(arboard::Error::ContentNotAvailable) => Ok(None),
        Err(e) => Err(anyhow::anyhow!("Clipboard read error: {}", e)),
    }
}

/// Wispr-style insert: paste the text at the cursor of the frontmost app,
/// without leaving the dictation on the clipboard.
///
/// Clipboard-save semantics: only TEXT content can be restored — an image or
/// file payload on the clipboard is left clobbered with the dictation text.
/// The restore is a delayed re-write, which re-adds the user's original as a
/// fresh clipboard-manager entry (dictation stays as its own entry).
pub fn insert_text(text: &str) -> anyhow::Result<()> {
    // Load-bearing check FIRST: with untrusted AX the ⌘V HID events are
    // silently ignored by macOS — the failure mode is "nothing happened",
    // which must never look like a successful insert to the caller.
    if !is_accessibility_trusted() {
        return Err(anyhow::anyhow!("Accessibility permission missing"));
    }

    let previous = get_clipboard().ok().flatten();

    copy_to_clipboard(text)?;
    paste_into_frontmost()?;

    tracing::info!(chars = text.len(), "Inserted text into frontmost app");

    // Restore after the target app has consumed the paste. 1.2 s covers slow
    // foreground apps; anything faster risks pasting the RESTORED content.
    if let Some(previous) = previous {
        let previous = previous.to_string();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(1200));
            if let Ok(mut clipboard) = arboard::Clipboard::new() {
                let _ = clipboard.set_text(&previous);
            }
        });
    }

    Ok(())
}

pub fn paste_into_frontmost() -> anyhow::Result<()> {
    check_accessibility_permission()?;

    let source = CGEventSource::new(core_graphics::event_source::CGEventSourceStateID::Private)
        .map_err(|_| anyhow::anyhow!("Failed to create event source"))?;

    let cmd_down = CGEvent::new_keyboard_event(source.clone(), 55, true)
        .map_err(|_| anyhow::anyhow!("Failed to create Cmd key-down event"))?;
    let v_down = CGEvent::new_keyboard_event(source.clone(), 9, true)
        .map_err(|_| anyhow::anyhow!("Failed to create V key-down event"))?;
    let v_up = CGEvent::new_keyboard_event(source.clone(), 9, false)
        .map_err(|_| anyhow::anyhow!("Failed to create V key-up event"))?;
    let cmd_up = CGEvent::new_keyboard_event(source, 55, false)
        .map_err(|_| anyhow::anyhow!("Failed to create Cmd key-up event"))?;

    v_down.set_flags(core_graphics::event::CGEventFlags::CGEventFlagCommand);

    cmd_down.post(CGEventTapLocation::HID);
    v_down.post(CGEventTapLocation::HID);
    v_up.post(CGEventTapLocation::HID);
    cmd_up.post(CGEventTapLocation::HID);

    tracing::info!("Pasted into frontmost app");
    Ok(())
}
