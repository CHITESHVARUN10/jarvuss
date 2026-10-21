import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            NoirPalette.desktop
                .ignoresSafeArea()

            AppShellView(appState: appState)
                .ignoresSafeArea()

            if appState.popupManager.isVisible {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                PopupView(manager: appState.popupManager)
                    .frame(maxWidth: 360)
            }
        }
        .frame(minWidth: 1080, minHeight: 700)
    }
}
