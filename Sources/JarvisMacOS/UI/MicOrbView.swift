import SwiftUI

struct MicOrbView: View {
    let assistantState: AppState.AssistantState
    let audioLevel: Double
    let micActive: Bool
    var sessionState: AppState.VoiceSessionState = .idle
    let onTap: () -> Void

    @State private var pulseScale: CGFloat = 1.0
    @State private var iconOpacity: Double = 1.0

    private var orbColor: (Color, Color, Color) {
        if sessionState == .active && assistantState == .listening {
            return (Color(red: 0.35, green: 0.85, blue: 1.0),
                    Color(red: 0.65, green: 0.40, blue: 1.0),
                    Color(red: 0.20, green: 0.70, blue: 1.0))
        }
        switch assistantState {
        case .idle:
            return (Color(red: 0.35, green: 0.35, blue: 0.55),
                    Color(red: 0.25, green: 0.25, blue: 0.45),
                    Color(red: 0.20, green: 0.20, blue: 0.40))
        case .listening:
            return (Color(red: 0.48, green: 0.48, blue: 1.0),
                    Color(red: 0.70, green: 0.38, blue: 1.0),
                    Color(red: 0.35, green: 0.80, blue: 1.0))
        case .recording:
            return (Color(red: 1.0, green: 0.36, blue: 0.55),
                    Color(red: 0.90, green: 0.25, blue: 0.40),
                    Color(red: 0.80, green: 0.30, blue: 0.70))
        case .processing:
            return (Color(red: 0.95, green: 0.75, blue: 0.20),
                    Color(red: 0.95, green: 0.55, blue: 0.10),
                    Color(red: 0.90, green: 0.65, blue: 0.30))
        case .executing:
            return (Color(red: 0.20, green: 0.85, blue: 0.65),
                    Color(red: 0.15, green: 0.75, blue: 0.85),
                    Color(red: 0.30, green: 0.95, blue: 0.55))
        }
    }

    private var glowColor: Color {
        if sessionState == .active && (assistantState == .listening || assistantState == .recording) {
            return Color(red: 0.35, green: 0.85, blue: 1.0).opacity(0.45)
        }
        switch assistantState {
        case .idle:       return Color(red: 0.4, green: 0.4, blue: 0.8).opacity(0.25)
        case .listening:  return Color(red: 0.6, green: 0.6, blue: 1.0).opacity(0.30)
        case .recording:  return Color(red: 1.0, green: 0.3, blue: 0.5).opacity(0.45)
        case .processing: return Color(red: 1.0, green: 0.75, blue: 0.2).opacity(0.40)
        case .executing:  return Color(red: 0.2, green: 0.9, blue: 0.6).opacity(0.40)
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
            // Outer glow ring
            Circle()
                .fill(glowColor)
                .frame(width: 230, height: 230)
                .blur(radius: 35)
                .scaleEffect(pulseScale)

            // Level ring (reacts to audio)
            if assistantState == .recording {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [orbColor.0.opacity(0.7), orbColor.1.opacity(0.4)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 3
                    )
                    .frame(width: 165 + CGFloat(audioLevel * 30),
                           height: 165 + CGFloat(audioLevel * 30))
                    .animation(.easeOut(duration: 0.08), value: audioLevel)
            }

            // Main orb border gradient
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [orbColor.0, orbColor.1, orbColor.2],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.5
                )
                .frame(width: 156, height: 156)

            // Inner orb fill
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.08, blue: 0.12),
                            Color(red: 0.06, green: 0.06, blue: 0.10)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 150, height: 150)

            // Gloss overlay inside
            Circle()
                .fill(
                    LinearGradient(
                        colors: [orbColor.0.opacity(0.15), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 150, height: 150)

            // Icon
            Image(systemName: micIcon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [orbColor.0, orbColor.1],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: orbColor.0.opacity(0.6), radius: 10)
                .opacity(iconOpacity)
        }
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
            pulseScale = shouldPulse ? 1.08 : 1.0
        }

        withAnimation(shouldIconPulse
            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.3)
        ) {
            iconOpacity = shouldIconPulse ? 0.5 : 1.0
        }
    }
}
