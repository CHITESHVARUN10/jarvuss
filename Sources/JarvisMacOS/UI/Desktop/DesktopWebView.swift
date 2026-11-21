import AppKit
import WebKit

/// Only bundled documents can access the bridge. Native data reaches the page
/// as arguments, never as interpolated script or markup.
@MainActor
final class DesktopWebView: WKWebView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
    typealias Handler = (String, [String: Any]) async throws -> Any?
    private let document: URL
    var handle: Handler?
    var onLoad: (() -> Void)?
    var onVisibility: ((Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(document name: String, transparent: Bool = false) {
        let assets = Bundle.main.url(forResource: "JarvisMacOS_JarvisMacOS", withExtension: "bundle")
            .flatMap(Bundle.init(url:)) ?? Bundle.module
        document = assets.url(forResource: name, withExtension: "html", subdirectory: "Assets")!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        super.init(frame: .zero, configuration: configuration)
        configuration.userContentController.addScriptMessageHandler(
            DesktopMessageHandler(view: self), contentWorld: .page, name: "jarvis"
        )
        navigationDelegate = self
        uiDelegate = self
        allowsBackForwardNavigationGestures = false
        if transparent {
            setValue(false, forKey: "drawsBackground")
            underPageBackgroundColor = .clear
        } else {
            let background = NSColor(srgbRed: 9 / 255, green: 9 / 255, blue: 11 / 255, alpha: 1)
            underPageBackgroundColor = background
        }
        loadFileURL(document, allowingReadAccessTo: document.deletingLastPathComponent())
    }

    required init?(coder: NSCoder) { nil }

    func deliver(_ method: String, _ data: Any = NSNull()) {
        callAsyncJavaScript(
            "window.jarvisUI?.[method]?.(data)", arguments: ["method": method, "data": data],
            in: nil, in: .page, completionHandler: nil
        )
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onLoad?() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.targetFrame?.isMainFrame == true &&
            navigationAction.request.url?.standardizedFileURL == document.standardizedFileURL ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadFileURL(document, allowingReadAccessTo: document.deletingLastPathComponent())
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.webView === self,
              message.frameInfo.request.url?.standardizedFileURL == document.standardizedFileURL,
              let body = message.body as? [String: Any],
              let action = body["action"] as? String,
              let arguments = body["payload"] as? [String: Any], let handle else {
            replyHandler(nil, "This action is unavailable.")
            return
        }
        Task {
            do { replyHandler(try await handle(action, arguments) ?? NSNull(), nil) }
            catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let window {
            let events: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification
            ]
            for event in events {
                observers.append(NotificationCenter.default.addObserver(forName: event, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateVisibility() }
                })
            }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        onVisibility?(window.map { !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false)
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

/// WKUserContentController retains its handler. This relay leaves ownership
/// of the view with its AppKit window.
private final class DesktopMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var view: DesktopWebView?
    init(view: DesktopWebView) { self.view = view }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let view else { replyHandler(nil, "The window has closed."); return }
        view.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

struct DesktopUIError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension AppAppearance {
    var desktopValues: [String: Any] {
        let scales: [InterfaceTextSize: String] = [.extraSmall: "0.86", .small: "0.93", .standard: "1", .large: "1.08", .extraLarge: "1.16"]
        return [
            "hex": String(format: "#%06x", accent.hex),
            "rgb": [16, 8, 0].map { String((accent.hex >> $0) & 255) }.joined(separator: ", "),
            "orb": orbStyle.rawValue, "motion": animateOrb,
            "scale": scales[textSize] ?? "1", "glass": glassOpacity, "contrast": borderContrast
        ]
    }
}
