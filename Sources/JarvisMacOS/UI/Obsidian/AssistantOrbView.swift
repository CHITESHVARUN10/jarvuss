import AppKit
import SwiftUI
import WebKit

/// The approved Three.js renderer, isolated to the orb. The application shell,
/// settings, dialogs, command routing, and recording remain native views.
struct AssistantOrbView: View {
    var isListening = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let appearance = AppAppearance.shared
        OrbWebHost(style: appearance.orbStyle, accent: appearance.accent, animated: appearance.animateOrb && !reduceMotion)
            .accessibilityHidden(true)
    }
}

/// Renderer assets are packaged explicitly; development runs use the same file.
enum OrbRendererAsset {
    static var url: URL? {
        if let bundled = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "Orb") { return bundled }
        guard Bundle.main.bundleURL.pathExtension != "app" else { return nil }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("OrbAssets/renderer.html")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }
    static func configuration(style: AssistantOrbStyle, accent: AccentTheme, animated: Bool, active: Bool) -> String {
        let values: [String: Any] = ["style": style.rawValue, "accent": accent.rawValue, "motion": animated, "active": active]
        let json = String(data: try! JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), encoding: .utf8)!
        return "window.nativeOrb?.configure(\(json));"
    }
}

private struct OrbWebHost: NSViewRepresentable {
    let style: AssistantOrbStyle
    let accent: AccentTheme
    let animated: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> OrbWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.add(context.coordinator, name: "orbReady")
        let view = OrbWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        view.visibilityChanged = { [weak coordinator = context.coordinator] in coordinator?.apply() }
        if let url = OrbRendererAsset.url, let html = try? String(contentsOf: url, encoding: .utf8) {
            view.loadHTMLString(html, baseURL: nil)
        } else { NSLog("[Appearance] Bundled orb renderer is missing.") }
        return view
    }
    func updateNSView(_ view: OrbWebView, context: Context) {
        context.coordinator.style = style
        context.coordinator.accent = accent
        context.coordinator.animated = animated
        context.coordinator.apply()
    }
    static func dismantleNSView(_ view: OrbWebView, coordinator: Coordinator) {
        view.visibilityChanged = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "orbReady")
        view.navigationDelegate = nil
        view.stopLoading()
        // Destroy the rendering realm and release scenes/GPU buffers on leaving
        // the page; no hidden animation loop remains behind a settings screen.
        view.loadHTMLString("<!doctype html><html></html>", baseURL: nil)
        coordinator.view = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var view: OrbWebView?
        var style: AssistantOrbStyle = .liquid
        var accent: AccentTheme = .cobalt
        var animated = true
        private var reloadAttempts = 0
        private var lastConfiguration: String?
        func apply(force: Bool = false) {
            guard let view else { return }
            let configuration = OrbRendererAsset.configuration(style: style, accent: accent, animated: animated, active: view.orbVisible)
            // AppState also publishes microphone levels. Identical renderer
            // inputs must not turn those updates into repeated WebKit work.
            guard force || configuration != lastConfiguration else { return }
            lastConfiguration = configuration
            view.evaluateJavaScript(configuration, completionHandler: nil)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { apply(force: true) }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "orbReady", message.body as? String == "ready" else { return }
            apply(force: true)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard reloadAttempts < 1 else { return }
            reloadAttempts += 1
            guard let url = OrbRendererAsset.url, let html = try? String(contentsOf: url, encoding: .utf8) else { return }
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

private final class OrbWebView: WKWebView {
    var visibilityChanged: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    var orbVisible: Bool { window.map { !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false }
    override var acceptsFirstResponder: Bool { false }
    override var canBecomeKeyView: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        if let window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in self?.visibilityChanged?() })
            }
        }
        visibilityChanged?()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
