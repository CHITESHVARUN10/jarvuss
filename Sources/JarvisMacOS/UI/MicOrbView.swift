import SwiftUI

/// Mock `.orb`: 132pt circle, radial-gradient fill, 1px line border, one halo
/// ring scaled per state, and a ripple pulse-ring while listening/recording.
struct MicOrbView: View {
    let assistantState: AppState.AssistantState
    let audioLevel: Double
    let micActive: Bool
    let onTap: () -> Void

    @State private var ripple = false
    @State private var spin = false
    @State private var hovering = false

    private var isLive: Bool {
        micActive && (assistantState == .listening || assistantState == .recording)
    }

    /// One hue per state — calm, no gradients.
    private var stateColor: Color {
        guard micActive else { return JColor.ink3 }
        switch assistantState {
        case .idle:       return JColor.ink3
        case .listening:  return JColor.accent
        case .recording:  return JColor.danger
        case .processing: return JColor.warn
        case .executing:  return JColor.ok
        }
    }

    private var borderColor: Color {
        switch assistantState {
        case .idle:       return JColor.line
        case .listening:  return JColor.accent.opacity(0.30)
        case .recording:  return JColor.danger.opacity(0.45)
        case .processing: return JColor.warn.opacity(0.45)
        case .executing:  return JColor.ok.opacity(0.45)
        }
    }

    private var haloScale: CGFloat {
        guard micActive else { return 1.0 }
        switch assistantState {
        case .idle:       return 1.0
        case .listening:  return 1.18
        case .recording:  return 1.20
        case .processing: return 1.14
        case .executing:  return 1.20
        }
    }

    private var haloOpacity: Double {
        guard micActive else { return 0 }
        switch assistantState {
        case .idle:       return 0
        case .listening:  return 0.60
        case .recording:  return 0.65
        case .processing: return 0.60
        case .executing:  return 0.65
        }
    }

    private var micIcon: String {
        switch assistantState {
        case .idle:       return micActive ? "mic" : "mic.slash"
        case .listening:  return "mic"
        case .recording:  return "mic.fill"
        case .processing: return "brain"
        case .executing:  return "bolt.fill"
        }
    }

    var body: some View {
        ZStack {
            // Ripple ring — only while listening.
            if micActive && assistantState == .listening {
                Circle()
                    .strokeBorder(JColor.accent, lineWidth: 1.5)
                    .scaleEffect(ripple ? 1.42 : 1.0)
                    .opacity(ripple ? 0 : 0.5)
            }

            // Halo ring.
            Circle()
                .strokeBorder(stateColor, lineWidth: 1.5)
                .scaleEffect(haloScale)
                .opacity(haloOpacity)

            // Orb body.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.05), Color.white.opacity(0.012)],
                        center: UnitPoint(x: 0.5, y: 0.38),
                        startRadius: 0,
                        endRadius: 92
                    )
                )
                .background(Circle().fill(JColor.base))
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 1))
                .frame(width: 132, height: 132)

            Image(systemName: micIcon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(stateColor)
        }
        .frame(width: 176, height: 176)
        .shadow(color: glowColor, radius: 22, y: 12)
        .scaleEffect(hovering ? 1.03 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
        .animation(.easeOut(duration: 0.45), value: assistantState)
        .animation(.easeOut(duration: 0.45), value: micActive)
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .onAppear { updateAnimations() }
        .onChange(of: assistantState) { _ in updateAnimations() }
        .onChange(of: micActive) { _ in updateAnimations() }
    }

    private var glowColor: Color {
        guard micActive, assistantState != .idle else { return .clear }
        return stateColor.opacity(0.5)
    }

    private func updateAnimations() {
        if micActive && assistantState == .listening {
            ripple = false
            withAnimation(.easeOut(duration: 2.6).repeatForever(autoreverses: false)) {
                ripple = true
            }
        } else {
            ripple = false
        }
    }
}
