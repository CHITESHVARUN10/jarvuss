import SwiftUI

/// Center stage from the mock: top pills, greeting, orb, transcript, composer, logbar.
struct StageView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var responseEngine = ResponseEngine.shared
    @FocusState private var composerFocused: Bool
    /// Mock `@media (max-width:1180px)`: tighter stage gutters on narrow windows.
    var compact: Bool = false

    private var stageGutter: CGFloat { compact ? 26 : 40 }

    var body: some View {
        VStack(spacing: 0) {
            stageTop

            // Mock `.stage-main`: centered in the space left above the logbar.
            GeometryReader { proxy in
                ScrollView(showsIndicators: false) {
                    stageMain
                        .padding(.horizontal, stageGutter)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height, alignment: .center)
                }
            }

            EventLogDrawer(appState: appState)
        }
        .background(JColor.base)
    }

    /// Mock `.stage-main`: greeting → orb → transcript → reply → composer, gap 30.
    private var stageMain: some View {
        VStack(spacing: 30) {
            greeting

            MicOrbView(
                assistantState: appState.assistantState,
                audioLevel: appState.audioLevelNormalized,
                micActive: appState.micActive
            ) {
                if appState.micActive {
                    appState.stopMicrophone()
                } else {
                    Task { await appState.startMicrophone() }
                }
            }

            TranscriptView(
                lastSpeech: appState.lastRecognizedSpeech,
                currentCommand: appState.currentCommand,
                audioLevel: appState.audioLevelNormalized,
                state: appState.assistantState
            )
            .frame(maxWidth: 520)

            if !responseEngine.lastResponse.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(JColor.accent)
                        .padding(.top, 2)
                    Text(responseEngine.lastResponse)
                        .font(.system(size: 12.5))
                        .foregroundStyle(JColor.ink2)
                        .lineLimit(4)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .frame(maxWidth: 520, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                        .fill(JColor.raised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: JRadius.md, style: .continuous)
                        .strokeBorder(JColor.line, lineWidth: 1)
                )
            }

            composer
        }
    }

    // MARK: - Top pills

    private var stageTop: some View {
        HStack(spacing: 10) {
            statePill

            Spacer()

            verifyPill
            backendPill
        }
        .padding(.horizontal, 22)
        .frame(height: 56)
    }

    /// Mock `.pill`: state pill goes live when the mic is on.
    private var statePill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(stateDotColor)
                .frame(width: 5, height: 5)
            Text(stateText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(appState.micActive ? JColor.ink : JColor.ink2)
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(
            Capsule(style: .continuous)
                .fill(JColor.inset)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(appState.micActive ? JColor.lineStrong : JColor.line, lineWidth: 1)
        )
    }

    private var verifyPill: some View {
        Button {
            appState.actionPillRequiresVerify.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "shield")
                    .font(.system(size: 11))
                Text(appState.actionPillRequiresVerify ? "Verify on" : "Verify off")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(JColor.ink3)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(JGhostPillStyle())
        .help("⌘O — ⌘⇧A action pill: verify the voiceprint before running (ON), or run immediately on hotkey (OFF)")
    }

    private var backendPill: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(appState.backendStartupError == nil ? JColor.ok : JColor.danger)
                .frame(width: 5, height: 5)
            Text(appState.backendStatus)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(appState.backendStartupError == nil ? JColor.ink2 : JColor.danger)
        }
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(
            Capsule(style: .continuous)
                .fill(JColor.inset)
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(JColor.line, lineWidth: 1)
        )
    }

    private var stateText: String {
        if appState.micActive && appState.voiceSessionState == .active
            && appState.assistantState == .listening {
            return "Follow-up active"
        }
        switch appState.assistantState {
        case .idle:       return "Idle"
        case .listening:  return "Listening"
        case .recording:  return "Recording"
        case .processing: return "Thinking"
        case .executing:  return "Working"
        }
    }

    private var stateDotColor: Color {
        guard appState.micActive else { return JColor.ink4 }
        switch appState.assistantState {
        case .idle:       return JColor.ink4
        case .listening:  return JColor.ok
        case .recording:  return JColor.danger
        case .processing: return JColor.warn
        case .executing:  return JColor.ok
        }
    }

    // MARK: - Greeting

    private var greeting: some View {
        Text(greetingText)
            .font(JType.display)
            .foregroundStyle(JColor.ink)
            .multilineTextAlignment(.center)
            .animation(.easeOut(duration: 0.3), value: appState.assistantState)
    }

    private var greetingText: String {
        if !appState.micActive { return "Tap the orb to begin" }
        switch appState.assistantState {
        case .idle:       return "Tap the orb to begin"
        case .listening:  return "How can I help, Sir?"
        case .recording:  return "Listening…"
        case .processing: return "Let me think…"
        case .executing:  return "On it."
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                TextField("Type a command…", text: $appState.commandInput)
                    .font(.system(size: 13, weight: .regular))
                    .textFieldStyle(.plain)
                    .foregroundStyle(JColor.ink)
                    .focused($composerFocused)
                    .onSubmit { appState.executeTypedCommand() }

                Button {
                    appState.executeTypedCommand()
                } label: {
                    ZStack {
                        Circle()
                            .fill(JColor.accent)
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color(red: 0.039, green: 0.039, blue: 0.071))
                    }
                    .opacity(appState.commandInput.isEmpty ? 0.2 : 1.0)
                    .scaleEffect(appState.commandInput.isEmpty ? 1.0 : 1.02)
                }
                .buttonStyle(.plain)
                .disabled(appState.commandInput.isEmpty)
            }
            // Mock `.composer`: 7pt inset, 16pt leading, radius-full.
            .padding(.leading, 16)
            .padding(.vertical, 7)
            .padding(.trailing, 7)
            .frame(maxWidth: 520)
            .background(
                Capsule(style: .continuous)
                    .fill(JColor.raised)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(composerFocused ? JColor.accent.opacity(0.55) : JColor.line, lineWidth: 1)
            )
            .shadow(color: composerFocused ? JColor.accentSoft : .clear, radius: 3)
            .animation(.easeOut(duration: 0.22), value: composerFocused)

            HStack(spacing: 7) {
                kbd("⌘⇧D")
                hintText("dictate")
                Text("·")
                    .foregroundStyle(JColor.ink4.opacity(0.4))
                kbd("⌘O")
                hintText("toggle verify")
                Text("·")
                    .foregroundStyle(JColor.ink4.opacity(0.4))
                kbd("⏎")
                hintText("run")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(JColor.ink4)
    }

    private func kbd(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(JColor.ink3)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(JColor.inset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(JColor.line, lineWidth: 1)
            )
    }
}

/// Mock `.pill.ghost`: transparent until hovered.
private struct JGhostPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule(style: .continuous)
                    .fill(configuration.isPressed ? JColor.inset : Color.clear)
            )
    }
}
