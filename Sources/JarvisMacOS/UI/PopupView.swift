import SwiftUI

struct PopupView: View {
    @ObservedObject var manager: PopupManager

    var body: some View {
        if manager.isVisible {
            ObsidianAnswerCard(message: manager.message, icon: manager.icon)
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
