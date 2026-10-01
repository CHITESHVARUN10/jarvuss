import SwiftUI

/// Right-hand panel from the mock: 340pt wide (300 when compact), a pinned
/// `.panel-head`, and a pane body that centers in the space under it.
struct PanelView: View {
    @ObservedObject var appState: AppState
    @Binding var section: RailSection
    /// Mock `@media (max-width:1180px)`.
    var compact: Bool = false

    private var panelWidth: CGFloat { compact ? 300 : 340 }

    var body: some View {
        VStack(spacing: 0) {
            JPanelHead(title: headTitle, sub: headSub)

            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    pane
                        .padding(.horizontal, 22)
                        .padding(.top, 6)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
            }
        }
        .frame(width: panelWidth)
        .background(JColor.base)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(JColor.line),
            alignment: .leading
        )
        .animation(.easeOut(duration: 0.2), value: section)
    }

    private var headTitle: String {
        switch section {
        case .assistant:   return "Assistant"
        case .voice:       return "Voice"
        case .insights:    return "Insights"
        case .routines:    return "Routines"
        case .system:      return "System"
        case .connections: return "Connections"
        case .about:       return "About"
        }
    }

    private var headSub: String {
        switch section {
        case .assistant:   return "How Jarvis should behave"
        case .voice:       return "Your speaker profile"
        case .insights:    return "Your usage, on device"
        case .routines:    return "Say a keyword, Jarvis handles the rest"
        case .system:      return "Display and safety"
        case .connections: return "Your integrations"
        case .about:       return "Jarvis for macOS"
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .assistant:
            AssistantPane(appState: appState)
        case .voice:
            VoicePane(appState: appState)
        case .insights:
            InsightsPane(appState: appState)
        case .routines:
            RoutinesPane(appState: appState)
        case .system:
            SystemPane(appState: appState)
        case .connections:
            ConnectionsPane(appState: appState)
        case .about:
            AboutPane(appState: appState)
        }
    }
}
