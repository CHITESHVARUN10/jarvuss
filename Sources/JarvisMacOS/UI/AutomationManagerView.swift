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
                Text("Automation Manager")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button {
                    closeModal()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close automation dialog")
            }

            GroupBox("Keyword") {
                TextField("e.g. grind mode", text: $keyword)
                TextField("optional off keyword (e.g. grind mode off)", text: $offKeyword)
            }

            GroupBox("Actions") {
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
                            } else {
                                Text("No value")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                actions.removeAll { $0.id == action.id }
                                if actions.isEmpty {
                                    actions.append(AutomationAction(type: .openApp, value: ""))
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Button {
                        actions.append(AutomationAction(type: .openApp, value: ""))
                    } label: {
                        Label("Add Action", systemImage: "plus")
                    }
                }
            }

            HStack(spacing: 10) {
                Button(editingID == nil ? "Save Automation" : "Update Automation") {
                    appState.saveAutomation(
                        keyword: keyword,
                        offKeyword: offKeyword.isEmpty ? nil : offKeyword,
                        actions: actions,
                        editingID: editingID
                    )
                    closeModal(resetFields: true)
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel") {
                    closeModal(resetFields: true)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button("Reset") {
                    resetForm()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            Text("Saved Automations")
                .font(.headline)

            List {
                ForEach(appState.automations) { automation in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Keyword: \(automation.keyword)")
                                .font(.subheadline.weight(.semibold))
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
                            .foregroundStyle(.red)
                        }

                        if let off = automation.offKeyword, !off.isEmpty {
                            Text("Off: \(off)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(automation.actions.map { "\($0.type.rawValue)(\($0.value))" }.joined(separator: " • "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(minHeight: 220)
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 560)
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
