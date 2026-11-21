import AppKit
import Foundation
import SwiftUI

/// The in-window and global answer use the same layout, with the global
/// fallback remaining visible when a shortcut was used in another app.
@MainActor
enum FloatPanel {
    static var presentInDesktop: (([String: Any]) -> Bool)?
    private static var panel: NSPanel?
    private static var surface: DesktopPanelSurface?
    private static var dismissTask: Task<Void, Never>?

    static func show(text: String, icon: String, duration: TimeInterval = 3.0) {
        let clock = icon.hasPrefix("clock")
        let calendar = icon.hasPrefix("calendar")
        let values: [String: Any] = [
            "title": "Quick Answer", "text": text,
            "meta": clock ? "Local system clock" : calendar ? "Local calendar" : "System information",
            "duration": duration * 1000
        ]
        dismissTask?.cancel()
        if presentInDesktop?(values) == true {
            panel?.orderOut(nil)
            return
        }
        if panel == nil { prepare() }
        surface?.present("answer", state: values)
        position()
        panel?.orderFrontRegardless()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(duration))
            if !Task.isCancelled { panel?.orderOut(nil) }
        }
    }

    private static func prepare() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 122),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        let surface = DesktopPanelSurface(frame: .zero)
        window.isFloatingPanel = true
        window.level = .statusBar + 1
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.contentView = surface
        surface.onResize = { [weak window] height in
            guard let window, window.isVisible else { return }
            let size = NSSize(width: 300, height: min(300, max(75, height)))
            if window.frame.size != size { window.setContentSize(size); position() }
        }
        surface.onAction = { [weak window] action in
            if action == "close" { window?.orderOut(nil) }
            return nil
        }
        self.surface = surface
        panel = window
    }

    private static func position() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 17, y: visible.maxY - panel.frame.height - 17))
    }
}

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
