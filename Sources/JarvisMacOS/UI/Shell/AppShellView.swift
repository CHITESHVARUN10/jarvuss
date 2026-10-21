import SwiftUI

/// The Noir shell: labelled sidebar, breadcrumb toolbar, one full-width page,
/// a session-only inspector for the assistant, and the activity footer.
struct AppShellView: View {
    @ObservedObject var appState: AppState

    @StateObject private var feed = AssistantFeed()
    @StateObject private var toasts = ToastCenter()
    @State private var activityOpen = false
    @State private var preferencesOpen = false

    var body: some View {
        HStack(spacing: 0) {
            NoirSidebar(appState: appState)

            VStack(spacing: 0) {
                NoirToolbar(appState: appState, onPreferences: { preferencesOpen = true })

                HStack(spacing: 0) {
                    ZStack(alignment: .bottom) {
                        page
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if activityOpen {
                            NoirActivityDrawer(appState: appState, isOpen: $activityOpen)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .zIndex(2)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    if appState.activeSection == .assistant {
                        NoirInspector(
                            appState: appState,
                            feed: feed,
                            onOpenPreferences: { preferencesOpen = true },
                            onOpenVoice: { appState.activeSection = .voice }
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                NoirFooter(appState: appState, activityOpen: $activityOpen)
            }
        }
        .background(NoirPalette.base)
        .preferredColorScheme(.dark)
        .environmentObject(toasts)
        .overlay(alignment: .bottom) {
            if let message = toasts.message {
                NoirToastView(text: message)
                    .padding(.bottom, 55)
                    .zIndex(20)
            }
        }
        .sheet(isPresented: $preferencesOpen) {
            AssistantPreferencesSheet(appState: appState)
                .environmentObject(toasts)
        }
        .onChange(of: appState.activeSection) { _, _ in
            if activityOpen {
                withAnimation(.easeOut(duration: 0.18)) { activityOpen = false }
            }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch appState.activeSection {
        case .assistant:
            AssistantWorkspace(
                appState: appState,
                feed: feed,
                onOpenPreferences: { preferencesOpen = true }
            )
        case .voice:
            NoirVoicePage(appState: appState)
        case .routines:
            NoirRoutinesPage(appState: appState)
        case .insights:
            NoirInsightsPage(appState: appState)
        case .system:
            NoirSystemPage(appState: appState)
        case .connections:
            NoirConnectionsPage(appState: appState)
        case .setup:
            NoirSetupPage(appState: appState)
        case .about:
            NoirAboutPage(appState: appState)
        }
    }
}
