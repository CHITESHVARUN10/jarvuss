import SwiftUI

// MARK: - Routines

struct NoirRoutinesPage: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var toasts: ToastCenter

    @State private var editorItem: RoutineEditorItem?
    @State private var deleteTarget: VoiceAutomation?

    var body: some View {
        NoirPage(
            eyebrow: "Your day, a little easier",
            title: "One phrase. More done.",
            sub: "Bring a few actions together and give them a name.",
            trailing: AnyView(
                Button {
                    editorItem = .new
                } label: {
                    Label("New routine", systemImage: "plus")
                }
                .buttonStyle(NoirButtonStyle(intent: .primary))
            )
        ) {
            if appState.automations.isEmpty {
                NoirCard(padded: true) {
                    VStack(spacing: 8) {
                        Image(systemName: "bolt")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(NoirPalette.muted)
                        Text("Your next shortcut starts here.\nCreate your first routine.")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(NoirPalette.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else {
                VStack(spacing: 11) {
                    ForEach(appState.automations) { routine in
                        routineCard(routine)
                    }
                }
            }

            NoirCard(padded: true) {
                HStack(spacing: 9) {
                    Image(systemName: "bolt")
                        .font(.system(size: 14))
                        .foregroundStyle(NoirPalette.accent)
                    Text("Built around your words")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NoirPalette.accent)
                }
                Text("Open apps and folders, play music, and start timers. Say your routine’s phrase to run its actions in order. Add an off phrase to make it easy to stop.")
                    .font(.system(size: 11))
                    .lineSpacing(5)
                    .foregroundStyle(NoirPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }
            .padding(.top, 27)

            Text("Routines are stored locally on this Mac and run in order.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 18)
        }
        .sheet(item: $editorItem) { item in
            RoutineEditorSheet(appState: appState, editing: item.routine)
                .environmentObject(toasts)
        }
        .alert("Delete this routine?", isPresented: deleteBinding) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete routine", role: .destructive) {
                if let target = deleteTarget {
                    appState.deleteAutomation(id: target.id)
                    toasts.show("Routine removed.")
                }
                deleteTarget = nil
            }
        } message: {
            Text("Remove “\(deleteTarget?.keyword ?? "")”?")
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func routineCard(_ routine: VoiceAutomation) -> some View {
        NoirCard(padded: true) {
            HStack(spacing: 15) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(NoirPalette.accentSoft)
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(NoirPalette.accent.opacity(0.09), lineWidth: 1)
                    Image(systemName: "bolt")
                        .font(.system(size: 16))
                        .foregroundStyle(NoirPalette.accent)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 0) {
                    Text(routine.keyword)
                        .font(.system(size: 13))
                        .foregroundStyle(NoirPalette.text)
                    Text(stepSummary(routine))
                        .font(.system(size: 11))
                        .lineSpacing(4)
                        .foregroundStyle(NoirPalette.muted)
                        .padding(.top, 7)
                    if let off = routine.offKeyword, !off.isEmpty {
                        Text("Off phrase: “\(off)”")
                            .font(.system(size: 11))
                            .foregroundStyle(NoirPalette.muted)
                            .padding(.top, 5)
                    }
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    NoirIconButton(icon: "play", help: "Run routine") {
                        appState.activeSection = .assistant
                        appState.commandInput = routine.keyword
                        appState.executeTypedCommand()
                    }
                    NoirIconButton(icon: "pencil", help: "Edit routine") {
                        editorItem = .edit(routine)
                    }
                    NoirIconButton(icon: "trash", help: "Delete routine") {
                        deleteTarget = routine
                    }
                }
            }
        }
    }

    private func stepSummary(_ routine: VoiceAutomation) -> String {
        routine.actions.map { action in
            action.value.isEmpty
                ? action.type.displayName
                : "\(action.type.displayName) · \(action.value)"
        }
        .joined(separator: "   →   ")
    }
}

// MARK: - Editor routing

enum RoutineEditorItem: Identifiable {
    case new
    case edit(VoiceAutomation)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let routine): return routine.id.uuidString
        }
    }

    var routine: VoiceAutomation? {
        if case .edit(let routine) = self { return routine }
        return nil
    }
}

