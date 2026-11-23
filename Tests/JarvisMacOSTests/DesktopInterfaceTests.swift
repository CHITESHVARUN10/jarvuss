import AppKit
import SwiftUI
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
            const recordingBars = document.querySelectorAll('#inlinePreviewHud .hud-bar').length;
            document.getElementById('previewHudPhase').value = 'result';
            document.getElementById('previewHudPhase').dispatchEvent(new Event('change'));
            const dictationTitle = document.querySelector('#inlinePreviewHud .hud-label').textContent;
            document.getElementById('previewHudPhase').value = 'recording';
            document.getElementById('previewHudMode').value = 'command';
            document.getElementById('previewHudMode').dispatchEvent(new Event('change'));
            return {
                files: search.files.length,
                orb: document.getElementById('orbPreview').dataset.style,
                recordingBars,
                dictationTitle,
                commandTitle: document.querySelector('#inlinePreviewHud .hud-label').textContent,
                commandBars: document.querySelectorAll('#inlinePreviewHud .hud-bar').length,
                width: document.querySelector('.app-shell').clientWidth
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["files"] as? Int, 0)
        XCTAssertEqual(result?["orb"] as? String, "halo")
        XCTAssertEqual(result?["recordingBars"] as? Int, 64)
        XCTAssertEqual(result?["dictationTitle"] as? String, "Dictation ready")
        XCTAssertEqual(result?["commandTitle"] as? String, "Command · listening")
        XCTAssertEqual(result?["commandBars"] as? Int, 64)
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
    func testFloatingQuickAnswerStillRendersPlainTextAndCanClose() async throws {
        let web = DesktopWebView(document: "panel", transparent: true)
        web.frame = NSRect(x: 0, y: 0, width: 440, height: 220)
        let close = expectation(description: "Quick answer closes")
        web.handle = { action, _ in
            if action == "close" { close.fulfill() }
            return nil
        }
        try await waitForDesktop(web)
        let result = try await web.callAsyncJavaScript("""
            window.jarvisUI.answer({title:'Quick Answer', text:'<b>Typed</b>', meta:'Local clock'});
            const result = document.querySelector('.quick-answer-val');
            document.querySelector('[data-hud="close"]').click();
            return {text: result.textContent, count: result.childElementCount};
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["text"] as? String, "<b>Typed</b>")
        XCTAssertEqual(result?["count"] as? Int, 0)
        await fulfillment(of: [close], timeout: 1)
    }

    @MainActor
    func testDictationUsesNativePanelAndCleansRepeatedWordsBeforeDisplayingResult() throws {
        let app = NSApplication.shared
        let existingWindows = Set(app.windows.map(ObjectIdentifier.init))
        let suite = "jarvis-hud-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "jarvis.dictation.insertAtCursor")
        var phase: AppPhase = .Ready
        let controller = DictationController(defaults: defaults, capture: DictationCapture(
            phase: { phase },
            start: { phase = .Recording; return true },
            stop: { phase = .Processing },
            cancel: { phase = .Ready }
        ), releaseTransientMic: {})
        var window: NSWindow?
        defer {
            controller.dismissTranscript()
            window?.contentView = nil
            defaults.removePersistentDomain(forName: suite)
        }

        controller.toggleDictation()
        window = app.windows.first { $0 is NSPanel && !existingWindows.contains(ObjectIdentifier($0)) }
        let panel = try XCTUnwrap(window)
        let host = try XCTUnwrap(panel.contentView as? NSHostingView<DictationHUDView>)
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.recordingSize)
        controller.livePreviewEnabled = true
        controller.partialTranscript = "Check the API"
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.recordingSize(showingPreview: true))

        controller.toggleDictation()
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.processingSize)
        let raw = "Check the " + String(repeating: "API. ", count: 23)
        controller.receiveDictationTranscript(raw, speechSeconds: 2)
        XCTAssertTrue(panel.contentView === host)
        XCTAssertEqual(panel.frame.width, DictationHUDLayout.transcriptWidth)
        XCTAssertEqual(controller.transcript, "Check the API.")
        XCTAssertEqual(controller.originalTranscript, raw)

        controller.dismissTranscript()
        controller.toggleAction()
        XCTAssertEqual(controller.mode, .action)
        XCTAssertTrue(panel.contentView === host)
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.recordingSize)
        controller.partialTranscript = "Find the API key"
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.recordingSize(showingPreview: true))
        controller.toggleAction()
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.processingSize)
        controller.phase = .TranscriptReady
        controller.showPanelIfNeeded()
        XCTAssertEqual(panel.frame.size, DictationHUDLayout.processingSize)
        controller.receiveActionTranscript("Find the API key") {
            XCTAssertFalse(panel.isVisible)
            XCTAssertEqual(STTRouter.shared.owner, .action)
        }
        XCTAssertEqual(STTRouter.shared.owner, .none)
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
