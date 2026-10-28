import SwiftUI
import AppKit

// MARK: - HUD root

/// Dictation HUD content, hosted in a borderless NSPanel by DictationController.
/// Noir language: graphite card, lavender hairline, flat controls.
struct DictationHUDView: View {
    @ObservedObject private var model = DictationController.shared

    private var isAction: Bool { model.mode == .action }

    var body: some View {
        Group {
            if model.shortcutPreparing {
                DictationReloadingView(message: "Preparing microphone…")
                    .frame(width: 300)
            } else { switch model.phase {
            case .Recording:
                DictationRecordingPillView(
                    audioLevel: model.audioLevel,
                    livePreview: model.partialTranscript,
                    livePreviewEnabled: model.livePreviewEnabled,
                    isAction: isAction,
                    isStarting: model.captureStarting,
                    recordedSeconds: model.recordedSeconds,
                    limitMinutes: model.activeRecordingLimitMinutes
                )

            case .Processing:
                DictationTranscribingPillView(isAction: isAction)

            case .TranscriptReady:
                DictationTranscriptOverlayView(
                    transcript: model.transcript,
                    original: model.originalTranscript,
                    copied: model.copied,
                    inserted: model.insertedAtCursor,
                    formatting: model.formattingInProgress,
                    insertNotice: model.insertNotice,
                    showCopyOriginal: model.copyOriginalEnabled && !model.originalTranscript.isEmpty,
                    onCopy: { model.copyTranscript() },
                    onCopyOriginal: { model.copyOriginalTranscript() },
                    onUndo: { model.undoInsert() },
                    onGrantAccessibility: { model.openAccessibilityPane() },
                    onClose: { model.closeTranscript() }
                )
                .frame(width: DictationHUDLayout.transcriptWidth)

            case .Error:
                DictationErrorView(
                    message: model.errorMessage,
                    onRetry: { model.retryRecording() },
                    onDismiss: { model.dismissTranscript() }
                )
                .frame(width: DictationErrorView.cardWidth)

            case .Preparing:
                DictationDownloadProgressView(
                    progress: model.downloadProgress,
                    speed: model.downloadSpeed,
                    remaining: model.downloadRemaining
                )
                .frame(width: 300)

            case .Idle, .Ready:
                if model.modelPhase == .Loading || model.modelPhase == .Unloading {
                    DictationReloadingView()
                        .frame(width: 300)
                } else {
                    DictationReadyView()
                        .frame(width: 240)
                }

            default:
                EmptyView()
            }
            }
        }
    }
}

// MARK: - Card chrome

private struct DictationCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(DictationHUDLayout.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(DictationCardPalette.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(DictationCardPalette.edge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
    }
}

// MARK: - Recording

struct DictationRecordingPillView: View {
    var audioLevel: Float = 0.2
    var livePreview: String = ""
    var livePreviewEnabled: Bool = false
    var isAction: Bool = false
    var isStarting = false
    var recordedSeconds: Double = 0
    var limitMinutes: Int = 5

    var body: some View {
        DictationCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: isAction ? "bolt" : "mic")
                        .font(.system(size: 11))
                    Text(isAction ? "COMMAND · LISTENING" : "DICTATION · RECORDING")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                    Spacer(minLength: 8)
                    Text(isStarting ? "STARTING" : "\(Int(recordedSeconds) / 60):\(String(format: "%02d", Int(recordedSeconds) % 60)) / \(limitMinutes):00")
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(DictationCardPalette.secondary)
                }
                .foregroundStyle(DictationCardPalette.accent)
                .frame(height: 18)

                NoirWaveform(level: audioLevel, active: !isStarting)

                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: isStarting ? "mic" : (isAction ? "bolt" : "lock"))
                            .font(.system(size: 9))
                        Text(isStarting ? "Opening microphone…" : (isAction ? "Say your command" : "Audio stays on this Mac"))
                            .font(.system(size: 10.5))
                    }
                    .foregroundStyle(DictationCardPalette.secondary)
                    Spacer(minLength: 8)
                    Text(isAction ? "⌘⇧A" : "⌘⇧D")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DictationCardPalette.muted)
                        .accessibilityLabel("Press the shortcut again to finish")
                    Button(isStarting ? "Cancel" : "Finish") {
                        if isAction {
                            DictationController.shared.toggleAction()
                        } else {
                            DictationController.shared.toggleDictation()
                        }
                    }
                    .buttonStyle(DictationControlStyle())
                    .help(isAction ? "Finish command (⌘⇧A)" : "Finish dictation (⌘⇧D)")
                }
            }
        }
        .frame(width: DictationHUDLayout.recordingSize.width, height: DictationHUDLayout.recordingSize.height)
    }
}

