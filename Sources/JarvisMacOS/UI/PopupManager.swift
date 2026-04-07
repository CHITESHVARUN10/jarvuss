import Foundation
import SwiftUI

@MainActor
final class PopupManager: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var message: String = ""
    @Published var icon: String = "info.circle.fill"

    private var dismissTask: Task<Void, Never>?

    func show(message: String, icon: String = "info.circle.fill", duration: TimeInterval = 3.0) {
        dismissTask?.cancel()
        self.message = message
        self.icon = icon
        withAnimation(.easeIn(duration: 0.25)) {
            isVisible = true
        }
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.3)) {
                    self?.isVisible = false
                }
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) {
            isVisible = false
        }
    }
}