// MARK: - Routine editor

struct RoutineEditorSheet: View {
    @ObservedObject var appState: AppState
    let editing: VoiceAutomation?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toasts: ToastCenter

    @State private var keyword: String
    @State private var offKeyword: String
    @State private var actions: [AutomationAction]
    @State private var errorText: String?

    init(appState: AppState, editing: VoiceAutomation?) {
        _appState = ObservedObject(wrappedValue: appState)
        self.editing = editing
        _keyword = State(initialValue: editing?.keyword ?? "")
        _offKeyword = State(initialValue: editing?.offKeyword ?? "")
        _actions = State(initialValue: editing?.actions ?? [AutomationAction(type: .openApp, value: "")])
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "A new routine" : "Edit routine")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(NoirPalette.text)
                Spacer()
                NoirIconButton(icon: "xmark", help: "Close") { dismiss() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    TextField("e.g. Focus time", text: $keyword)
                        .noirField()
                        .noirFieldLabel("Trigger phrase")

                    TextField("e.g. End focus", text: $offKeyword)
                        .noirField()
                        .noirFieldLabel("Off phrase · optional")

                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Actions, in order")
                                .font(.system(size: 11))
                                .foregroundStyle(NoirPalette.secondary)
                            Spacer()
                            Button {
                                actions.append(AutomationAction(type: .openApp, value: ""))
                            } label: {
                                Label("Add action", systemImage: "plus")
                            }
                            .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                        }
                        .padding(.bottom, 10)

                        VStack(spacing: 9) {
                            ForEach($actions) { $action in
                                actionRow($action)
                            }
                        }
                    }

                    if let errorText {
                        Text(errorText)
                            .font(.system(size: 11))
                            .foregroundStyle(NoirPalette.red)
                    }

                    Text("Say the trigger phrase to run these actions in sequence.")
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.muted)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
            }
            .frame(maxHeight: 480)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(NoirButtonStyle(intent: .quiet))
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Create routine" : "Save changes") {
                    save()
                }
                .buttonStyle(NoirButtonStyle(intent: .primary))
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }
        }
        .frame(width: 540)
        .background(NoirPalette.base)
        .preferredColorScheme(.dark)
    }

    private func actionRow(_ action: Binding<AutomationAction>) -> some View {
        HStack(spacing: 8) {
            NoirSelect(
                options: AutomationActionType.allCases.map { ($0, $0.displayName) },
                selection: Binding(
                    get: { action.wrappedValue.type },
                    set: { newType in
                        action.wrappedValue.type = newType
                        if !newType.requiresValue { action.wrappedValue.value = "" }
                    }
                ),
                width: 160
            )

            if action.wrappedValue.type.requiresValue {
                TextField(action.wrappedValue.type.placeholder, text: action.value)
                    .noirField()
            } else {
                Text("No value")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            NoirIconButton(icon: "xmark", help: "Remove action") {
                actions.removeAll { $0.id == action.wrappedValue.id }
                if actions.isEmpty {
                    actions.append(AutomationAction(type: .openApp, value: ""))
                }
            }
        }
    }

    private func save() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorText = "Give the routine a trigger phrase."
            return
        }

        let cleaned = actions.filter {
            !$0.type.requiresValue || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !cleaned.isEmpty else {
            errorText = "Add at least one action with a value."
            return
        }

        if appState.automations.contains(where: {
            $0.id != editing?.id && $0.keyword.lowercased() == trimmed.lowercased()
        }) {
            errorText = "Choose a unique trigger phrase."
            return
        }

        appState.saveAutomation(
            keyword: trimmed,
            offKeyword: offKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : offKeyword,
            actions: cleaned,
            editingID: editing?.id
        )
        toasts.show(editing == nil ? "Routine created." : "Routine saved.")
        dismiss()
    }
}