// MARK: - Transcribing

struct DictationTranscribingPillView: View {
    var isAction: Bool = false

    var body: some View {
        DictationCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: isAction ? "bolt" : "mic")
                        .font(.system(size: 11))
                    Text(isAction ? "COMMAND · WORKING" : "DICTATION · POLISHING")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                    Spacer(minLength: 8)
                }
                .foregroundStyle(DictationCardPalette.accent)

                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(DictationCardPalette.accent)
                    Text("Transcribing on this Mac…")
                        .font(.system(size: 12))
                        .foregroundStyle(DictationCardPalette.secondary)
                    Spacer(minLength: 8)
                }
            }
        }
        .frame(width: DictationHUDLayout.processingSize.width, height: DictationHUDLayout.processingSize.height)
    }
}

// MARK: - Transcript card

struct DictationTranscriptOverlayView: View {
    let transcript: String
    var original: String = ""
    var copied: Bool = false
    var inserted: Bool = false
    var formatting: Bool = false
    var insertNotice: String = ""
    var showCopyOriginal: Bool = false
    let onCopy: () -> Void
    var onCopyOriginal: () -> Void = {}
    var onUndo: () -> Void = {}
    var onGrantAccessibility: () -> Void = {}
    let onClose: () -> Void

    @State private var showRaw = false
    @State private var undoRequested = false
    @State private var copiedFlash = false

    private var canToggleOriginal: Bool { showCopyOriginal && !original.isEmpty }
    private var displayText: String { showRaw ? original : transcript }
    private var wordCount: Int { displayText.split(whereSeparator: \.isWhitespace).count }
    private var cardSize: CGSize {
        DictationHUDLayout.transcriptSize(transcript: transcript, original: original,
            showsOriginal: canToggleOriginal, notice: insertNotice)
    }

    var body: some View {
        DictationCard {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 12)

                ScrollView(.vertical, showsIndicators: true) {
                    Text(displayText)
                        .font(.system(size: 13))
                        .lineSpacing(5)
                        .foregroundStyle(DictationCardPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: DictationHUDLayout.textHeight(transcript: transcript, original: original,
                    showsOriginal: canToggleOriginal))

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 14)
                    .padding(.bottom, 12)

                HStack(spacing: 8) {
                    Button {
                        if showRaw { onCopyOriginal() } else { onCopy() }
                        copiedFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedFlash = false
                        }
                    } label: {
                        Label(copiedFlash ? "Copied" : "Copy text", systemImage: copiedFlash ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(DictationControlStyle(primary: true))

                    if canToggleOriginal {
                        Button { showRaw.toggle() } label: {
                            Label(showRaw ? "Polished" : "Original", systemImage: "clock.arrow.circlepath")
                        }
                        .buttonStyle(DictationControlStyle())
                        .help(showRaw ? "Show the polished text" : "Show the original transcript")
                    }

                    Spacer(minLength: 0)

                    if inserted {
                        Button {
                            undoRequested = true
                            onUndo()
                        } label: {
                            Label("Undo paste", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(DictationControlStyle())
                        .help("Undo the paste in the destination app; keep this transcript")
                    }
                }
                .frame(height: 32)

                HStack(spacing: 5) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 9))
                    Text(statusText)
                        .font(.system(size: 10))
                }
                .foregroundStyle(DictationCardPalette.secondary)
                .frame(height: 14, alignment: .leading)
                .padding(.top, 10)

                if !insertNotice.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10))
                            .padding(.top, 2)
                        Text(insertNotice)
                            .font(.system(size: 10.5))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Grant", action: onGrantAccessibility)
                            .buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(DictationCardPalette.accent)
                            .help("Open macOS Accessibility settings")
                    }
                    .foregroundStyle(DictationCardPalette.secondary)
                    .frame(height: DictationHUDLayout.noticeHeight(insertNotice), alignment: .topLeading)
                    .padding(.top, 10)
                }
            }
        }
        .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(DictationCardPalette.accent)
                .frame(width: 5, height: 5)
            Text(showRaw ? "ORIGINAL · DICTATION" : "READY · DICTATION")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(DictationCardPalette.accent)
            Spacer(minLength: 8)
            Text("\(wordCount) word\(wordCount == 1 ? "" : "s")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DictationCardPalette.secondary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DictationCardPalette.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close dictation result")
            .help("Close")
        }
        .frame(height: 22)
    }

    private var statusIcon: String {
        if formatting { return "ellipsis" }
        if undoRequested && !inserted { return "arrow.uturn.backward" }
        if copiedFlash || copied { return "doc.on.clipboard" }
        return inserted ? "checkmark" : "text.cursor"
    }

    private var statusText: String {
        if formatting { return "Polishing your transcript…" }
        if undoRequested && !inserted { return "Paste undone. Text is still available here." }
        if copiedFlash { return "Copied to the clipboard." }
        if inserted { return "Pasted at your cursor." }
        if copied { return "Copied to the clipboard. Ready to paste." }
        return "Ready to copy and paste where you need it."
    }
}

