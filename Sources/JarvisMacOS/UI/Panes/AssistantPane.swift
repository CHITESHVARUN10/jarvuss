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
                JRow(title: "Speaker verification",
                     sub: "Every command is gated on a voice match",
                     first: true) {
                    JSwitch(binding: $appState.actionPillRequiresVerify)
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
                JRow(title: "Spoken replies",
                     sub: "Read confirmations aloud",
                     first: true) {
                    JSwitch(binding: $appState.voiceResponseEnabled)
                }
                JRow(title: "Voice mode",
                     sub: appState.voiceProfileReady
                        ? "Hands-free follow-ups"
                        : "Finish enrollment to unlock") {
                    JSwitch(binding: $appState.voiceModeEnabled)
                        .disabled(!appState.voiceProfileReady)
                }
                JRow(title: "Follow-up window",
                     sub: "Stay armed after a command") {
                    Text("\(Int(appState.sessionTimeout))s")
                        .font(JType.kv)
                        .foregroundStyle(JColor.ink2)
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
            }
            .padding(.top, 9)

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
