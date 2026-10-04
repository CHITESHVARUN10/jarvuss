import AppKit

/// App delegate — owns STT core lifecycle and the global dictation hotkey.
///
/// The main window + command pipeline keep running through MainApp/AppState;
/// this delegate only adds what a pure-SwiftUI App cannot do: Carbon hotkey
/// registration and one-time native startup.
final class DictationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)

        // Raise the window NOW, not in MainApp.init(). The init call happens
        // before any window exists, and only a bundled launch gets a
        // LaunchServices activation — so `swift run` produced a process with
        // a dock icon and a full-size window stranded UNDER the terminal
        // (looks exactly like "the app does not open"). did-finish-launching
        // is the first point where SwiftUI's scenes exist to be raised.
        NSApplication.shared.activate(ignoringOtherApps: true)

        DictationController.shared.launch()
        registerDictationHotkey()
        NSLog("[Jarvis] Dictation ready (⌘⇧D dictate · ⌘⇧A action)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterDictationHotkey()
    }

    // WindowGroup keeps the process alive after the last window closes
    // (regular policy → dock icon stays). Without this, dock-click does
    // nothing and the app looks "vanished". Reopen: activate + front any
    // existing window, or open a fresh main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSLog("[Jarvis] Reopen — visible windows: \(flag)")
        NSApp.activate(ignoringOtherApps: true)
        if !flag {
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
            // No window left at all — ask SwiftUI to recreate the main one.
            if let url = URL(string: "jarvis://main") {
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
