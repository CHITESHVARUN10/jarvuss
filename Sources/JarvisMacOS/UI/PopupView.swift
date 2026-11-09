import SwiftUI

struct PopupView: View {
    @ObservedObject var manager: PopupManager

    var body: some View {
        if manager.isVisible {
            VStack(spacing: 12) {
                Image(systemName: manager.icon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(JarvisColor.textSecondary)

                Text(manager.message)
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(JarvisColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 30)
            .background(GlassPanelBackground().clipShape(RoundedRectangle(cornerRadius: 16)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(NoirPalette.lineStrong, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.35), radius: 40, x: 0, y: 10)
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
