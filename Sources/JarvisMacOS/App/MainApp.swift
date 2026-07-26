import SwiftUI
import AppKit

@main
struct MainApp: App {
    @StateObject private var appState = AppState()

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
                .onDisappear {
                    appState.shutdown()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.shutdown()
                }
        }
    }
}