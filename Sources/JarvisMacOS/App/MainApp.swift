import SwiftUI
import AppKit

@main
struct MainApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(DictationAppDelegate.self) private var dictationDelegate

    init() {
        // Policy must be set early so the dock icon is correct; raising the
        // window lives in applicationDidFinishLaunching, where the scenes
        // actually exist to be raised (this init call was too early and a
        // dev-run stayed buried under the terminal forever).
        NSApplication.shared.setActivationPolicy(.regular)
        // The packaged app registers Contents/Resources/Fonts via
        // ATSApplicationFontsPath; dev runs register them here so the
        // dictation card renders its intended faces either way.
        JarvisFonts.registerBundledFonts()
        // Self-protection: terminate rather than let a runaway footprint
        // push the Mac into swap. Limit lives in Assistant → Behaviour.
        MemoryGuard.shared.start()
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