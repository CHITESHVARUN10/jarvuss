import SwiftUI

struct MicOrbView: View {
    let assistantState: AppState.AssistantState
    let audioLevel: Double
    let micActive: Bool
    var sessionState: AppState.VoiceSessionState = .idle
    let onTap: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var iconOpacity: Double = 1.0

    /// One hue per state — calm, no gradients.
    private var stateColor: Color {
        if sessionState == .active && (assistantState == .listening || assistantState == .recording) {
            return JarvisColor.accent
        }
        switch assistantState {
        case .idle:       return JarvisColor.textTertiary
        case .listening:  return JarvisColor.accent
        case .recording:  return JarvisColor.danger
        case .processing: return JarvisColor.attention
        case .executing:  return JarvisColor.ok
        }
    }

    private var micIcon: String {
        switch assistantState {
        case .idle:       return "mic.slash.fill"
        case .listening:  return "waveform"
        case .recording:  return "mic.fill"
        case .processing: return "brain"
        case .executing:  return "bolt.fill"
        }
    }

    var body: some View {
        ZStack {
            // Level ring (reacts to audio)
            if assistantState == .recording {
                Circle()
                    .strokeBorder(stateColor.opacity(0.35), lineWidth: 1.5)
                    .frame(width: 168 + CGFloat(audioLevel * 24),
                           height: 168 + CGFloat(audioLevel * 24))
                    .animation(.easeOut(duration: 0.08), value: audioLevel)
            }

            // Inner orb fill
            Circle()
                .fill(JarvisColor.surface)
                .frame(width: 150, height: 150)

            // Hairline ring
            Circle()
                .strokeBorder(stateColor.opacity(assistantState == .idle ? 0.45 : 0.8), lineWidth: 1.5)
                .frame(width: 150, height: 150)

            // Icon
            Image(systemName: micIcon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(stateColor)
                .opacity(iconOpacity)
        }
        .frame(width: 180, height: 180)
        .shadow(color: stateColor.opacity(assistantState == .idle ? 0.10 : 0.25), radius: 24)
        .scaleEffect(pulseScale)
        .contentShape(Circle())
        .onTapGesture(perform: onTap)
        .onAppear { animatePulse() }
        .onChange(of: assistantState) { _ in animatePulse() }
    }

    private func animatePulse() {
        let shouldPulse = assistantState == .listening || assistantState == .recording
        let shouldIconPulse = assistantState == .listening || assistantState == .processing

        withAnimation(shouldPulse
            ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.4)
        ) {
            pulseScale = shouldPulse ? 1.04 : 1.0
        }

        withAnimation(shouldIconPulse
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.3)
        ) {
            iconOpacity = shouldIconPulse ? 0.5 : 1.0
        }
    }
}
