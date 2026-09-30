import SwiftUI

struct StatusBadge: View {
    let state: AppState.AssistantState
    let micActive: Bool
    var sessionState: AppState.VoiceSessionState = .idle

    private var label: String {
        if sessionState == .active && state == .listening {
            return "Session active"
        }
        return state.rawValue
    }

    private var dotColor: Color {
        if sessionState == .active && (state == .listening || state == .recording) {
            return JarvisColor.accent
        }
        switch state {
        case .idle:       return JarvisColor.textTertiary
        case .listening:  return JarvisColor.accent
        case .recording:  return JarvisColor.danger
        case .processing: return JarvisColor.attention
        case .executing:  return JarvisColor.ok
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .modifier(PulsingModifier(active: state == .listening || state == .recording || sessionState == .active))

            Text(label)
                .font(JarvisType.caption)
                .foregroundStyle(JarvisColor.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(JarvisColor.surface)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(JarvisColor.hairline, lineWidth: 1))
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
