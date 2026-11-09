import SwiftUI

struct AppShellView: View {
    @ObservedObject var appState: AppState
    @StateObject private var feed = AssistantFeed()
    @StateObject private var toasts = ToastCenter()
    @State private var activityOpen = false
    @State private var preferencesOpen = false
    @State private var inspectorVisible = true
    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
                .environment(\.obsidianWindowWidth, proxy.size.width)
        }
    }
    private func content(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            NoirToolbar(appState: appState)
            HStack(spacing: 0) {
                NoirSidebar(appState: appState)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ZStack(alignment: .bottom) {
                            page(width: width).frame(maxWidth: .infinity, maxHeight: .infinity)
                            if activityOpen { NoirActivityDrawer(appState: appState, isOpen: $activityOpen).zIndex(2) }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        if appState.activeSection == .assistant, inspectorVisible, width >= 1000 {
                            NoirInspector(appState: appState, feed: feed, onOpenPreferences: { preferencesOpen = true }, onOpenVoice: { appState.activeSection = .voice }, width: min(320, max(234, width * 0.19)))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    NoirFooter(appState: appState, activityOpen: $activityOpen)
                }
            }
        }
        .background(NoirPalette.base).preferredColorScheme(.dark).obsidianFont(size: 13).tint(NoirPalette.accent)
        .environmentObject(toasts)
        .overlay(alignment: .bottom) {
            if let message = toasts.message { NoirToastView(text: message).padding(.bottom, 43).zIndex(20) }
        }
        .sheet(isPresented: $preferencesOpen) {
            AssistantPreferencesSheet(appState: appState).environmentObject(toasts).presentationBackground(.clear)
        }
        .onChange(of: appState.activeSection) { _, _ in activityOpen = false }
    }
    @ViewBuilder private func page(width: CGFloat) -> some View {
        switch appState.activeSection {
        case .assistant:
            AssistantWorkspace(appState: appState, feed: feed, onToggleInspector: { inspectorVisible.toggle() }, inspectorAvailable: width >= 1000, orbSize: min(270, max(190, width * 0.14)))
        case .voice: NoirVoicePage(appState: appState)
        case .routines: NoirRoutinesPage(appState: appState)
        case .insights: NoirInsightsPage(appState: appState)
        case .appearance: ObsidianAppearancePage()
        case .system, .setup, .about: ObsidianSettingsPage(appState: appState)
        }
    }
}
