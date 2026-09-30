import SwiftUI

struct AutomationManagerView: View {
    @ObservedObject var appState: AppState
    @Binding var isModalOpen: Bool

    @State private var keyword: String = ""
    @State private var offKeyword: String = ""
    @State private var actions: [AutomationAction] = [AutomationAction(type: .openApp, value: "")]
    @State private var editingID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Automations")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(JarvisColor.textPrimary)
                Spacer()
                Button {
                    closeModal()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(JarvisColor.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close automation dialog")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Keyword")
                    .font(JarvisType.title)
                    .foregroundStyle(JarvisColor.textPrimary)
                TextField("e.g. grind mode", text: $keyword)
                    .quietField()
                TextField("optional off keyword (e.g. grind mode off)", text: $offKeyword)
                    .quietField()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Actions")
                    .font(JarvisType.title)
                    .foregroundStyle(JarvisColor.textPrimary)
                VStack(spacing: 8) {
                    ForEach($actions) { $action in
                        HStack(spacing: 8) {
                            Picker("Type", selection: $action.type) {
                                ForEach(AutomationActionType.allCases) { type in
                                    Text(type.displayName).tag(type)
                                }
                            }
                            .frame(width: 170)

                            if action.type.requiresValue {
                                TextField(action.type.placeholder, text: $action.value)
                                    .quietField()
                            } else {
                                Text("No value")
                                    .font(JarvisType.caption)
                                    .foregroundStyle(JarvisColor.textTertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                actions.removeAll { $0.id == action.id }
                                if actions.isEmpty {
                                    actions.append(AutomationAction(type: .openApp, value: ""))
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(JarvisColor.textTertiary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        actions.append(AutomationAction(type: .openApp, value: ""))
                    } label: {
                        Label("Add action", systemImage: "plus")
                    }
                }
            }

            HStack(spacing: 10) {
                Button(editingID == nil ? "Save automation" : "Update automation") {
                    appState.saveAutomation(
                        keyword: keyword,
                        offKeyword: offKeyword.isEmpty ? nil : offKeyword,
                        actions: actions,
                        editingID: editingID
                    )
                    closeModal(resetFields: true)
                }
                .buttonStyle(JarvisButtonStyle(color: JarvisColor.accent, compact: false))

                Button("Cancel") {
                    closeModal(resetFields: true)
                }
                .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: false))
                .keyboardShortcut(.cancelAction)

                Button("Reset") {
                    resetForm()
                }
                .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: false))
            }

            Divider()
                .overlay(JarvisColor.hairline)

            Text("Saved automations")
                .font(JarvisType.title)
                .foregroundStyle(JarvisColor.textPrimary)

            List {
                ForEach(appState.automations) { automation in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Keyword: \(automation.keyword)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(JarvisColor.textPrimary)
                            Spacer()
                            Button("Edit") {
                                editingID = automation.id
                                keyword = automation.keyword
                                offKeyword = automation.offKeyword ?? ""
                                actions = automation.actions.isEmpty
                                    ? [AutomationAction(type: .openApp, value: "")]
                                    : automation.actions
                            }
                            .buttonStyle(.borderless)

                            Button("Delete") {
                                appState.deleteAutomation(id: automation.id)
                                if editingID == automation.id {
                                    resetForm()
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(JarvisColor.danger)
                        }

                        if let off = automation.offKeyword, !off.isEmpty {
                            Text("Off: \(off)")
                                .font(JarvisType.caption)
                                .foregroundStyle(JarvisColor.textSecondary)
                        }

                        Text(automation.actions.map { "\($0.type.rawValue)(\($0.value))" }.joined(separator: " • "))
                            .font(JarvisType.dataSmall)
                            .foregroundStyle(JarvisColor.textTertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 220)
            .scrollContentBackground(.hidden)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
        .background(JarvisColor.canvas)
        .onExitCommand {
            closeModal()
        }
    }

    private func closeModal(resetFields: Bool = true) {
        if resetFields {
            resetForm()
        }
        isModalOpen = false
    }

    private func resetForm() {
        editingID = nil
        keyword = ""
        offKeyword = ""
        actions = [AutomationAction(type: .openApp, value: "")]
    }
}
