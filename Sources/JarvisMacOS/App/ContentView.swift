import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            // ── Background ──────────────────────────────────────────
            JColor.base
                .ignoresSafeArea()

            // ── Layout: rail + stage + panel ────────────────────────
            AppShellView(appState: appState)

            // ── Popup overlay ────────────────────────────────────────
            if appState.popupManager.isVisible {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                PopupView(manager: appState.popupManager)
                    .frame(maxWidth: 360)
            }
        }
        .frame(minWidth: 1160, minHeight: 720)
    }
}
