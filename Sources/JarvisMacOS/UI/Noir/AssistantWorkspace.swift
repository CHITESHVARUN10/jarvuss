import SwiftUI
import AppKit

// MARK: - Assistant page

struct AssistantWorkspace: View {
    @ObservedObject var appState: AppState
    @ObservedObject var feed: AssistantFeed
    @ObservedObject private var responseEngine = ResponseEngine.shared

    let onOpenPreferences: () -> Void

    @State private var lastAssistantResponse = ""

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 700

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    assistantMeta
                        .padding(.bottom, 4)

                    Group {
                        if feed.items.isEmpty {
                            VStack(spacing: 0) {
                                voiceStage(compact: compact)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .padding(.top, compact ? 4 : 12)
                                    .padding(.bottom, compact ? 10 : 16)

                                suggestions
                            }
                        } else {
                            conversation
                                .padding(.vertical, 18)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    composer
                        .padding(.top, compact ? 14 : 22)
                    shortcuts
                        .padding(.top, compact ? 9 : 13)
                }
                .padding(.top, compact ? 20 : 28)
                .padding(.horizontal, 35)
                .padding(.bottom, compact ? 14 : 24)
                .frame(maxWidth: 850, alignment: .top)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: appState.currentCommand) { _, command in
            noteUser(command)
        }
        .onChange(of: responseEngine.lastResponse) { _, response in
            guard !response.isEmpty, response != lastAssistantResponse else { return }
            lastAssistantResponse = response
            withAnimation(.easeOut(duration: 0.2)) {
                feed.addAssistant(response)
            }
        }
        .onAppear {
            lastAssistantResponse = responseEngine.lastResponse
        }
    }

    // MARK: Meta

    private var assistantMeta: some View {
        HStack(spacing: 8) {
            Text("YOUR PERSONAL WORKSPACE")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(NoirPalette.muted)

            Spacer(minLength: 8)

            HStack(spacing: 7) {
                Image(systemName: "shield")
                    .font(.system(size: 11))
                Text("Verification \(appState.actionPillRequiresVerify ? "on" : "off")")
                    .font(.system(size: 10))
            }
            .foregroundStyle(NoirPalette.muted)
        }
    }

    // MARK: Voice stage

    private func voiceStage(compact: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            NoirOrb(isListening: appState.isLiveListening) {
                toggleListening()
            }
            .frame(width: 206, height: 206)
            .scaleEffect(compact ? 0.74 : 1)
            .frame(width: compact ? 152 : 206, height: compact ? 152 : 206)
            .padding(.bottom, compact ? 12 : 24)

            Text(appState.isLiveListening ? "I’m listening." : "A little less effort.")
                .font(.system(size: compact ? 27 : 32, weight: .regular))
                .tracking(-1)
                .foregroundStyle(NoirPalette.text)
                .multilineTextAlignment(.center)

            Text(appState.isLiveListening
                 ? "Say “Jarvis” followed by a command.\nClick the orb again to pause."
                 : "Your voice. A quieter way to get things done.\nClick the orb and tell me what’s next.")
                .font(.system(size: 12))
                .lineSpacing(6)
                .multilineTextAlignment(.center)
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, compact ? 8 : 12)

            HStack(spacing: 7) {
                Circle()
                    .fill(appState.isLiveListening ? NoirPalette.accent : NoirPalette.muted)
                    .frame(width: 5, height: 5)
                Text(stateLine)
                    .font(.system(size: 10))
                    .tracking(0.3)
            }
            .foregroundStyle(appState.isLiveListening ? NoirPalette.accent : NoirPalette.secondary)
            .padding(.top, compact ? 12 : 20)

            Spacer(minLength: 4)
        }
        .frame(minHeight: compact ? 240 : 310)
    }

    private var stateLine: String {
        guard appState.isLiveListening else { return "Ready when you are" }
        switch appState.assistantState {
        case .idle:       return "Ready when you are"
        case .listening:  return "Listening · microphone live"
        case .recording:  return "Recording · microphone live"
        case .processing: return "Thinking on this Mac"
        case .executing:  return "Working on it"
        }
    }

    private func toggleListening() {
        if appState.isLiveListening {
            appState.stopMicrophone()
        } else {
            appState.noteManualMicStart()
            Task { await appState.startMicrophone() }
        }
    }

    // MARK: Suggestions

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A FEW THINGS TO TRY")
                .font(.system(size: 9, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(NoirPalette.muted)
                .padding(.bottom, 12)

            HStack(spacing: 10) {
                suggestion(icon: "square.grid.2x2", label: "Open an application", command: "open Safari")
                suggestion(icon: "music.note", label: "Set the soundtrack", command: "play my Deep Focus playlist")
                suggestion(icon: "clock", label: "Find your focus", command: "start a 25 minute timer")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestion(icon: String, label: String, command: String) -> some View {
        SuggestionCard(icon: icon, label: label) {
            appState.commandInput = command
            noteUser(command)
            appState.executeTypedCommand()
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 12) {
            ForEach(feed.items) { item in
                message(item)
            }

            HStack(spacing: 16) {
                Text("This conversation is a local record for this session.")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.muted)
                Spacer(minLength: 8)
                NoirIconButton(icon: "arrow.clockwise", help: "Return to start") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        feed.reset()
                    }
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func message(_ item: AssistantFeed.Item) -> some View {
        let isUser = item.role == .user
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !isUser {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.accent)
                }
                Text(isUser ? "You" : "Jarvis")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(NoirPalette.muted)
            }
            .padding(.bottom, 8)

            Text(item.text)
                .font(.system(size: 12))
                .lineSpacing(7)
                .foregroundStyle(NoirPalette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isUser {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .medium))
                    Text("Handled on this Mac")
                        .font(.system(size: 10))
                }
                .foregroundStyle(NoirPalette.green)
                .padding(.top, 10)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
        .frame(maxWidth: isUser ? 700 : 740, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isUser ? Color.white.opacity(0.024) : NoirPalette.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(isUser ? NoirPalette.line : NoirPalette.accent.opacity(0.11), lineWidth: 1)
        )
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }

    private func noteUser(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if feed.items.last?.role == .user && feed.items.last?.text == trimmed { return }
        withAnimation(.easeOut(duration: 0.2)) {
            feed.addUser(trimmed)
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 0) {
            TextField("Or type what you have in mind…", text: $appState.commandInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(NoirPalette.text)
                .padding(.horizontal, 2)
                .padding(.bottom, 14)
                .onSubmit(submitTyped)

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11))
                    Text("On-device intelligence")
                        .font(.system(size: 10))
                }
                .foregroundStyle(NoirPalette.muted)

                Spacer(minLength: 8)

                NoirIconButton(icon: "mic", help: "Start dictation") {
                    DictationController.shared.toggleDictation()
                }

                Button(action: submitTyped) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: 0x2A2639))
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(NoirPalette.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 13)
        .padding(.bottom, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x222326))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NoirPalette.lineStrong, lineWidth: 1)
        )
        .frame(maxWidth: 850)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool {
        !appState.commandInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitTyped() {
        let text = appState.commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        noteUser(text)
        appState.executeTypedCommand()
    }

    private var shortcuts: some View {
        HStack(spacing: 16) {
            shortcut("⌘ ⇧ D", "Dictate")
            shortcut("⌘ ⇧ A", "Command")
            shortcut("↵", "Send")
        }
        .frame(maxWidth: .infinity)
    }

    private func shortcut(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 9))
                .foregroundStyle(NoirPalette.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(NoirPalette.line, lineWidth: 1)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(NoirPalette.muted)
        }
    }
}

