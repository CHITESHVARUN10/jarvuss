import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var appState: AppState
    @State private var isAutomationModalOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 2) {
                Text("JARVIS")
                    .font(.system(size: 18, weight: .black, design: .default))
                    .tracking(4)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.70, green: 0.70, blue: 1.0), Color(red: 0.80, green: 0.50, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text("Neural Assistant v3.4")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.30))
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()
                .background(Color.white.opacity(0.06))

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {

                    // Mic controls
                    SectionCard(content: micControlSection)

                    Divider().background(Color.white.opacity(0.06))

                    // Voice Auth card
                    SectionCard(content: VoiceAuthCard(
                        status: appState.voiceVerificationStatus,
                        similarity: appState.lastVoiceSimilarity,
                        samplesCount: appState.backendEnrollmentSampleCount,
                        samplesTarget: appState.voiceEnrollmentSampleTarget
                    ))

                    Divider().background(Color.white.opacity(0.06))

                    // Enrollment
                    SectionCard(content: EnrollmentView(appState: appState))

                    Divider().background(Color.white.opacity(0.06))

                    // Usage stats (Wrapped)
                    StatsView(dbManager: appState.dbManager)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()

                    Divider().background(Color.white.opacity(0.06))

                    // Manual input
                    SectionCard(content: manualInputSection)

                    Divider().background(Color.white.opacity(0.06))

                    // Brightness box
                    SectionCard(content: brightnessBox)

                    Divider().background(Color.white.opacity(0.06))

                    // Contrast box
                    SectionCard(content: contrastBox)

                    Divider().background(Color.white.opacity(0.06))

                    // Automations (single row)
                    SectionCard(content: automationRow)

                    Divider().background(Color.white.opacity(0.06))

                    // Connectors (Spotify keys + authorize)
                    SectionCard(content: connectorsSection)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
        }
        .frame(width: 300)
        .background(
            ZStack {
                Color(red: 0.07, green: 0.07, blue: 0.10)
                Rectangle()
                    .fill(Color.white.opacity(0.03))
            }
        )
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundStyle(Color.white.opacity(0.06)),
            alignment: .trailing
        )
        .sheet(isPresented: $isAutomationModalOpen) {
            AutomationManagerView(appState: appState, isModalOpen: $isAutomationModalOpen)
        }
    }

    // MARK: - Mic controls section
    private var micControlSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("MICROPHONE", icon: "mic")

            // Audio level meter
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.35))
                    Spacer()
                    Text(String(format: "%.1f dB", appState.audioLevelDB))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.50))
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.white.opacity(0.07))
                            .frame(height: 5)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(levelGradient)
                            .frame(width: geo.size.width * max(0.02, appState.audioLevelNormalized), height: 5)
                            .animation(.easeOut(duration: 0.06), value: appState.audioLevelNormalized)
                    }
                }
                .frame(height: 5)
            }

            // Voice Session state indicator
            HStack {
                Text("Voice Session")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.35))
                Spacer()
                if appState.voiceSessionState == .active {
                    let secondsLeft = max(0, Int((appState.sessionExpiresAt?.timeIntervalSinceNow ?? 0).rounded()))
                    Text("ACTIVE (\(secondsLeft)s)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 1.0))
                } else {
                    Text("IDLE")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.40))
                }
            }

            // Mic start/stop
            HStack(spacing: 8) {
                Button {
                    Task { await appState.startMicrophone() }
                } label: {
                    Label("Start", systemImage: "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(appState.micActive)
                .buttonStyle(JarvisButtonStyle(color: Color(red: 0.35, green: 0.85, blue: 0.65), compact: true))

                Button {
                    appState.stopMicrophone()
                } label: {
                    Label("Stop", systemImage: "mic.slash.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .disabled(!appState.micActive)
                .buttonStyle(JarvisButtonStyle(color: Color(red: 0.85, green: 0.35, blue: 0.45), compact: true))
            }

            // Voice mode toggle
            Button {
                appState.toggleVoiceMode()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.voiceModeEnabled ? "waveform.circle.fill" : "waveform.circle")
                        .font(.system(size: 14))
                    Text(appState.voiceModeEnabled ? "Voice Mode: ON" : "Voice Mode: OFF")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
            }
            .disabled(!appState.voiceProfileReady)
            .buttonStyle(JarvisButtonStyle(
                color: appState.voiceModeEnabled
                    ? Color(red: 0.55, green: 0.55, blue: 1.0)
                    : Color.white.opacity(0.35),
                compact: true
            ))

            // Action pill (⌘⇧A) verify toggle — flips without code changes
            Button {
                appState.actionPillRequiresVerify.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.actionPillRequiresVerify ? "lock.fill" : "bolt.fill")
                        .font(.system(size: 13))
                    Text(appState.actionPillRequiresVerify ? "⌘⇧A Verify: ON" : "⌘⇧A Verify: OFF")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
            }
            .buttonStyle(JarvisButtonStyle(
                color: appState.actionPillRequiresVerify
                    ? Color(red: 0.55, green: 0.55, blue: 1.0)
                    : Color.white.opacity(0.35),
                compact: true
            ))
            .help("⌘⇧A action pill: verify voiceprint before running (ON), or run immediately on hotkey (OFF)")

            // Voice response toggle
            Button {
                appState.voiceResponseEnabled.toggle()
                if !appState.voiceResponseEnabled {
                    ResponseEngine.shared.stopSpeaking()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.voiceResponseEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(appState.voiceResponseEnabled
                            ? Color(red: 0.55, green: 0.55, blue: 1.0)
                            : Color.white.opacity(0.35))
                    Text(appState.voiceResponseEnabled ? "Voice Response: ON" : "Voice Response: OFF")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    if ResponseEngine.shared.isSpeaking {
                        Circle()
                            .fill(Color(red: 0.55, green: 0.55, blue: 1.0))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .buttonStyle(JarvisButtonStyle(
                color: appState.voiceResponseEnabled
                    ? Color(red: 0.55, green: 0.55, blue: 1.0)
                    : Color.white.opacity(0.35),
                compact: true
            ))

            // Last spoken response
            if !ResponseEngine.shared.lastResponse.isEmpty {
                Text(ResponseEngine.shared.lastResponse)
                    .font(.system(size: 10, design: .default))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    // MARK: - Manual input section
    private var manualInputSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("MANUAL COMMAND", icon: "keyboard")

            HStack(spacing: 0) {
                TextField("Type a command...", text: $appState.commandInput)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .onSubmit { appState.executeTypedCommand() }

                Button {
                    appState.executeTypedCommand()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 1.0).opacity(appState.commandInput.isEmpty ? 0.3 : 0.9))
                }
                .buttonStyle(.plain)
                .disabled(appState.commandInput.isEmpty)
                .padding(.trailing, 8)
            }
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )

            Text("⌘⇧D dictates · ⌘⇧A runs commands (no wake word). Voice mode needs \"Jarvis <verb> <target>\"")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.22))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Brightness box (exact value +10 / -10)
    private var brightnessBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("BRIGHTNESS", icon: "sun.max.fill")

            HStack {
                Text("Level")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("\(appState.currentBrightness)%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            HStack(spacing: 8) {
                Button(action: { appState.decreaseBrightnessUI() }) {
                    Text("-10")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(JarvisButtonStyle(color: Color.white.opacity(0.5), compact: true))

                Button(action: { appState.increaseBrightnessUI() }) {
                    Text("+10")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(JarvisButtonStyle(color: Color.white.opacity(0.5), compact: true))
            }
        }
    }

    // MARK: - Contrast box (exact value +10 / -10, external monitors via DDC/CI)
    private var contrastBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("CONTRAST", icon: "circle.lefthalf.filled")

            HStack {
                Text("Level")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Text("\(appState.currentContrast)%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
            }

            HStack(spacing: 8) {
                Button(action: { appState.decreaseContrastUI() }) {
                    Text("-10")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(JarvisButtonStyle(color: Color.white.opacity(0.5), compact: true))

                Button(action: { appState.increaseContrastUI() }) {
                    Text("+10")
                        .font(.system(size: 11, weight: .bold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(JarvisButtonStyle(color: Color.white.opacity(0.5), compact: true))
            }

            Text("Built-in Retina has no contrast control — external monitors only.")
                .font(.system(size: 9))
                .foregroundStyle(Color.white.opacity(0.25))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Automations (single minimal row, modal holds the rest)
    private var automationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("AUTOMATIONS", icon: "bolt.fill")

            Button {
                isAutomationModalOpen = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                    Text("Manage")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(appState.automations.count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.70))
                }
            }
            .buttonStyle(JarvisButtonStyle(color: Color.white.opacity(0.5), compact: true))
        }
    }

    // MARK: - Connectors
    private var connectorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("CONNECTORS", icon: "link")
            ConnectorsView(appState: appState)
        }
    }

    // MARK: - Helpers

    // MARK: - Display brightness control section

    // MARK: - Combined brightness control section (GUI test only)

    // MARK: - Shared section card
    private struct SectionCard<Content: View>: View {
        let content: Content
        var body: some View {
            content
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.035))
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                    }
                )
        }
    }

    private func sectionCard<Content: View>(_ content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.035))
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
                }
            )
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.30))
            Text(text)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.white.opacity(0.30))
        }
    }

    private var levelGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.35, green: 0.85, blue: 0.65),
                Color(red: 0.55, green: 0.55, blue: 1.0),
                Color(red: 1.0, green: 0.38, blue: 0.55)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
