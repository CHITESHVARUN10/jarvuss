import SwiftUI

/// Settings opens General. Setup and About remain available without a second
/// connections destination or moving core service behavior into the renderer.
struct ObsidianSettingsPage: View {
    @ObservedObject var appState: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                settingsTab("General", section: .system)
                settingsTab("Setup", section: .setup)
                settingsTab("About", section: .about)
                Spacer()
            }
            .padding(.horizontal, 30).frame(height: 44)
            .background(NoirPalette.footer)
            .overlay(alignment: .bottom) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
            switch appState.activeSection {
            case .setup: NoirSetupPage(appState: appState)
            case .about: NoirAboutPage(appState: appState)
            default: NoirSystemPage(appState: appState)
            }
        }
    }
    private func settingsTab(_ title: String, section: RailSection) -> some View {
        Button { appState.activeSection = section } label: {
            Text(title).obsidianFont(size: 11, weight: .medium)
                .foregroundStyle(appState.activeSection == section ? NoirPalette.text : NoirPalette.muted)
                .frame(height: 44)
                .overlay(alignment: .bottom) {
                    if appState.activeSection == section { Rectangle().fill(NoirPalette.accent).frame(height: 2) }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(appState.activeSection == section ? .isSelected : [])
    }
}

struct ObsidianCoreServices: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var toasts: ToastCenter
    @State private var activeService: ConnectionKind?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Core services")
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Ollama", sub: appState.ollamaReachable ? "Local model service is available." : "Local model service is not responding.") {
                        Button("Details") { activeService = .ollama }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Native helper", sub: "Voice verification and event storage.") {
                        Text(appState.backendStatus).obsidianFont(size: 11).foregroundStyle(NoirPalette.secondary)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "PostgreSQL", sub: "Command activity and usage storage.") {
                        Button("Configure") { activeService = .postgres }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    }
                }
            }
        }
        .task { await appState.refreshPostgresStatus(); await appState.refreshOllamaStatus() }
        .sheet(item: $activeService) { kind in
            ConnectionSheet(appState: appState, kind: kind).environmentObject(toasts).presentationBackground(.clear)
        }
    }
}
