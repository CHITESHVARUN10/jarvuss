import AppKit
import WebKit
import XCTest
@testable import JarvisMacOS

final class DesktopInterfaceTests: XCTestCase {
    @MainActor
    func testBundledDesktopLoadsWithNativeBridgeAndResponsiveLayout() async throws {
        let state = AppState(activateServices: false)
        let session = DesktopSession(app: state) { _ in }
        let web = session.makeView()
        web.frame = NSRect(x: 0, y: 0, width: 1240, height: 790)
        try await waitForDesktop(web, condition: "document.getElementById('workspaceFolders').children.length >= 3")

        let folderCount = try await web.evaluateJavaScript("document.getElementById('workspaceFolders').children.length") as? Int
        XCTAssertGreaterThanOrEqual(folderCount ?? 0, 3)

        let initialTitle = try await web.evaluateJavaScript("document.getElementById('presenceTitle').textContent") as? String
        XCTAssertEqual(initialTitle, "Ready for a command")
        let emptyStream = try await web.evaluateJavaScript("document.querySelector('.empty-session-msg').textContent") as? String
        XCTAssertEqual(emptyStream, "No commands in this session.")

        let result = try await web.callAsyncJavaScript("""
            const search = await native('searchState');
            switchView('appearance');
            document.getElementById('orbStyleSelect').value = 'halo';
            currentOrb = 'halo';
            syncOrb();
            document.getElementById('previewHudPhase').value = 'result';
            document.getElementById('previewHudPhase').dispatchEvent(new Event('change'));
            return {
                files: search.files.length,
                orb: document.getElementById('orbPreview').dataset.style,
                hud: document.querySelector('#inlinePreviewHud .hud-label').textContent,
                width: document.querySelector('.app-shell').clientWidth
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["files"] as? Int, 0)
        XCTAssertEqual(result?["orb"] as? String, "halo")
        XCTAssertEqual(result?["hud"] as? String, "Dictation ready")
        XCTAssertEqual(result?["width"] as? Int, 1240)

        web.frame.size = CGSize(width: 480, height: 540)
        let compact = try await web.callAsyncJavaScript("""
            await new Promise(resolve => setTimeout(resolve, 100));
            return {
                width: document.querySelector('.app-shell').clientWidth,
                scrollWidth: document.documentElement.scrollWidth,
                height: document.querySelector('.app-shell').clientHeight,
                sidebar: document.querySelector('.sidebar').clientWidth
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Int]
        XCTAssertEqual(compact?["width"], 480)
        XCTAssertEqual(compact?["scrollWidth"], 480)
        XCTAssertEqual(compact?["height"], 540)
        XCTAssertLessThanOrEqual(compact?["sidebar"] ?? 100, 42)

        let searchReady = try await web.callAsyncJavaScript("""
            openFileSearch();
            await new Promise(resolve => setTimeout(resolve, 120));
            return document.getElementById('fileSearchModal').classList.contains('open')
                && document.activeElement === document.getElementById('fileSearchInput')
                && document.querySelector('#fileSearchModal .modal-foot .btn-primary').disabled;
            """, arguments: [:], in: nil, contentWorld: .page) as? Bool
        XCTAssertEqual(searchReady, true)
    }

    @MainActor
    func testGlobalHUDUsesSharedRecordingAndResultMarkup() async throws {
        let web = DesktopWebView(document: "panel", transparent: true)
        web.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
        web.handle = { _, _ in nil }
        try await waitForDesktop(web)
        let result = try await web.callAsyncJavaScript("""
            const state = {
                mode: 'dictation', phase: 'recording', text: '<b>Typed</b>', clock: '0:08',
                level: 0.55, notice: 'Audio stays on this Mac', original: 'typed',
                copied: false, inserted: false, needsAccess: false
            };
            window.jarvisUI.hud(state);
            const bars = document.querySelectorAll('.hud-bar').length;
            const title = document.querySelector('.hud-label').textContent;
            window.jarvisUI.hud({...state, phase:'result'});
            const result = document.querySelector('.hud-transcript');
            return {bars, title, text: result.textContent, count: result.childElementCount};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["bars"] as? Int, 30)
        XCTAssertEqual(result?["title"] as? String, "Dictation recording")
        XCTAssertEqual(result?["text"] as? String, "<b>Typed</b>")
        XCTAssertEqual(result?["count"] as? Int, 0)
    }

    @MainActor
    private func waitForDesktop(_ web: WKWebView, condition: String = "true") async throws {
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            if (try? await web.evaluateJavaScript("Boolean(window.jarvisUI && document.readyState === 'complete' && (\(condition)))")) as? Bool == true {
                // The reply to the startup message supplies the initial view model.
                try await Task.sleep(for: .milliseconds(120))
                return
            }
        }
        throw DesktopUIError("The bundled desktop scripts did not load.")
    }
}
