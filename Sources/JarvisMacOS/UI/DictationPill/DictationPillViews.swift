import SwiftUI

// MARK: - HUD root

/// Dictation HUD content, hosted in a borderless NSPanel by DictationController.
/// Noir language: graphite card, lavender hairline, flat controls.
struct DictationHUDView: View {
    @ObservedObject private var model = DictationController.shared

    private var isAction: Bool { model.mode == .action }

    var body: some View {
        Group {
            switch model.phase {
            case .Recording:
                DictationRecordingPillView(
                    audioLevel: model.audioLevel,
                    livePreview: model.partialTranscript,
                    livePreviewEnabled: model.livePreviewEnabled,
                    isAction: isAction
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
                .frame(width: DictationTranscriptOverlayView.cardWidth)

            case .Error:
                DictationErrorView(
                    message: model.errorMessage,
                    onRetry: { model.retryRecording() },
                    onDismiss: { model.dismissTranscript() }
                )
                .frame(width: 300)

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
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.phase)
    }
}

// MARK: - Card chrome

private struct DictationCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
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

    var body: some View {
        DictationCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: isAction ? "bolt" : "mic")
                        .font(.system(size: 11))
                    Text(isAction ? "COMMAND · LISTENING" : "DICTATION · RECORDING")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.5)
                    Spacer(minLength: 8)
                    Text("LIVE")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(DictationCardPalette.muted)
                }
                .foregroundStyle(DictationCardPalette.accent)

                NoirWaveform(level: audioLevel, active: true)

                HStack(spacing: 8) {
                    Text(isAction ? "Listening for your command…" : "Listening… audio stays on this Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(DictationCardPalette.muted)
                    Spacer(minLength: 8)
                    Button("Finish") {
                        if isAction {
                            DictationController.shared.toggleAction()
                        } else {
                            DictationController.shared.toggleDictation()
                        }
                    }
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                }
            }
        }
        .frame(width: 370, height: 150)
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
        .frame(width: 370, height: 105)
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

    /// Keep in sync with DictationController.panelSizeForCurrentState.
    static let baseHeight: CGFloat = 300
    static let noticeHeight: CGFloat = 350
    static let cardWidth: CGFloat = 370

    @State private var showRaw = false
    @State private var undone = false
    @State private var copiedFlash = false

    private var canToggleOriginal: Bool { showCopyOriginal && !original.isEmpty }

    private var displayText: String {
        if undone { return "Dictation removed from the app." }
        return showRaw ? original : transcript
    }

    private var wordCount: Int {
        displayText.split(whereSeparator: \.isWhitespace).count
    }

    private var tagText: String {
        if undone { return "UNDONE · DICTATION" }
        return showRaw ? "ORIGINAL · DICTATION" : "READY · DICTATION"
    }

    private var metaText: String {
        if formatting { return "polishing…" }
        let words = "\(wordCount) word\(wordCount == 1 ? "" : "s")"
        if inserted { return "\(words) · pasted" }
        if copied { return "\(words) · copied" }
        return words
    }

    private var cardHeight: CGFloat {
        insertNotice.isEmpty ? Self.baseHeight : Self.noticeHeight
    }

    var body: some View {
        DictationCard {
            VStack(alignment: .leading, spacing: 0) {
                header

                ScrollView(.vertical, showsIndicators: false) {
                    Text(displayText)
                        .font(.system(size: 13))
                        .lineSpacing(6)
                        .foregroundStyle(undone ? DictationCardPalette.muted : DictationCardPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)

                HStack(spacing: 6) {
                    Button {
                        if showRaw { onCopyOriginal() } else { onCopy() }
                        copiedFlash = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            copiedFlash = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: copiedFlash ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text(copiedFlash ? "Copied" : "Copy text")
                        }
                    }
                    .buttonStyle(NoirButtonStyle(intent: .primary, small: true))
                    .disabled(undone)

                    if canToggleOriginal {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showRaw.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 11))
                                Text(showRaw ? "Polished" : "Original")
                            }
                        }
                        .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                        .disabled(undone)
                    }

                    Button {
                        undone = true
                        onUndo()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11))
                            Text("Undo")
                        }
                    }
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    .disabled(undone)

                    Spacer(minLength: 0)
                }
                .padding(.top, 14)

                footer
            }
        }
        .frame(width: Self.cardWidth, height: cardHeight, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(undone ? DictationCardPalette.muted : DictationCardPalette.accent)
                .frame(width: 6, height: 6)

            Text(tagText)
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(undone ? DictationCardPalette.muted : DictationCardPalette.accent)

            Spacer(minLength: 8)

            Text(metaText)
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(DictationCardPalette.muted)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DictationCardPalette.muted)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !insertNotice.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open")
                        .font(.system(size: 9, weight: .medium))
                    Text(insertNotice)
                        .font(.system(size: 10.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Grant", action: onGrantAccessibility)
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DictationCardPalette.accent)
                }
                .foregroundStyle(DictationCardPalette.muted)
            }

            Text(footerText)
                .font(.system(size: 10))
                .foregroundStyle(DictationCardPalette.muted)
        }
        .padding(.top, 12)
    }

    private var footerText: String {
        if inserted { return "Pasted at your cursor." }
        if copiedFlash { return "Copied to the clipboard." }
        return "Copy the text, then paste where you need it."
    }
}

// MARK: - Waveform

struct NoirWaveform: View {
    var level: Float = 0.2
    var active: Bool = true
    var color: Color = DictationCardPalette.accent
    private let barCount = 36

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.06)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    let wave = abs(sin(t * 2.1 + Double(index) * 0.52))
                    let levelBump = Double(level) * 20 * abs(sin(t * 1.5 + Double(index) * 0.27))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .frame(width: 2, height: max(4, min(38, 9 + wave * 16 + levelBump)))
                }
            }
            .frame(height: 42)
            .opacity(active ? 1 : 0.35)
        }
        .frame(height: 42)
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
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(DictationCardPalette.accent)
                .padding(.leading, 16)
            Text("Reloading model…")
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
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(DictationCardPalette.secondary)
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
