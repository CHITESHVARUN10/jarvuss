import SwiftUI

/// The new shell: rail + stage + panel, replacing the old single left panel.
struct AppShellView: View {
    @ObservedObject var appState: AppState
    @State private var section: RailSection = .assistant

    var body: some View {
        GeometryReader { proxy in
            // Mock `@media (max-width:1180px)`: narrower panel, tighter gutters.
            let compact = proxy.size.width < 1180

            HStack(spacing: 0) {
                RailView(appState: appState, section: $section)

                StageView(appState: appState, compact: compact)
                    .frame(minWidth: 420, maxWidth: .infinity)

                PanelView(appState: appState, section: $section, compact: compact)
            }
        }
        .background(JColor.base)
    }
}
