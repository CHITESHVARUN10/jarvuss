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
private var gRecoveryHotKeyRef: EventHotKeyRef?
private var gDictationEventHandlerRef: EventHandlerRef?
// Keep the registered C callback and handler together until unregistration.
private var gDictationEventHandlerUPP: EventHandlerUPP?
private let gDictationHotKeySignature: OSType = OSType(0x4A565354) // "JVST"
private let gActionHotKeySignature: OSType = OSType(0x4A565341) // "JVSA"

// Held-state tracking — suppress auto-repeat. Separate flags per hotkey so
// holding ⌘⇧D can't swallow a ⌘⇧A press and vice versa.
// Lives outside any class so the C callback can touch it.
// Only accessed from the main queue (all hotkey events hop there).
struct HotkeyLatch {
    private(set) var held = false
    mutating func press() -> Bool {
        guard !held else { return false }
        held = true
        return true
    }
    mutating func release() { held = false }
    mutating func recover(physicalKeyDown: Bool) {
        if !physicalKeyDown { release() }
    }
}

private var gDictationLatch = HotkeyLatch()
private var gActionLatch = HotkeyLatch()
private var gRecoveryLatch = HotkeyLatch()
private var gHotkeyReleaseTimer: Timer?

/// System permission dialogs can consume a Carbon key-up. Poll only while
/// a registered key is held, so one missed release cannot disable it forever.
@MainActor
private func watchHotkeyRelease() {
    guard gHotkeyReleaseTimer == nil else { return }
    let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
        MainActor.assumeIsolated {
            gDictationLatch.recover(physicalKeyDown: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_D)))
            gActionLatch.recover(physicalKeyDown: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_A)))
            gRecoveryLatch.recover(physicalKeyDown: CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_R)))
            if !gDictationLatch.held && !gActionLatch.held && !gRecoveryLatch.held {
                gHotkeyReleaseTimer?.invalidate()
                gHotkeyReleaseTimer = nil
            }
        }
    }
    gHotkeyReleaseTimer = timer
    RunLoop.main.add(timer, forMode: .common)
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
    let isRecovery = hkID.id == 3
    let isAction = hkID.signature == gActionHotKeySignature

    let kind = GetEventKind(event)
    let isPress = (kind == UInt32(kEventHotKeyPressed))

    DispatchQueue.main.async {
        if isRecovery {
            if isPress {
                guard gRecoveryLatch.press() else { return }
                watchHotkeyRelease()
                DisplayRecovery.shared.restore()
            } else { gRecoveryLatch.release() }
            return
        }
        if isPress {
            // Toggle ON the first key-down only.
            // Suppress auto-repeat presses while the key is held.
            if isAction {
                guard gActionLatch.press() else { return }
                watchHotkeyRelease()
                NSLog("[Jarvis][Hotkey] DOWN — toggle action")
                PillShortcutCoordinator.shared.press(.action)
            } else {
                guard gDictationLatch.press() else { return }
                watchHotkeyRelease()
                NSLog("[Jarvis][Hotkey] DOWN — toggle dictation")
                PillShortcutCoordinator.shared.press(.dictate)
            }
        } else {
            // Release: clear the held flag, do NOT toggle.
            if isAction {
                gActionLatch.release()
            } else {
                gDictationLatch.release()
            }
        }
    }

    return noErr
}

@MainActor
func registerDictationHotkey() {
    // Idempotent: re-registering without unregister leaks an EventHotKeyRef
    // per call (app relaunch paths, tests). Tear down first.
    unregisterDictationHotkey()

    let hotKeyID = EventHotKeyID(signature: gDictationHotKeySignature, id: 1)

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
    let actionHotKeyID = EventHotKeyID(signature: gActionHotKeySignature, id: 2)

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

    let recoveryStatus = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(cmdKey | shiftKey),
        EventHotKeyID(signature: gDictationHotKeySignature, id: 3), GetEventDispatcherTarget(), 0, &gRecoveryHotKeyRef)
    DisplayRecovery.shared.shortcutRegistered = recoveryStatus == noErr
    NSLog("[Jarvis][Display recovery] ⌘⇧R registration: %d", recoveryStatus)

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

@MainActor
func unregisterDictationHotkey() {
    DisplayRecovery.shared.shortcutRegistered = false
    if let ref = gDictationHotKeyRef { UnregisterEventHotKey(ref) }
    gDictationHotKeyRef = nil
    if let ref = gActionHotKeyRef { UnregisterEventHotKey(ref) }
    gActionHotKeyRef = nil
    if let ref = gRecoveryHotKeyRef { UnregisterEventHotKey(ref) }
    gRecoveryHotKeyRef = nil
    if let handler = gDictationEventHandlerRef { RemoveEventHandler(handler) }
    gDictationEventHandlerRef = nil
    gDictationEventHandlerUPP = nil
    gDictationLatch.release()
    gActionLatch.release()
    gRecoveryLatch.release()
    gHotkeyReleaseTimer?.invalidate()
    gHotkeyReleaseTimer = nil
}
