import SwiftUI

struct StatusBadge: View {
    let state: AppState.AssistantState
    let micActive: Bool
    var sessionState: AppState.VoiceSessionState = .idle

    private var label: String {
        if sessionState == .active && state == .listening {
            return "SESSION ACTIVE (FOLLOW-UP)"
        }
        return state.rawValue.uppercased()
    }

    private var dotColor: Color {
        if sessionState == .active && (state == .listening || state == .recording) {
            return Color(red: 0.35, green: 0.85, blue: 1.0)
        }
        switch state {
        case .idle:       return Color(red: 0.55, green: 0.55, blue: 0.65)
        case .listening:  return Color(red: 0.55, green: 0.88, blue: 1.0)
        case .recording:  return Color(red: 1.0, green: 0.38, blue: 0.55)
        case .processing: return Color(red: 1.0, green: 0.78, blue: 0.2)
        case .executing:  return Color(red: 0.25, green: 0.90, blue: 0.65)
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
                .shadow(color: dotColor.opacity(0.85), radius: 5)
                .modifier(PulsingModifier(active: state == .listening || state == .recording || sessionState == .active))

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.8)
                .foregroundStyle(dotColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(dotColor.opacity(0.12))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(dotColor.opacity(0.35), lineWidth: 0.8))
    }
}

struct PulsingModifier: ViewModifier {
    let active: Bool
    @State private var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .opacity(active ? opacity : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    opacity = 0.25
                }
            }
            .onChange(of: active) { newVal in
                if newVal {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        opacity = 0.25
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { opacity = 1.0 }
                }
            }
    }
}
