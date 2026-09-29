import AppKit
import Carbon.HIToolbox

// MARK: - Global push-to-talk hotkeys (⌘⇧D dictate, ⌘⇧A action) via Carbon
//
// Carbon RegisterEventHotKey is the SINGLE hotkey path — it works globally
// without accessibility permission. Toggle happens on key-DOWN only;
// key-UP only clears the held flag (auto-repeat suppression).
// Both hotkeys share ONE Carbon event handler (installed once); the
// EventHotKeyID signature routes to dictate vs action.

private var gDictationHotKeyRef: EventHotKeyRef?
private var gActionHotKeyRef: EventHotKeyRef?
private var gDictationEventHandlerRef: EventHandlerRef?
// The UPP closure below must be retained for the app's lifetime — Carbon
// calls it on every hotkey press. Keeping only the EventHandlerRef (as before)
// left the UPP on the stack: first press worked, second press jumped to
// freed memory (EXC_BAD_ACCESS) and the frontend "vanished".
private var gDictationEventHandlerUPP: EventHandlerUPP?
private let gDictationHotKeySignature: OSType = OSType(0x4A565354) // "JVST"
private let gActionHotKeySignature: OSType = OSType(0x4A565341) // "JVSA"

// Held-state tracking — suppress auto-repeat. Separate flags per hotkey so
// holding ⌘⇧D can't swallow a ⌘⇧A press and vice versa.
// Lives outside any class so the C callback can touch it.
// Only accessed from the main queue (all hotkey events hop there).
private var gDictationHotkeyHeld = false
private var gActionHotkeyHeld = false

/// Resets the hotkey held-state. Called when a dictation cycle completes
/// (dismiss/close) so a stale held flag can't swallow the next press.
func resetDictationHotkeyHeldState() {
    DispatchQueue.main.async {
        gDictationHotkeyHeld = false
    }
}

/// Same, for the action pill (⌘⇧A).
func resetActionHotkeyHeldState() {
    DispatchQueue.main.async {
        gActionHotkeyHeld = false
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

    guard err == noErr else { return noErr }
    guard hkID.signature == gDictationHotKeySignature || hkID.signature == gActionHotKeySignature else { return noErr }
    let isAction = hkID.signature == gActionHotKeySignature

    let kind = GetEventKind(event)
    let isPress = (kind == UInt32(kEventHotKeyPressed))

    DispatchQueue.main.async {
        if isPress {
            // Toggle ON the first key-down only.
            // Suppress auto-repeat presses while the key is held.
            if isAction {
                guard !gActionHotkeyHeld else { return }
                gActionHotkeyHeld = true
                NSLog("[Jarvis][Hotkey] DOWN — toggle action")
                DictationController.shared.toggleAction()
            } else {
                guard !gDictationHotkeyHeld else { return }
                gDictationHotkeyHeld = true
                NSLog("[Jarvis][Hotkey] DOWN — toggle dictation")
                DictationController.shared.toggleDictation()
            }
        } else {
            // Release: clear the held flag, do NOT toggle.
            if isAction {
                gActionHotkeyHeld = false
            } else {
                gDictationHotkeyHeld = false
            }
        }
    }

    return noErr
}

func registerDictationHotkey() {
    // Idempotent: re-registering without unregister leaks an EventHotKeyRef
    // per call (app relaunch paths, tests). Tear down first.
    unregisterDictationHotkey()

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

    // Action pill (⌘⇧A) — same shared Carbon handler, own signature + id.
    var actionHotKeyID = EventHotKeyID(signature: gActionHotKeySignature, id: 2)

    let actionStatus = RegisterEventHotKey(
        UInt32(kVK_ANSI_A),
        UInt32(cmdKey | shiftKey),
        actionHotKeyID,
        GetEventDispatcherTarget(),
        0,
        &gActionHotKeyRef
    )

    if actionStatus == noErr {
        NSLog("[Jarvis][Hotkey] Carbon hotkey registered (⌘⇧A)")
    } else {
        NSLog("[Jarvis][Hotkey] Action registration failed: \(actionStatus)")
    }

    var specs: [EventTypeSpec] = [
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
        EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
    ]

    let handler: EventHandlerUPP = { _, event, _ in
        dictationHotkeyEventHandler(nil, event, nil)
    }
    // Retain the UPP itself (not just the handler ref) — see note above.
    gDictationEventHandlerUPP = handler

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
    // Retain the handler ref so it can be removed on terminate —
    // otherwise each register leaks a Carbon event handler.
    gDictationEventHandlerRef = installed

    if installErr == noErr {
        NSLog("[Jarvis][Hotkey] Carbon event handler installed")
    } else {
        NSLog("[Jarvis][Hotkey] Event handler install failed: \(installErr)")
    }
}

func unregisterDictationHotkey() {
    if let ref = gDictationHotKeyRef { UnregisterEventHotKey(ref) }
    gDictationHotKeyRef = nil
    if let ref = gActionHotKeyRef { UnregisterEventHotKey(ref) }
    gActionHotKeyRef = nil
    if let handler = gDictationEventHandlerRef { RemoveEventHandler(handler) }
    gDictationEventHandlerRef = nil
    gDictationEventHandlerUPP = nil
    gDictationHotkeyHeld = false
    gActionHotkeyHeld = false
}
