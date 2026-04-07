import SwiftUI

struct PopupView: View {
    @ObservedObject var manager: PopupManager

    var body: some View {
        if manager.isVisible {
            VStack(spacing: 12) {
                Image(systemName: manager.icon)
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.white.opacity(0.85))

                Text(manager.message)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.35, green: 0.35, blue: 1.0).opacity(0.25),
                                    Color(red: 0.6, green: 0.3, blue: 1.0).opacity(0.15)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
            )
            .shadow(color: Color(red: 0.4, green: 0.4, blue: 1.0).opacity(0.35), radius: 40, x: 0, y: 10)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.9)),
                removal: .opacity.combined(with: .scale(scale: 0.95))
            ))
            .onTapGesture {
                manager.dismiss()
            }
        }
    }
}