// MARK: - Compact HUD controls

private struct DictationControlStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(primary ? Color(hex: 0x22212E) : DictationCardPalette.secondary)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(primary ? DictationCardPalette.accent.opacity(configuration.isPressed ? 0.85 : 1)
                      : Color.white.opacity(configuration.isPressed ? 0.08 : 0.025)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(primary ? .clear : Color.white.opacity(0.09), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Waveform

struct NoirWaveform: View {
    var level: Float = 0.2
    var active: Bool = true
    var color: Color = DictationCardPalette.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let barCount = 64

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !active || reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let gain = active && level.isFinite ? sqrt(Double(min(1, max(0, level)))) : 0
                let barWidth: CGFloat = 2
                for index in 0..<barCount {
                    let position = Double(index) / Double(barCount - 1)
                    let envelope = 0.45 + 0.55 * sin(position * .pi)
                    let wave = 0.3 + 0.7 * abs(sin(time * 2.1 + Double(index) * 0.52))
                    let height = 3 + (size.height - 3) * gain * envelope * wave
                    let rect = CGRect(x: (size.width - barWidth) * position,
                                      y: (size.height - height) / 2, width: barWidth, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(active ? 0.9 : 0.35)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .accessibilityHidden(true)
    }
}

// MARK: - Ready / reloading / error / download

struct DictationReadyView: View {
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(DictationCardPalette.ok)
                .frame(width: 7, height: 7)
                .padding(.leading, 16)
            Text(DictationController.shared.mode == .action ? "Ready — say a command" : "Ready — speak")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DictationCardPalette.secondary)
            Spacer(minLength: 8)
        }
        .frame(width: 240, height: 44)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DictationCardPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(DictationCardPalette.edge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }
}

struct DictationReloadingView: View {
    var message = "Reloading model…"
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(DictationCardPalette.accent)
                .padding(.leading, 16)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(DictationCardPalette.secondary)
            Spacer(minLength: 8)
        }
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DictationCardPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(DictationCardPalette.edge, lineWidth: 1)
        )
    }
}

struct DictationErrorView: View {
    static let cardWidth: CGFloat = 360
    static func messageHeight(_ message: String) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        let bounds = (message as NSString).boundingRect(
            with: NSSize(width: cardWidth - 36, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph])
        return min(220, max(20, ceil(bounds.height) + 6))
    }
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(message)
                    .font(.system(size: 12))
                    .lineSpacing(4)
                    .foregroundStyle(DictationCardPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(height: Self.messageHeight(message))
            HStack(spacing: 8) {
                Button("Retry", action: onRetry)
                    .buttonStyle(NoirButtonStyle(intent: .primary, small: true))
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DictationCardPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(DictationCardPalette.edge, lineWidth: 1)
        )
    }
}

struct DictationDownloadProgressView: View {
    let progress: Float
    let speed: String
    let remaining: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Downloading the speech model…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DictationCardPalette.secondary)
            ProgressView(value: Double(progress))
                .progressViewStyle(.linear)
                .tint(DictationCardPalette.accent)
            if !speed.isEmpty {
                HStack {
                    Text(speed)
                    Spacer()
                    Text(remaining)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(DictationCardPalette.muted)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(DictationCardPalette.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(DictationCardPalette.edge, lineWidth: 1)
        )
    }
}

// MARK: - Palette

enum DictationCardPalette {
    static let text      = NoirPalette.text
    static let muted     = NoirPalette.muted
    static let secondary = NoirPalette.secondary
    static let accent    = NoirPalette.accent
    static let ok        = NoirPalette.green
    static let card      = Color(hex: 0x26262D)
    static let edge      = NoirPalette.accent.opacity(0.29)
}
