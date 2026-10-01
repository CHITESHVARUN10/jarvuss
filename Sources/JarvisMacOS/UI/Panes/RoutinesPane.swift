import SwiftUI

/// Routines pane — new-routine button + saved routine rows; edits via the modal sheet.
struct RoutinesPane: View {
    @ObservedObject var appState: AppState
    @State private var isModalOpen = false

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
            .sheet(isPresented: $isModalOpen) {
                AutomationManagerView(appState: appState, isModalOpen: $isModalOpen)
            }
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isModalOpen = true
            } label: {
                Label("New routine", systemImage: "plus")
            }
            .jButton(intent: .primary, block: true)

            if appState.automations.isEmpty {
                JCard {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(JColor.ink4)
                        Text("No routines yet.\nCreate one to chain actions behind a phrase.")
                            .font(.system(size: 12))
                            .foregroundStyle(JColor.ink4)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .padding(.top, 9)
            } else {
                JCard(flush: true) {
                    ForEach(Array(appState.automations.enumerated()), id: \.element.id) { idx, automation in
                        routineRow(automation, first: idx == 0)
                    }
                }
                .padding(.top, 9)
            }
        }
    }

    private func routineRow(_ automation: VoiceAutomation, first: Bool) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(JColor.accentSoft)
                    .frame(width: 30, height: 30)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(JColor.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.keyword)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(JColor.ink)
                    .lineLimit(1)
                Text(describe(automation))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(JColor.ink4)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JColor.ink4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { isModalOpen = true }
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(JColor.line)
                    .frame(height: 1)
            }
        }
    }

    private func describe(_ automation: VoiceAutomation) -> String {
        let parts = automation.actions.map { action in
            action.value.isEmpty
                ? action.type.displayName
                : "\(action.type.displayName) “\(action.value)”"
        }
        return parts.joined(separator: " → ")
    }
}
