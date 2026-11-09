import SwiftUI
import AppKit

/// Live session UI. Suggestions only populate the composer; execution always
/// goes through the existing typed-command / shortcut pipelines.
struct AssistantWorkspace: View {
    @ObservedObject var appState: AppState
    @ObservedObject var feed: AssistantFeed
    @ObservedObject private var responseEngine = ResponseEngine.shared
    var onToggleInspector: () -> Void = {}
    var inspectorAvailable = true
    var orbSize: CGFloat = 190
    @State private var inputMode = "command"
    @State private var composerFocused = false
    @State private var focusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            session(orbSize: min(orbSize, max(150, proxy.size.height * 0.30)))
        }
    }
    private func session(orbSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            sessionToolbar
            VStack(spacing: 0) {
                Button(action: toggleListening) {
                    AssistantOrbView(isListening: appState.isLiveListening).frame(width: orbSize, height: orbSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appState.isLiveListening ? "Stop listening" : "Start listening")
                VStack(alignment: .center, spacing: 9) {
                    Text(appState.isLiveListening ? "Listening for a command." : "Ready for a command.")
                        .obsidianFont(size: 19, weight: .medium).foregroundStyle(NoirPalette.text)
                    Text("Control your apps, open a project, or dictate at your cursor.")
                        .obsidianFont(size: 12).lineSpacing(4).multilineTextAlignment(.center).foregroundStyle(NoirPalette.secondary)
                    HStack(spacing: 6) {
                        Circle().fill(appState.isLiveListening ? NoirPalette.accent : NoirPalette.muted).frame(width: 4, height: 4)
                        Text(stateLine).obsidianFont(size: 9).foregroundStyle(NoirPalette.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 2).padding(.bottom, 20)
            .overlay(alignment: .bottom) { Rectangle().fill(NoirPalette.hairline).frame(height: 1) }
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 17) {
                        if feed.items.isEmpty {
                            Text("No commands in this session.").obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 35)
                        }
                        ForEach(feed.items) { item in message(item) }
                        Color.clear.frame(height: 1).id("conversation-end")
                    }.padding(.horizontal, 24).padding(.vertical, 22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: feed.items.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { scroll.scrollTo("conversation-end", anchor: .bottom) }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                composer
                HStack(spacing: 6) {
                    suggestion("Open project", command: "open my projects in Finder")
                    suggestion("New tab in Brave", command: "open a new tab in Brave")
                    suggestion("Play a song", command: "play Dreams by Fleetwood Mac")
                }
            }.padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 19)
        }
        .background(NoirPalette.base)
        .onChange(of: appState.currentCommand) { _, command in noteUser(command) }
        .onChange(of: responseEngine.latestMessage?.id) { _, _ in
            guard let message = responseEngine.latestMessage, !message.text.isEmpty else { return }
            feed.addAssistant(message.text, succeeded: message.succeeded)
        }
    }
    private var sessionToolbar: some View {
        HStack(spacing: 9) {
            Text("Assistant").obsidianFont(size: 11, weight: .semibold).foregroundStyle(NoirPalette.text)
            Text("Local session").obsidianFont(size: 8).foregroundStyle(NoirPalette.muted).padding(4)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(NoirPalette.line, lineWidth: 1))
            Spacer()
            Button { feed.reset() } label: { Label("New session", systemImage: "plus").obsidianFont(size: 10) }
                .buttonStyle(.plain).foregroundStyle(NoirPalette.secondary)
            if inspectorAvailable { NoirIconButton(icon: "sidebar.right", help: "Toggle session inspector", action: onToggleInspector) }
        }.padding(.horizontal, 20).frame(height: 43).background(NoirPalette.footer)
            .overlay(alignment: .bottom) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
    }
    private var stateLine: String {
        guard appState.isLiveListening else { return "Standby · microphone off" }
        switch appState.assistantState {
        case .idle, .listening: return "Listening · microphone live"
        case .recording: return "Recording · microphone live"
        case .processing: return "Processing on this Mac"
        case .executing: return "Executing command"
        }
    }
    private func toggleListening() {
        if appState.isLiveListening { appState.stopMicrophone() }
        else { appState.noteManualMicStart(); Task { await appState.startMicrophone() } }
    }
    private func message(_ item: AssistantFeed.Item) -> some View {
        let user = item.role == .user
        return HStack(alignment: .top, spacing: 9) {
            if user { Spacer(minLength: 45) }
            else {
                Image(systemName: "sparkle").obsidianFont(size: 11).foregroundStyle(NoirPalette.accent)
                    .frame(width: 24, height: 24).background(NoirPalette.accentSoft, in: RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 9) {
                if !user { Text("Jarvis").obsidianFont(size: 10, weight: .medium).foregroundStyle(NoirPalette.secondary) }
                Text(item.text).obsidianFont(size: 12).lineSpacing(5).textSelection(.enabled)
                    .foregroundStyle(NoirPalette.text).padding(12)
                    .frame(maxWidth: user ? nil : .infinity, alignment: .leading)
                    .background(user ? NoirPalette.raised : NoirPalette.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NoirPalette.line, lineWidth: 1))
                if !user, let succeeded = item.succeeded {
                    Label(succeeded ? "Handled" : "Couldn’t complete", systemImage: succeeded ? "checkmark" : "exclamationmark.circle")
                        .obsidianFont(size: 9).foregroundStyle(succeeded ? NoirPalette.green : NoirPalette.orange)
                }
                if !user, item.id == feed.items.last?.id {
                    Button("Review latest command") { appState.activeSection = .system }.obsidianFont(size: 9).buttonStyle(.plain).foregroundStyle(NoirPalette.muted)
                }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 10) {
            HStack {
                ObsidianCommandField(text: $appState.commandInput, focusRequest: focusRequest, onFocus: { composerFocused = $0 }, onSubmit: submitTyped)
                    .frame(minHeight: 30)
                Button(action: submitTyped) {
                    Image(systemName: "arrow.up").obsidianFont(size: 15, weight: .semibold).foregroundStyle(canSend ? NoirPalette.onAccent : .white.opacity(0.7))
                        .frame(width: 32, height: 32).background(canSend ? NoirPalette.accent : NoirPalette.raised, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).disabled(!canSend).help("Run command").accessibilityLabel("Run command")
            }
            HStack(spacing: 8) {
                Text("Record").obsidianFont(size: 9).foregroundStyle(NoirPalette.muted)
                Picker("Recording mode", selection: $inputMode) {
                    Text("Command").tag("command"); Text("Dictation").tag("dictation")
                }.labelsHidden().pickerStyle(.menu).frame(width: 104).controlSize(.small)
                NoirIconButton(icon: "mic", help: inputMode == "command" ? "Record a command" : "Start dictation") {
                    PillShortcutCoordinator.shared.press(inputMode == "command" ? .action : .dictate)
                }
                Spacer()
                Text("⌘⇧A command · ⌘⇧D dictation").obsidianFont(size: 9).foregroundStyle(NoirPalette.muted)
            }
        }.padding(12).background(NoirPalette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(composerFocused ? NoirPalette.accent.opacity(0.65) : NoirPalette.lineStrong, lineWidth: 1))
    }
    private var canSend: Bool { !appState.commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func submitTyped() { guard canSend else { return }; noteUser(appState.commandInput); appState.executeTypedCommand() }
    private func noteUser(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !(feed.items.last?.role == .user && feed.items.last?.text == trimmed) else { return }
        feed.addUser(trimmed)
    }
    private func suggestion(_ label: String, command: String) -> some View {
        Button(label) { appState.commandInput = command; focusRequest += 1 }.obsidianFont(size: 9).buttonStyle(.plain)
            .foregroundStyle(NoirPalette.secondary).padding(.horizontal, 7).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(NoirPalette.line, lineWidth: 1))
    }
}

/// Used by older presentation surfaces, backed by the same selected 3D style.
struct NoirOrb: View {
    let isListening: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) { AssistantOrbView(isListening: isListening) }.buttonStyle(.plain)
            .accessibilityLabel(isListening ? "Stop listening" : "Start listening")
    }
}