// MARK: - Suggestion card

private struct SuggestionCard: View {
    let icon: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(NoirPalette.secondary)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 80, alignment: .bottomLeading)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x75757F))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? NoirPalette.accentSoft : Color.white.opacity(0.008))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(hovering ? NoirPalette.accent.opacity(0.21) : NoirPalette.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Orb

struct NoirOrb: View {
    let isListening: Bool
    let action: () -> Void

    @State private var spin = false
    @State private var breathe = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [NoirPalette.accent.opacity(0.07), .clear],
                            center: .center,
                            startRadius: 18,
                            endRadius: 140
                        )
                    )
                    .frame(width: 256, height: 256)

                Circle()
                    .strokeBorder(NoirPalette.accent.opacity(hovering ? 0.24 : 0.05), lineWidth: 1)
                    .frame(width: 182, height: 182)

                meridianField
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(
                        reduceMotion ? nil : .linear(duration: 34).repeatForever(autoreverses: false),
                        value: spin
                    )

                markerDot(size: 4, x: 51, y: -57)
                markerDot(size: 3, x: -58, y: 51)

                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [Color(hex: 0x363440).opacity(0.67), Color(hex: 0x24232B).opacity(0.5)],
                                center: .center,
                                startRadius: 2,
                                endRadius: 24
                            )
                        )
                    Circle()
                        .strokeBorder(Color(hex: 0xE5E1FF).opacity(0.125), lineWidth: 1)
                    Image(systemName: "mic")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color(hex: 0xD5D0EF))
                }
                .frame(width: 40, height: 40)
                .shadow(color: NoirPalette.accent.opacity(isListening ? 0.28 : 0.08), radius: 14)
            }
            .scaleEffect(breathe && isListening ? 1.035 : 1.0)
            .animation(
                isListening && !reduceMotion
                    ? .easeInOut(duration: 2).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.3),
                value: breathe
            )
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear {
            spin = true
            breathe = true
        }
        .accessibilityLabel(isListening ? "Stop listening" : "Start listening")
        .accessibilityAddTraits(isListening ? .isSelected : [])
    }

    private var meridianField: some View {
        ZStack {
            meridian(spans: [(69, 77), (52, 77), (26, 77)], rotation: -32)
            meridian(spans: [(77, 54), (77, 29), (77, 10)], rotation: 23)
            meridian(spans: [(69, 77), (43, 77)], rotation: 42)

            Circle()
                .stroke(meridianGradient, lineWidth: 0.7)
                .frame(width: 154, height: 154)

            Circle()
                .stroke(
                    NoirPalette.accent.opacity(0.2),
                    style: StrokeStyle(lineWidth: 0.7, lineCap: .round, dash: [1, 7])
                )
                .frame(width: 170, height: 170)
        }
    }

    private func meridian(spans: [(CGFloat, CGFloat)], rotation: Double) -> some View {
        ZStack {
            ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                Ellipse()
                    .stroke(meridianGradient, lineWidth: 0.7)
                    .frame(width: span.0 * 2, height: span.1 * 2)
            }
        }
        .rotationEffect(.degrees(rotation))
    }

    private var meridianGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(hex: 0xDCD4F4).opacity(0.65),
                Color(hex: 0xB5ABDA).opacity(0.17),
                Color(hex: 0xE2DCF5).opacity(0.5)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func markerDot(size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(Color(hex: 0xD2C9EA))
            .frame(width: size, height: size)
            .offset(x: x, y: y)
    }
}
