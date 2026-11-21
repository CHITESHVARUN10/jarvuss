import SwiftUI

struct ContentView: View {
    let appState: AppState
    @State private var detail: DesktopDetail?
    @StateObject private var toasts = ToastCenter()

    var body: some View {
        DesktopInterface(appState: appState) { detail = $0 }
            .overlay(alignment: .top) {
                Color.clear
                    .frame(width: 174, height: 52)
                    .contentShape(Rectangle())
                    .gesture(WindowDragGesture())
                    .accessibilityHidden(true)
            }
            .ignoresSafeArea()
            .frame(minWidth: 420, minHeight: 500)
            .preferredColorScheme(.dark)
            .sheet(item: $detail) { panel in
                Group {
                    switch panel {
                    case .setup(let kind):
                        SetupDetailSheet(appState: appState, kind: kind)
                    case .settings("behavior"):
                        AssistantPreferencesSheet(appState: appState)
                    case .settings(let group):
                        DesktopSettingsDetail(appState: appState, group: group)
                    }
                }
                .environmentObject(toasts)
                .presentationBackground(.clear)
            }
    }
}

private struct DesktopSettingsDetail: View {
    @ObservedObject var appState: AppState
    let group: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
            }.padding(12)
            switch group {
            case "display": NoirSystemPage(appState: appState, focusedGroup: .display)
            case "files": NoirSystemPage(appState: appState, focusedGroup: .projects)
            case "services": NoirSystemPage(appState: appState, focusedGroup: .services)
            default: NoirSystemPage(appState: appState, focusedGroup: .advanced)
            }
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 610)
        .background(GlassPanelBackground(behindWindow: false))
    }
}
