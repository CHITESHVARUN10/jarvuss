import AppKit

/// Hosts the floating quick answer for commands used outside the main window.
/// The native visual effect samples the desktop behind the nonactivating window.
@MainActor
final class DesktopPanelSurface: NSView {
    private let web = DesktopWebView(document: "panel", transparent: true)
    private let material = NSVisualEffectView()
    private var state: (String, [String: Any])?
    private var loaded = false
    var onResize: ((CGFloat) -> Void)?
    var onAction: ((String) -> Any?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        for view in [material, web] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        web.onLoad = { [weak self] in
            self?.loaded = true
            self?.currentAppearance = [:]
            self?.presentState()
        }
        web.handle = { [weak self] action, args in
            guard let self else { return nil }
            if action == "height" {
                if let value = args["height"] as? Double, value.isFinite {
                    self.onResize?(CGFloat(value))
                }
                return nil
            }
            return self.onAction?(action)
        }
    }

    required init?(coder: NSCoder) { nil }

    func present(_ method: String, state: [String: Any]) {
        self.state = (method, state)
        presentState()
    }

    private func presentState() {
        guard loaded, let (method, values) = state else { return }
        let appearance = AppAppearance.shared.desktopValues
        if !NSDictionary(dictionary: appearance).isEqual(to: currentAppearance) {
            currentAppearance = appearance
            web.deliver("appearance", appearance)
        }
        web.deliver(method, values)
    }

    private var currentAppearance: [String: Any] = [:]
}
