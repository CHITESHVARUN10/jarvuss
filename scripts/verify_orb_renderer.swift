// swift scripts/verify_orb_renderer.swift [renderer.html] [output-directory]
// Isolated native WebKit smoke check: no app state, microphone, or commands.
import AppKit
import WebKit

@MainActor final class OrbCheck: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var web: WKWebView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        window.orderBack(nil)
        let source = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Sources/JarvisMacOS/UI/Obsidian/OrbAssets/renderer.html"
        guard let html = try? String(contentsOfFile: source, encoding: .utf8) else { finish("Missing renderer", code: 1); return }
        web.loadHTMLString(html, baseURL: nil)
        Task { await check() }
    }
    private func check() async {
        do {
            var ready = false
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("!!(window.nativeOrb && window.THREE)")) as? Bool == true { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { finish("Renderer never initialized", code: 1); return }
            for style in ["liquid", "halo", "aurora", "lattice", "prism"] {
                _ = try await web.evaluateJavaScript("nativeOrb.configure({style:'\(style)',accent:'cobalt',motion:false,active:true});")
                try await Task.sleep(for: .milliseconds(150))
                let state = try await web.evaluateJavaScript("JSON.stringify(nativeOrb.state())") as? String ?? ""
                guard state.contains("Three.js"), state.contains(style) else { finish("Invalid renderer state: \(state)", code: 1); return }
                if CommandLine.arguments.count > 2 {
                    let image = try await web.takeSnapshot(configuration: nil)
                    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { finish("No snapshot for \(style)", code: 1); return }
                    try FileManager.default.createDirectory(atPath: CommandLine.arguments[2], withIntermediateDirectories: true)
                    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("\(style).png"))
                }
                print("PASS \(style): \(state)")
            }
            _ = try await web.evaluateJavaScript("nativeOrb.configure({style:'liquid',accent:'cobalt',motion:true,active:false});")
            let state = try await web.evaluateJavaScript("JSON.stringify(nativeOrb.state())") as? String ?? ""
            guard state.contains("\"active\":false") else { finish("Renderer did not deactivate", code: 1); return }
            finish("PASS deactivation; all five offline native WebKit scenes initialized", code: 0)
        } catch { finish("Renderer verification failed: \(error)", code: 1) }
    }
    private func finish(_ message: String, code: Int32) { print(message); web.stopLoading(); window.orderOut(nil); exit(code) }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = OrbCheck()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
