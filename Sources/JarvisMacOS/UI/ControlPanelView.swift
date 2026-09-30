import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var appState: AppState
    @State private var isAutomationModalOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    micControlSection

                    VoiceAuthCard(
                        status: appState.voiceVerificationStatus,
                        similarity: appState.lastVoiceSimilarity,
                        samplesCount: appState.backendEnrollmentSampleCount,
                        samplesTarget: appState.voiceEnrollmentSampleTarget
                    )

                    EnrollmentView(appState: appState)

                    StatsView(dbManager: appState.dbManager)

                    displaySection

                    automationRow

                    connectorsSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }

            manualInputSection
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
        }
        .frame(width: 300)
        .background(JarvisColor.canvas)
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(JarvisColor.hairline),
            alignment: .trailing
        )
        .sheet(isPresented: $isAutomationModalOpen) {
            AutomationManagerView(appState: appState, isModalOpen: $isAutomationModalOpen)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Jarvis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(JarvisColor.textPrimary)
            Text("Voice assistant")
                .font(JarvisType.caption)
                .foregroundStyle(JarvisColor.textTertiary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Microphone

    private var micControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Microphone")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(JarvisType.caption)
                        .foregroundStyle(JarvisColor.textSecondary)
                    Spacer()
                    Text(String(format: "%.1f dB", appState.audioLevelDB))
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(JarvisColor.textSecondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(JarvisColor.surfaceRaised)
                            .frame(height: 4)
                        Capsule()
                            .fill(JarvisColor.accent)
                            .frame(width: geo.size.width * max(0.02, appState.audioLevelNormalized), height: 4)
                            .animation(.easeOut(duration: 0.06), value: appState.audioLevelNormalized)
                    }
                }
                .frame(height: 4)
            }

            HStack {
                Text("Voice session")
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textSecondary)
                Spacer()
                if appState.voiceSessionState == .active {
                    let secondsLeft = max(0, Int((appState.sessionExpiresAt?.timeIntervalSinceNow ?? 0).rounded()))
                    Text("Active · \(secondsLeft)s")
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(JarvisColor.ok)
                } else {
                    Text("Idle")
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(JarvisColor.textTertiary)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await appState.startMicrophone() }
                } label: {
                    Label("Start", systemImage: "mic.fill")
                }
                .disabled(appState.micActive)
                .buttonStyle(JarvisButtonStyle(color: JarvisColor.ok, compact: true))

                Button {
                    appState.stopMicrophone()
                } label: {
                    Label("Stop", systemImage: "mic.slash.fill")
                }
                .disabled(!appState.micActive)
                .buttonStyle(JarvisButtonStyle(color: JarvisColor.danger, compact: true))
            }

            Button {
                appState.toggleVoiceMode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.voiceModeEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 14))
                    Text(appState.voiceModeEnabled ? "Voice mode: on" : "Voice mode: off")
                    Spacer()
                }
            }
            .disabled(!appState.voiceProfileReady)
            .buttonStyle(JarvisButtonStyle(
                color: appState.voiceModeEnabled ? JarvisColor.accent : JarvisColor.textTertiary,
                compact: true
            ))

            Button {
                appState.actionPillRequiresVerify.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.actionPillRequiresVerify ? "lock.fill" : "bolt.fill")
                        .font(.system(size: 13))
                    Text(appState.actionPillRequiresVerify ? "⌘⇧A verify: on" : "⌘⇧A verify: off")
                    Spacer()
                }
            }
            .buttonStyle(JarvisButtonStyle(
                color: appState.actionPillRequiresVerify ? JarvisColor.accent : JarvisColor.textTertiary,
                compact: true
            ))
            .help("⌘⇧A action pill: verify voiceprint before running (ON), or run immediately on hotkey (OFF)")

            Button {
                appState.voiceResponseEnabled.toggle()
                if !appState.voiceResponseEnabled {
                    ResponseEngine.shared.stopSpeaking()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.voiceResponseEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 13))
                    Text(appState.voiceResponseEnabled ? "Voice response: on" : "Voice response: off")
                    Spacer()
                    if ResponseEngine.shared.isSpeaking {
                        Circle()
                            .fill(JarvisColor.accent)
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .buttonStyle(JarvisButtonStyle(
                color: appState.voiceResponseEnabled ? JarvisColor.accent : JarvisColor.textTertiary,
                compact: true
            ))

            if !ResponseEngine.shared.lastResponse.isEmpty {
                Text(ResponseEngine.shared.lastResponse)
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(JarvisColor.surface)
                    )
            }
        }
    }

    // MARK: - Display (brightness + contrast)

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionLabel("Display")

                Spacer()

                Button {
                    appState.refreshBrightness()
                    appState.refreshContrast()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: true))
                .help("Re-read the exact brightness/contrast from the display")
            }

            levelRow(
                label: "Brightness",
                value: appState.currentBrightness,
                minus: { appState.decreaseBrightnessUI() },
                plus: { appState.increaseBrightnessUI() }
            )

            levelRow(
                label: "Contrast",
                value: appState.currentContrast,
                minus: { appState.decreaseContrastUI() },
                plus: { appState.increaseContrastUI() }
            )

            Text("Built-in Retina has no contrast control — external monitors only.")
                .font(JarvisType.micro)
                .foregroundStyle(JarvisColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func levelRow(label: String, value: Int,
                          minus: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(JarvisType.caption)
                .foregroundStyle(JarvisColor.textSecondary)
                .frame(width: 64, alignment: .leading)

            Button(action: minus) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: true))

            Text("\(value)%")
                .font(JarvisType.data)
                .foregroundStyle(JarvisColor.textPrimary)
                .frame(maxWidth: .infinity)

            Button(action: plus) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: true))
        }
    }

    // MARK: - Manual command

    private var manualInputSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                TextField("Type a command…", text: $appState.commandInput)
                    .font(JarvisType.body)
                    .textFieldStyle(.plain)
                    .foregroundStyle(JarvisColor.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .onSubmit { appState.executeTypedCommand() }

                Button {
                    appState.executeTypedCommand()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(JarvisColor.accent.opacity(appState.commandInput.isEmpty ? 0.3 : 0.9))
                }
                .buttonStyle(.plain)
                .disabled(appState.commandInput.isEmpty)
                .padding(.trailing, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                    .fill(JarvisColor.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JarvisRadius.sm, style: .continuous)
                    .strokeBorder(JarvisColor.hairline, lineWidth: 1)
            )

            Text("⌘⇧D dictates · ⌘⇧A runs commands")
                .font(JarvisType.micro)
                .foregroundStyle(JarvisColor.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Automations

    private var automationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Automations")

            Button {
                isAutomationModalOpen = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Manage")
                    Spacer()
                    Text("\(appState.automations.count)")
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(JarvisColor.textSecondary)
                }
            }
            .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: true))
        }
    }

    // MARK: - Connectors

    private var connectorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Connectors")
            ConnectorsView(appState: appState)
        }
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(JarvisType.title)
            .foregroundStyle(JarvisColor.textPrimary)
    }
}
