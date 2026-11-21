import AppKit
import Combine

/// The shortcut panel uses the same markup and CSS as the Appearance preview.
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

@MainActor
final class DesktopRecordingSurface: NSView {
    private let surface = DesktopPanelSurface(frame: .zero)
    private weak var model: DictationController?
    private var subscription: AnyCancellable?

    init(model: DictationController, onResize: @escaping (CGFloat) -> Void) {
        self.model = model
        super.init(frame: .zero)
        addSubview(surface)
        surface.autoresizingMask = [.width, .height]
        surface.onResize = onResize
        surface.onAction = { [weak model] action in
            guard let model else { return nil }
            switch action {
            case "close": model.dismissTranscript()
            case "finish":
                if model.mode == .action { model.toggleAction() }
                else { model.toggleDictation() }
            case "copy": model.copyTranscript()
            case "copyOriginal": return model.copyOriginalTranscript()
            case "undo": model.undoInsert()
            case "access": model.openAccessibilityPane()
            case "retry": model.retryRecording()
            default: break
            }
            return nil
        }
        subscription = model.objectWillChange
            .throttle(for: .milliseconds(65), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        guard let model, window?.isVisible == true else { return }
        let phase: String
        let notice: String
        var text = model.transcript
        if model.shortcutPreparing {
            phase = "processing"; notice = "Preparing microphone…"
        } else {
            switch model.phase {
            case .Recording:
                phase = "recording"
                notice = model.captureStarting ? "Opening microphone…" : model.mode == .action ? "Say your command" : "Audio stays on this Mac"
            case .TranscriptReady:
                phase = "result"
                notice = model.copied ? "Copied to clipboard." : model.insertedAtCursor ? "Inserted at the cursor."
                    : model.formattingInProgress ? "Formatting on this Mac…" : model.insertNotice
            case .Error:
                phase = "error"; notice = ""; text = model.errorMessage
            case .Preparing:
                phase = "processing"
                notice = ["Preparing speech model · \(Int(model.downloadProgress * 100))%", model.downloadSpeed, model.downloadRemaining]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            case .Processing:
                phase = "processing"; notice = "Transcribing on this Mac…"
            default:
                phase = "processing"; notice = "Loading the speech model…"
            }
        }
        let seconds = Int(max(0, model.recordedSeconds))
        let level = max(0.08, min(1, sqrt(Double(max(0, model.audioLevel))) * 2.5))
        surface.present("hud", state: [
            "phase": phase, "mode": model.mode == .action ? "command" : "dictation",
            "clock": "\(seconds / 60):\(String(format: "%02d", seconds % 60))", "level": level,
            "notice": notice, "text": text,
            "partial": model.livePreviewEnabled ? model.partialTranscript : "",
            "original": model.copyOriginalEnabled ? model.originalTranscript : "",
            "inserted": model.insertedAtCursor, "copied": model.copied,
            "needsAccess": !model.insertedAtCursor && model.insertAtCursorEnabled && !model.insertNotice.isEmpty && !AXIsProcessTrusted()
        ])
    }
}
