import SwiftUI

/// Assistant pane — Privacy, Behaviour, Recent.
struct AssistantPane: View {
    @ObservedObject var appState: AppState
    @StateObject private var launchAtLogin = LaunchAtLoginController()

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
            .onAppear { launchAtLogin.refresh() }
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            JLabel(text: "Privacy")

            JCard {
                JRow(title: "Verification — ⌘⇧A",
                     sub: "Gate pill commands on a voice match",
                     first: true) {
                    JSwitch(binding: $appState.actionPillRequiresVerify)
                }
                JRow(title: "Verification — live mode",
                     sub: appState.voiceModeRequiresVerify
                        ? "Wake word + voice match"
                        : "Wake word only (no voice match)") {
                    JSwitch(binding: $appState.voiceModeRequiresVerify)
                }
                JRow(title: "Threshold",
                     sub: "Similarity required to execute") {
                    Text(String(format: "%.2f", appState.voiceVerifyThreshold))
                        .font(JType.kv)
                        .foregroundStyle(JColor.ink2)
                }
            }
            .padding(.top, 9)

            JLabel(text: "Behaviour")
                .padding(.top, 22)

            JCard {
                JRow(title: "Backend",
                     sub: "Voice auth, Spotify and the learned intent router live in a Python helper",
                     first: true) {
                    Picker("", selection: $appState.backendMode) {
                        ForEach(BackendMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 118)
                }
                JRow(title: "Spoken replies",
                     sub: "Read confirmations aloud") {
                    JSwitch(binding: $appState.voiceResponseEnabled)
                }
                JRow(title: "Voice mode",
                     sub: appState.canUseVoiceMode
                        ? "Hands-free follow-ups"
                        : "Finish enrollment to unlock") {
                    JSwitch(binding: $appState.voiceModeEnabled)
                        .disabled(!appState.canUseVoiceMode && !appState.voiceModeEnabled)
                }
                JRow(title: "Follow-up window",
                     sub: "Stay armed after a command") {
                    Picker("", selection: $appState.sessionTimeoutSeconds) {
                        Text("1 s").tag(1)
                        Text("2 s").tag(2)
                        Text("3 s").tag(3)
                        Text("4 s").tag(4)
                        Text("5 s").tag(5)
                        Text("6 s").tag(6)
                        Text("7 s").tag(7)
                        Text("8 s").tag(8)
                        Text("9 s").tag(9)
                        Text("10 s").tag(10)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 78)
                }
                JRow(title: "Start at login",
                     sub: "Open Jarvis automatically when you log in") {
                    JSwitch(binding: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                }
                if launchAtLogin.requiresApproval {
                    JRow(title: "Approval needed",
                         sub: "Allow Jarvis under Login Items") {
                        Button("Open Settings") {
                            launchAtLogin.openLoginItemsSettings()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(JColor.accent)
                    }
                }
                JRow(title: "Memory limit",
                     sub: "Quit Jarvis if it ever exceeds this") {
                    Picker("", selection: $appState.memoryLimitGB) {
                        Text("Off").tag(0)
                        Text("2 GB").tag(2)
                        Text("4 GB").tag(4)
                        Text("6 GB").tag(6)
                        Text("8 GB").tag(8)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 78)
                }
                JRow(title: "Dictation diagnostics",
                     sub: "Log raw input + timings per dictation (dev)") {
                    JSwitch(binding: $appState.dictationDevLogEnabled)
                }
            }
            .padding(.top, 9)

            if appState.backendMode == .off && (appState.actionPillRequiresVerify || appState.voiceModeRequiresVerify) {
                Text("Verification requires the Python helper. Enable the backend or turn verification off for that mode.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(JColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }

            if let error = launchAtLogin.errorText {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(JColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 9)
            }

            JLabel(text: "Recent")
                .padding(.top, 22)

            JCard(flush: true) {
                if appState.recentCommands.isEmpty {
                    Text("No commands yet — press ⌘⇧D and talk.")
                        .font(.system(size: 12))
                        .foregroundStyle(JColor.ink4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 26)
                } else {
                    ForEach(Array(appState.recentCommands.enumerated()), id: \.offset) { idx, command in
                        HStack(spacing: 11) {
                            Text(command)
                                .font(JType.rowTitle)
                                .foregroundStyle(JColor.ink)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 11)
                        .overlay(alignment: .top) {
                            if idx > 0 {
                                Rectangle()
                                    .fill(JColor.line)
                                    .frame(height: 1)
                                    .padding(.horizontal, 15)
                            }
                        }
                    }
                }
            }
            .padding(.top, 9)
        }
    }
}
