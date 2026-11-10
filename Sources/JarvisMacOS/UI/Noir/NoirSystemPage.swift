import SwiftUI
import AppKit

struct NoirSystemPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var recovery = DisplayRecovery.shared
    @StateObject private var launchAtLogin = LaunchAtLoginController()
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.obsidianWindowWidth) private var windowWidth
    @State private var assistantPreferencesOpen = false
    @State private var brightness: Double = 65
    @State private var contrast: Double = 50
    @State private var editingBrightness = false
    @State private var editingContrast = false

    var body: some View {
        NoirPage(eyebrow: "Preferences", title: "General",
                 sub: "The essentials up front. Everything else, when you need it.") {
            let columns = windowWidth >= 1500
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            columns {
                everyday.frame(maxWidth: .infinity, alignment: .topLeading)
                moreSettings.frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: $assistantPreferencesOpen) {
            AssistantPreferencesSheet(appState: appState).environmentObject(toasts).presentationBackground(.clear)
        }
        .onAppear { syncDisplayValues(); launchAtLogin.refresh() }
        .onChange(of: appState.currentBrightness) { _, value in if !editingBrightness { brightness = Double(value) } }
        .onChange(of: appState.currentContrast) { _, value in if !editingContrast { contrast = Double(value) } }
    }

    private var everyday: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Everyday", minHeight: 30)
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "Start at login", sub: "Ready when you sign in.") {
                        NoirSwitch(isOn: Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) }))
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Assistant behavior", sub: "Responses, session behavior, and memory.") {
                        Button("Configure") { assistantPreferencesOpen = true }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    }
                }
            }
            if launchAtLogin.requiresApproval {
                Button("Allow Jarvis in Login Items…") { launchAtLogin.openLoginItemsSettings() }
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true)).padding(.top, 12)
            }
            if let error = launchAtLogin.errorText {
                Text(error).obsidianFont(size: 11).foregroundStyle(NoirPalette.red).padding(.top, 10)
            }
            HStack(alignment: .top, spacing: 16) {
                Text("Speech and dictation have a home of their own.").obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                Spacer(minLength: 0)
                Button("Voice & speech ↗") {
                    appState.voiceSettingsTab = .dictation
                    appState.activeSection = .voice
                }.buttonStyle(.plain).obsidianFont(size: 11).foregroundStyle(NoirPalette.accent)
            }
            .padding(.vertical, 18)
            ObsidianModelUpdates(model: IntentModelSetup.shared)
        }
    }

    private var moreSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "More settings", minHeight: 30)
            NoirCard {
                VStack(spacing: 0) {
                    settingsGroup(.display, title: "Display & sound", sub: "Brightness, volume, and display recovery.", icon: "display") {
                        displaySettings
                        NoirSoundSection()
                        NoirSectionHeading(title: "Display safety")
                        recoverySettings
                    }
                    NoirDivider()
                    settingsGroup(.projects, title: "Files & projects", sub: "Project roots, aliases, and search.", icon: "folder") {
                        NoirProjectPreferences()
                        NoirFileSearchPreferences()
                    }
                    NoirDivider()
                    settingsGroup(.services, title: "Local services", sub: "Ollama, native helper, and storage.", icon: "server.rack") {
                        ObsidianCoreServices(appState: appState)
                    }
                    NoirDivider()
                    settingsGroup(.advanced, title: "Advanced & safeguards", sub: "Command limits, review, and diagnostics.", icon: "lock") {
                        NoirSectionHeading(title: "Command safeguards")
                        safeguardsSettings
                        CommandFeedbackView(initialCommand: appState.lastCommandForReview, requestID: appState.lastCommandTraceID)
                    }
                }
            }
        }
    }

    private func settingsGroup<Content: View>(_ group: GeneralSettingsGroup, title: String, sub: String, icon: String,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Button {
                appState.expandedSettingsGroup = appState.expandedSettingsGroup == group ? nil : group
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: icon).obsidianFont(size: 15).foregroundStyle(NoirPalette.muted).frame(width: 20)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).obsidianFont(size: 12, weight: .medium).foregroundStyle(NoirPalette.text)
                        Text(sub).obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").obsidianFont(size: 10).foregroundStyle(NoirPalette.muted)
                        .rotationEffect(.degrees(appState.expandedSettingsGroup == group ? 90 : 0))
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(title)
                .accessibilityValue(appState.expandedSettingsGroup == group ? "Expanded" : "Collapsed")
            if appState.expandedSettingsGroup == group {
                VStack(alignment: .leading, spacing: 0) { content() }.padding(.horizontal, 18).padding(.bottom, 18)
            }
        }
    }

    private var displaySettings: some View {
        NoirCard {
            VStack(spacing: 0) {
                NoirSettingRow(title: "Brightness") {
                    displayControl(value: $brightness, editing: $editingBrightness) {
                        appState.setBrightnessUI(Int(brightness.rounded()))
                    }
                }
                NoirDivider()
                NoirSettingRow(title: "Contrast", sub: "External displays only.") {
                    displayControl(value: $contrast, editing: $editingContrast) {
                        appState.setContrastUI(Int(contrast.rounded()))
                    }
                }
                NoirDivider()
                NoirSettingRow(title: "Display profile") {
                    Text(appState.displayProfileName)
                        .obsidianFont(size: 11, design: .monospaced)
                        .foregroundStyle(NoirPalette.secondary)
                }
            }
        }
    }
    private var safeguardsSettings: some View {
        NoirCard {
            VStack(spacing: 0) {
                NoirSettingRow(title: "Destructive actions", sub: "Always blocked.") {
                    NoirTag(text: "Locked", kind: .red, icon: "lock")
                }
                NoirDivider()
                NoirSettingRow(title: "Privileged commands", sub: "sudo is never permitted.") {
                    NoirTag(text: "Locked", kind: .red, icon: "lock")
                }
                NoirDivider()
                NoirSettingRow(title: "Package installs", sub: "Installation is never executed.") {
                    NoirTag(text: "Preview only", kind: .amber)
                }
            }
        }
    }
    private var recoverySettings: some View {
        NoirCard(padded: true) {
            Text("Jarvis keeps brightness at 10% or higher, contrast at 20% or higher, and software dimming above zero.")
                .obsidianFont(size: 12)
                .foregroundStyle(NoirPalette.secondary)
            Text("If the screen becomes unreadable, press ⌘⇧R. Or press ⌘⇧A, say ‘Restore my display’, then press ⌘⇧A again to finish. Recovery bypasses verification only for this exact, safe action.")
                .obsidianFont(size: 11)
                .foregroundStyle(NoirPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text("Requests 60% brightness, 50% external contrast and normal software brightness using macOS and supported display controls. BetterDisplay is optional. If you use it, keep its notification integration enabled to release its dimming; software image adjustments are suspended until you re-enable them in BetterDisplay. Jarvis must be running.")
                .obsidianFont(size: 11)
                .foregroundStyle(NoirPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Button(recovery.isRestoring ? "Restoring…" : "Restore display visibility") { recovery.restore() }
                .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                .disabled(recovery.isRestoring)
                .padding(.top, 12)
            if !recovery.shortcutRegistered {
                Text("⌘⇧R is unavailable. Another app may already use it; the button and voice phrase still work.")
                    .obsidianFont(size: 11).foregroundStyle(NoirPalette.orange).padding(.top, 8)
            }
            if !recovery.status.isEmpty {
                Text(recovery.status).obsidianFont(size: 11).foregroundStyle(NoirPalette.secondary).padding(.top, 8)
            }
        }
    }
    private func displayControl(
        value: Binding<Double>,
        editing: Binding<Bool>,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            NoirSlider(
                value: value,
                onEditingChanged: { editing.wrappedValue = $0 },
                onCommit: onCommit
            )
            .frame(width: 118)

            Text("\(Int(value.wrappedValue.rounded()))%")
                .obsidianFont(size: 11, design: .monospaced)
                .foregroundStyle(NoirPalette.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(width: 170)
    }

    private func syncDisplayValues() {
        brightness = Double(appState.currentBrightness)
        contrast = Double(appState.currentContrast)
    }

    private struct NoirSlider: View {
        @Binding var value: Double
        let onEditingChanged: (Bool) -> Void
        let onCommit: () -> Void

        var body: some View {
            GeometryReader { proxy in
                let fraction = min(max(value / 100, 0), 1)
                let width = proxy.size.width

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)
                    Capsule(style: .continuous)
                        .fill(NoirPalette.accent)
                        .frame(width: max(0, width * fraction), height: 3)
                    Circle()
                        .fill(NoirPalette.text)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle().strokeBorder(NoirPalette.base.opacity(0.5), lineWidth: 1)
                        )
                        .offset(x: max(0, min(width - 13, width * fraction - 6.5)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            onEditingChanged(true)
                            let raw = min(max(drag.location.x / width, 0), 1)
                            value = (raw * 100).rounded()
                        }
                        .onEnded { _ in
                            onEditingChanged(false)
                            onCommit()
                        }
                )
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel("Slider")
            .accessibilityValue("\(Int(value.rounded())) percent")
        }
    }

}
