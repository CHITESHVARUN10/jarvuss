import AppKit
import Foundation
import SwiftUI

/// Global floating result panel — shows a short answer above ALL apps.
///
/// The in-window PopupView only renders when Jarvis is frontmost, so
/// background ⌘⇧A answers (time, date, brightness) were invisible. This
/// NSPanel floats at .statusBar level on all Spaces, never activates the
/// app, and auto-dismisses after 3 s. One panel is reused across calls.
enum FloatPanel {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?

    static func show(text: String, icon: String, duration: TimeInterval = 3.0) {
        DispatchQueue.main.async {
            dismissWork?.cancel()
            let size = NSSize(width: 340, height: 150)
            let p: NSPanel
            if let existing = panel {
                p = existing
            } else {
                // Fixed-size panel: the window frame NEVER changes after
                // creation (AppKit throws NSGenericException "more Update
                // Constraints passes than views" when a borderless NSPanel
                // hosting SwiftUI is resized while its content also has an
                // intrinsic size — the 2026-09-29 SIGABRT). Content is a
                // fixed 340×150 view; only the hosted rootView swaps.
                p = NSPanel(
                    contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered,
                    defer: false
                )
                p.isFloatingPanel = true
                p.level = .statusBar + 1
                p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
                p.isOpaque = false
                p.backgroundColor = .clear
                p.hasShadow = false
                p.hidesOnDeactivate = false
                p.ignoresMouseEvents = true
                p.becomesKeyOnlyIfNeeded = true
                panel = p
            }
            if p.contentView == nil {
                p.contentView = NSView(frame: NSRect(origin: .zero, size: size))
                p.contentView?.wantsLayer = true
                p.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
            }
            let host = NSHostingView(rootView: FloatResultView(message: text, icon: icon))
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = []
            // Swap the hosted subview WITHOUT touching the window frame:
            // setFrame on a borderless panel re-triggers the constraint
            // solver that crashed (NSPanel 165×151 in the 21:24 report).
            p.contentView?.subviews.forEach { $0.removeFromSuperview() }
            p.contentView?.addSubview(host)
            if let screen = NSScreen.main ?? NSScreen.screens.first {
                let v = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
            }
            p.orderFrontRegardless()
            let work = DispatchWorkItem { panel?.orderOut(nil) }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }
}

private struct FloatResultView: View {
    let message: String
    let icon: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
            Text(message)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 8)
        }
        // Fixed 340×150 content: matches the panel's fixed frame so
        // Auto Layout never has to reconcile window vs content size
        // (the constraint-loop SIGABRT came from that fight).
        .frame(width: 340, height: 150)
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
