import SwiftUI
import AppKit

// MARK: - Inspector

struct NoirInspector: View {
    @ObservedObject var appState: AppState
    @ObservedObject var feed: AssistantFeed

    let onOpenPreferences: () -> Void
    let onOpenVoice: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                Text("In the background")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NoirPalette.text)
                Text("A few things, just as you like them.")
                    .font(.system(size: 10))
                    .foregroundStyle(NoirPalette.muted)
                    .padding(.top, 7)

                sessionSection
                identitySection
                recentSection

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock")
                        .font(.system(size: 11))
                        .padding(.top, 2)
                    Text("Speech is processed on your Mac. Connected services handle their own requests.")
                        .font(.system(size: 10))
                        .lineSpacing(4)
                }
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 25)
            }
            .padding(.horizontal, 23)
            .padding(.top, 29)
            .padding(.bottom, 28)
        }
        .frame(width: 258)
        .frame(maxHeight: .infinity)
        .background(NoirPalette.footer.opacity(0.62))
        .overlay(alignment: .leading) {
            Rectangle().fill(NoirPalette.line).frame(width: 1)
        }
    }

    // MARK: Session

    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("This session")

            inspectorSwitch(
                icon: "shield",
                label: "Verify commands",
                isOn: $appState.actionPillRequiresVerify
            )

            inspectorSwitch(
                icon: "mic",
                label: "Hands-free mode",
                isOn: handsFreeBinding,
                disabled: !appState.canUseVoiceMode && !appState.voiceModeEnabled
            )

            inspectorSwitch(
                icon: "bubble.left",
                label: "Spoken replies",
                isOn: $appState.voiceResponseEnabled
            )

            Text(appState.voiceModeEnabled
                 ? "Say “Jarvis” to begin. Follow-ups stay open for \(appState.sessionTimeoutSeconds) seconds."
                 : "Start a session with the orb, or type a command below.")
                .font(.system(size: 10))
                .lineSpacing(4)
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 12)

            inspectorLink("Assistant preferences", action: onOpenPreferences)
        }
        .padding(.top, 24)
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
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

    // MARK: Identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Voice identity")

            HStack(spacing: 9) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundStyle(NoirPalette.muted)
                Text(appState.voiceProfileReady ? "Your voice is recognized" : "Voice profile needs enrollment")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.secondary)
            }
            .padding(.bottom, 12)

            HStack(spacing: 10) {
                NoirTag(
                    text: appState.voiceProfileReady ? "Profile ready" : "Enroll your voice",
                    kind: appState.voiceProfileReady ? .green : .amber
                )
                Text("\(appState.backendEnrollmentSampleCount) samples")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(NoirPalette.muted)
                Spacer(minLength: 0)
            }

            inspectorLink("Manage voice profile", action: onOpenVoice)
        }
        .padding(.top, 24)
        .padding(.bottom, 24)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Recent commands")

            let commands = recentCommands
            if commands.isEmpty {
                Text("No commands yet — press ⌘⇧D and talk.")
                    .font(.system(size: 10))
                    .foregroundStyle(NoirPalette.muted)
                    .padding(.top, 2)
            } else {
                ForEach(Array(commands.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: entry.live ? "checkmark" : "clock")
                            .font(.system(size: 11))
                            .foregroundStyle(NoirPalette.muted)
                            .frame(width: 13)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(entry.text)
                                .font(.system(size: 11))
                                .foregroundStyle(NoirPalette.secondary)
                                .lineLimit(2)
                            Text(entry.live ? "Just now · local" : "Recent · local")
                                .font(.system(size: 9))
                                .foregroundStyle(NoirPalette.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                }
            }
        }
        .padding(.top, 24)
    }

    private struct RecentEntry {
        let text: String
        let live: Bool
    }

    private var recentCommands: [RecentEntry] {
        let live = feed.items
            .filter { $0.role == .user }
            .suffix(3)
            .reversed()
            .map { RecentEntry(text: $0.text, live: true) }
        if !live.isEmpty { return Array(live) }
        return appState.recentCommands.prefix(3).map { RecentEntry(text: $0, live: false) }
    }

    // MARK: Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .medium))
            .tracking(1.3)
            .foregroundStyle(NoirPalette.muted)
            .padding(.bottom, 16)
    }

    private func inspectorSwitch(
        icon: String,
        label: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(NoirPalette.muted)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.secondary)
            Spacer(minLength: 8)
            NoirSwitch(isOn: isOn, disabled: disabled)
        }
        .padding(.bottom, 15)
    }

    private func inspectorLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
            }
            .font(.system(size: 10))
            .foregroundStyle(NoirPalette.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
    }
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
                                    .font(.system(size: 12, design: .monospaced))
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
                                .font(.system(size: 11))
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
                            .font(.system(size: 10))
                            .foregroundStyle(NoirPalette.red)
                            .padding(.top, 12)
                    }

                    Text(noteText)
                        .font(.system(size: 11))
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
        .background(NoirPalette.base)
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
