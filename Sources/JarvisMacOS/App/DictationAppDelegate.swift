import AppKit

/// App delegate — owns STT core lifecycle and the global dictation hotkey.
///
/// The main window + command pipeline keep running through MainApp/AppState;
/// this delegate only adds what a pure-SwiftUI App cannot do: Carbon hotkey
/// registration and one-time native startup.
final class DictationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        setvbuf(stdout, nil, _IONBF, 0)
        DictationController.shared.launch()
        registerDictationHotkey()
        NSLog("[Jarvis] Dictation ready (⌘⇧D)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterDictationHotkey()
    }
}
