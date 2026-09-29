import SwiftUI
import AppKit

@main
struct MainApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(DictationAppDelegate.self) private var dictationDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Jarvis") {
            ContentView(appState: appState)
                .task {
                    await appState.bootstrap()
                }
                // NOTE: onDisappear must NOT shut down services — closing the
                // last WindowGroup window leaves the process + dock icon alive
                // (regular policy), and killing mic/backend here strands the
                // app windowless. Shutdown happens only on willTerminate.
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.shutdown()
                }
        }
    }
}