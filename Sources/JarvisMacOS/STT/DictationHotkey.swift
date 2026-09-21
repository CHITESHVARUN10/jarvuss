import AppKit
import Carbon.HIToolbox

// MARK: - Global dictation hotkey (⌘⇧D via Carbon)
//
// Carbon RegisterEventHotKey is the SINGLE hotkey path — it works globally
// without accessibility permission. Toggle happens on key-DOWN only;
// key-UP only clears the held flag (auto-repeat suppression).

private var gDictationHotKeyRef: EventHotKeyRef?
private let gDictationHotKeySignature: OSType = OSType(0x4A565354) // "JVST"

// Held-state tracking — suppress auto-repeat.
// Lives outside any class so the C callback can touch it.
// Only accessed from the main queue (all hotkey events hop there).
private var gDictationHotkeyHeld = false

/// Resets the hotkey held-state. Called when a dictation cycle completes
/// (dismiss/close) so a stale held flag can't swallow the next press.
func resetDictationHotkeyHeldState() {
    DispatchQueue.main.async {
        gDictationHotkeyHeld = false
    }
}

// Global C callback for Carbon hotkey events.
private func dictationHotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return noErr }

    var hkID = EventHotKeyID()
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hkID
    )

    guard err == noErr, hkID.signature == gDictationHotKeySignature else { return noErr }

    let kind = GetEventKind(event)
    let isPress = (kind == UInt32(kEventHotKeyPressed))

    DispatchQueue.main.async {
        if isPress {
            // Toggle ON the first key-down only.
            // Suppress auto-repeat presses while the key is held.
            guard !gDictationHotkeyHeld else { return }
            gDictationHotkeyHeld = true
            NSLog("[Jarvis][Hotkey] DOWN — toggle dictation")
            DictationController.shared.toggleDictation()
        } else {
            // Release: clear the held flag, do NOT toggle.
            gDictationHotkeyHeld = false
        }
    }

    return noErr
}

func registerDictationHotkey() {
    var hotKeyID = EventHotKeyID(signature: gDictationHotKeySignature, id: 1)

    let status = RegisterEventHotKey(
        UInt32(kVK_ANSI_D),
        UInt32(cmdKey | shiftKey),
        hotKeyID,
        GetEventDispatcherTarget(),
        0,
        &gDictationHotKeyRef
    )

    if status == noErr {
        NSLog("[Jarvis][Hotkey] Carbon hotkey registered (⌘⇧D)")
    } else {
        NSLog("[Jarvis][Hotkey] Registration failed: \(status)")
    }

    var specs: [EventTypeSpec] = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
    ]

    let handler: EventHandlerUPP = { _, event, _ in
        dictationHotkeyEventHandler(nil, event, nil)
    }

    var installed: EventHandlerRef?
    let installErr = specs.withUnsafeMutableBufferPointer { buf in
        InstallEventHandler(
            GetEventDispatcherTarget(),
            handler,
            2,
            buf.baseAddress,
            nil,
            &installed
        )
    }

    if installErr == noErr {
        NSLog("[Jarvis][Hotkey] Carbon event handler installed")
    } else {
        NSLog("[Jarvis][Hotkey] Event handler install failed: \(installErr)")
    }
}

func unregisterDictationHotkey() {
    if let ref = gDictationHotKeyRef { UnregisterEventHotKey(ref) }
    gDictationHotKeyRef = nil
    gDictationHotkeyHeld = false
}
