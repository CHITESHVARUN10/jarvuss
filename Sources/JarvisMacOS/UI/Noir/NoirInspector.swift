import SwiftUI
import AppKit

struct NoirInspector: View {
    @ObservedObject var appState: AppState
    @ObservedObject var feed: AssistantFeed
    @ObservedObject private var projects = ProjectLocationStore.shared
    let onOpenPreferences: () -> Void
    let onOpenVoice: () -> Void
    var width: CGFloat = 234
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Session").obsidianFont(size: 10, weight: .medium)
                    Spacer()
                    Text("LOCAL").obsidianFont(size: 8).foregroundStyle(NoirPalette.muted)
                }.foregroundStyle(NoirPalette.secondary).frame(height: 43)
                NoirDivider()
                sectionLabel("Input")
                setting("Live listening", binding: Binding(get: { appState.isLiveListening }, set: { start in
                    if start { appState.noteManualMicStart(); Task { await appState.startMicrophone() } }
                    else { appState.stopMicrophone() }
                }))
                Label("System microphone", systemImage: "mic").obsidianFont(size: 10).foregroundStyle(NoirPalette.secondary)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading).background(NoirPalette.surface, in: RoundedRectangle(cornerRadius: 5))
                sectionLabel("Quick controls")
                ObsidianInspectorSound()
                setting("Verify commands", binding: $appState.actionPillRequiresVerify)
                setting("Spoken replies", binding: $appState.voiceResponseEnabled)
                sectionLabel("Workspace")
                Button { appState.activeSection = .system } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "folder").obsidianFont(size: 12).foregroundStyle(NoirPalette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(projects.locations.first(where: \.isRoot)?.name ?? "Project folders").obsidianFont(size: 11).foregroundStyle(NoirPalette.text)
                            Text(projects.locations.first(where: \.isRoot)?.path ?? "Choose a project location")
                                .obsidianFont(size: 9).foregroundStyle(NoirPalette.muted).lineLimit(2).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(NoirPalette.surface, in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
                sectionLabel("Voice & behavior")
                HStack {
                    Text(appState.voiceProfileReady ? "Voice profile ready" : "Voice profile not set").obsidianFont(size: 10).foregroundStyle(NoirPalette.secondary)
                    Spacer(minLength: 4)
                    Text("\(appState.backendEnrollmentSampleCount)").obsidianFont(size: 10, design: .monospaced).foregroundStyle(NoirPalette.muted)
                }
                Button("Manage voice profile", action: onOpenVoice).buttonStyle(.plain).obsidianFont(size: 10).foregroundStyle(NoirPalette.accent).padding(.top, 10)
                Button("Assistant preferences", action: onOpenPreferences).buttonStyle(.plain).obsidianFont(size: 10).foregroundStyle(NoirPalette.accent).padding(.top, 12)
                sectionLabel("Recent commands")
                let commands = feed.items.filter { $0.role == .user }.suffix(3).map(\.text)
                ForEach(Array(commands.reversed().enumerated()), id: \.offset) { _, command in
                    Text(command).obsidianFont(size: 10).foregroundStyle(NoirPalette.secondary).lineLimit(2).padding(.bottom, 10)
                }
                if commands.isEmpty { Text("No commands this session.").obsidianFont(size: 10).foregroundStyle(NoirPalette.muted) }
                Text("Speech is processed on this Mac.").obsidianFont(size: 9).foregroundStyle(NoirPalette.muted).padding(.top, 22)
            }.padding(.horizontal, 18).padding(.bottom, 20)
        }
        .frame(width: width).frame(maxHeight: .infinity).background(NoirPalette.footer)
        .overlay(alignment: .leading) { Rectangle().fill(NoirPalette.line).frame(width: 1) }
    }
    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased()).obsidianFont(size: 9, weight: .medium).tracking(0.7).foregroundStyle(NoirPalette.muted).padding(.top, 23).padding(.bottom, 13)
    }
    private func setting(_ title: String, binding: Binding<Bool>) -> some View {
        HStack { Text(title).obsidianFont(size: 11).foregroundStyle(NoirPalette.secondary); Spacer(minLength: 8); NoirSwitch(isOn: binding) }.padding(.bottom, 13)
    }
}

@MainActor
private struct ObsidianInspectorSound: View {
    @StateObject private var sound = SystemSoundModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var value = 0.0
    @State private var editing = false
    @State private var output: SystemAudioOutput?
    @State private var commit: Task<Void, Never>?
    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Text("Output volume")
                Spacer()
                Text(sound.snapshot?.level.map { "\(Int(($0 * 100).rounded()))%" } ?? "—").monospacedDigit()
            }.obsidianFont(size: 10).foregroundStyle(NoirPalette.secondary)
            Slider(value: Binding(get: { value }, set: { newValue in
                value = newValue
                guard !editing else { return }
                commit?.cancel()
                let expected = sound.snapshot?.output
                commit = Task {
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                    await sound.apply(.setLevel(Int(newValue.rounded())), to: expected)
                }
            }), in: 0...100) { began in
                commit?.cancel(); editing = began
                if began { output = sound.snapshot?.output }
                else {
                    let expected = output; output = nil
                    let target = Int(value.rounded())
                    Task { await sound.apply(.setLevel(target), to: expected) }
                }
            }.tint(NoirPalette.accent).controlSize(.small).accessibilityLabel("Output volume")
                .disabled(sound.snapshot?.canSetVolume != true || sound.isApplying)
        }.padding(.bottom, 16)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await sound.refresh(); sync()
                    do { try await Task.sleep(for: .seconds(3)) } catch { break }
                }
            }
            .onChange(of: sound.snapshot?.level) { _, _ in sync() }
            .onChange(of: sound.isApplying) { _, applying in if !applying { sync() } }
            .onDisappear { commit?.cancel() }
    }
    private func sync() { if !editing, let level = sound.snapshot?.level { value = Double(level) * 100 } }
}

// MARK: - Assistant preferences

struct AssistantPreferencesSheet: View {
    @ObservedObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Assistant preferences")
                    .obsidianFont(size: 15, weight: .medium)
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
                VStack(alignment: .leading, spacing: 0) {
                    NoirEyebrow(text: "Privacy")
                        .padding(.bottom, 12)

                    NoirCard {
                        VStack(spacing: 0) {
                            NoirSettingRow(
                                title: "Verify action commands",
                                sub: "Voice match before running ⌘⇧A."
                            ) {
                                NoirSwitch(isOn: $appState.actionPillRequiresVerify)
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Verify live mode",
                                sub: "Wake word followed by a voice match."
                            ) {
                                NoirSwitch(isOn: $appState.voiceModeRequiresVerify)
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Similarity threshold",
                                sub: "Required to execute a command."
                            ) {
                                Text(String(format: "%.2f", appState.voiceVerifyThreshold))
                                    .obsidianFont(size: 12, design: .monospaced)
                                    .foregroundStyle(NoirPalette.secondary)
                            }
                        }
                    }

                    NoirSectionHeading(title: "Behaviour")
                    NoirCard {
                        VStack(spacing: 0) {
                            NoirSettingRow(
                                title: "Backend helper",
                                sub: "Voice authentication and integrations."
                            ) {
                                NoirSelect(
                                    options: [
                                        (.automatic, "On demand"),
                                        (.always, "Always on"),
                                        (.off, "Off")
                                    ],
                                    selection: Binding(
                                        get: { appState.backendMode },
                                        set: { appState.backendMode = $0 }
                                    ),
                                    width: 132
                                )
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Spoken replies",
                                sub: "Read confirmations aloud."
                            ) {
                                NoirSwitch(isOn: $appState.voiceResponseEnabled)
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Hands-free mode",
                                sub: "Follow-ups after the wake word."
                            ) {
                                NoirSwitch(isOn: handsFreeBinding, disabled: handsFreeDisabled)
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Follow-up window",
                                sub: "Seconds after each command."
                            ) {
                                NoirSelect(
                                    options: (1...10).map { ($0, "\($0) s") },
                                    selection: $appState.sessionTimeoutSeconds,
                                    width: 90
                                )
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Start at login",
                                sub: "Open Jarvis when you sign in."
                            ) {
                                NoirSwitch(
                                    isOn: Binding(
                                        get: { launchAtLogin.isEnabled },
                                        set: { launchAtLogin.setEnabled($0) }
                                    )
                                )
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Memory limit",
                                sub: "Quit if the selected limit is exceeded."
                            ) {
                                NoirSelect(
                                    options: [
                                        (0, "Off"), (2, "2 GB"), (4, "4 GB"),
                                        (6, "6 GB"), (8, "8 GB")
                                    ],
                                    selection: $appState.memoryLimitGB,
                                    width: 80
                                )
                            }
                            NoirDivider()
                            NoirSettingRow(
                                title: "Dictation diagnostics",
                                sub: "Development logs for raw input and timings."
                            ) {
                                NoirSwitch(isOn: $appState.dictationDevLogEnabled)
                            }
                        }
                    }

                    if launchAtLogin.requiresApproval {
                        HStack(alignment: .top, spacing: 8) {
                            Text("Start at login needs approval under Login Items.")
                                .obsidianFont(size: 11)
                                .foregroundStyle(NoirPalette.orange)
                            Spacer(minLength: 8)
                            Button("Open Login Items") {
                                launchAtLogin.openLoginItemsSettings()
                            }
                            .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                        }
                        .padding(.top, 12)
                    }

                    if let error = launchAtLogin.errorText {
                        Text(error)
                            .obsidianFont(size: 10)
                            .foregroundStyle(NoirPalette.red)
                            .padding(.top, 12)
                    }

                    Text(noteText)
                        .obsidianFont(size: 11)
                        .lineSpacing(4)
                        .foregroundStyle(NoirPalette.muted)
                        .padding(.top, 15)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(NoirButtonStyle(intent: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .overlay(alignment: .top) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }
        }
        .frame(width: 540, height: 660)
        .background(GlassPanelBackground())
        .preferredColorScheme(.dark)
    }

    private var handsFreeDisabled: Bool {
        !appState.canUseVoiceMode && !appState.voiceModeEnabled
    }

    private var handsFreeBinding: Binding<Bool> {
        Binding(
            get: { appState.voiceModeEnabled },
            set: { newValue in
                if newValue {
                    guard appState.canUseVoiceMode else { return }
                    appState.voiceModeEnabled = true
                } else {
                    appState.voiceModeEnabled = false
                }
            }
        )
    }

    private var noteText: String {
        if appState.backendMode == .off
            && (appState.actionPillRequiresVerify || appState.voiceModeRequiresVerify) {
            return "Verification requires the backend helper. Enable it or turn off verification for the relevant mode."
        }
        return "These settings are stored locally on this Mac."
    }
}
