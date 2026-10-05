import SwiftUI

// MARK: - HUD root

/// Dictation HUD content, hosted in a borderless NSPanel by DictationController.
/// Switches on the mirrored Rust phase: Recording → Transcribing →
/// transcript card. Glass pill language: 240×44, ultra-thin material,
//  0.5px white-12% border, soft shadow.
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
                // Reloading after an idle-unload: session phase may still read
                // Ready/Idle while the model itself is Loading/Unloading.
                if model.modelPhase == .Loading || model.modelPhase == .Unloading {
                    DictationReloadingView()
                        .frame(width: 300)
                } else {
                    // Panel exists but core is idle-ready (e.g. press landed
                    // while Ready, or start_recording was refused). Never a
                    // bare EmptyView — user must see *something*.
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

// MARK: - Recording pill

/// 240×44 glass pill: breathing red dot + live waveform + "Recording".
/// Grows a preview bubble above when live-preview text is showing.
struct DictationRecordingPillView: View {
    @State private var isVisible = false
    var audioLevel: Float = 0.2
    var livePreview: String = ""
    var livePreviewEnabled: Bool = false
    var isAction: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            if livePreviewEnabled && !livePreview.isEmpty {
                DictationLivePreviewBubble(text: livePreview)
            }

            pill
        }
        .frame(width: previewVisible ? 400 : 240)
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .scaleEffect(isVisible ? 1 : 0.85)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isVisible = true
            }
        }
    }

    private var previewVisible: Bool {
        livePreviewEnabled && !livePreview.isEmpty
    }

    private var pill: some View {
        HStack(spacing: 10) {
            DictationRecordingStatusDot(isAction: isAction)
                .padding(.leading, 14)

            Spacer(minLength: 2)

            PillWaveformView(audioLevel: audioLevel)
                .frame(height: 20)
                .frame(maxWidth: 110)

            Spacer(minLength: 2)

            Text(isAction ? "Listening" : "Recording")
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 14)
        }
        .frame(width: 240, height: 44)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .compositingGroup()
    }
}

/// Glass bubble above the pill showing the live transcript so far.
private struct DictationLivePreviewBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(.white.opacity(0.75))
            .lineLimit(3)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 400, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.white.opacity(0.12), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .compositingGroup()
            .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

/// 8px status dot with soft glow and breathing pulse.
/// Red for dictate (⌘⇧D), indigo for action (⌘⇧A) — same glass, own color.
private struct DictationRecordingStatusDot: View {
    @State private var isPulsing = false
    var isAction: Bool = false

    private var dotColor: Color {
        isAction ? Color(red: 0.45, green: 0.50, blue: 1.0)
                 : Color(red: 0.73, green: 0.10, blue: 0.10)
    }

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .shadow(color: dotColor.opacity(0.6), radius: 6)
            .opacity(isPulsing ? 0.55 : 1.0)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.6)
                    .repeatForever(autoreverses: true)
                ) {
                    isPulsing = true
                }
            }
    }
}

// MARK: - Transcribing pill

/// Same 240×44 glass, spinner + dimmed waveform + "Transcribing".
struct DictationTranscribingPillView: View {
    @State private var isVisible = false
    var isAction: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.5))
                .padding(.leading, 14)

            Spacer(minLength: 2)

            PillWaveformView(audioLevel: 0.0)
                .frame(height: 20)
                .frame(maxWidth: 110)
                .opacity(0.5)

            Spacer(minLength: 2)

            Text((isAction ? "Working" : "Transcribing"))
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 14)
        }
        .frame(width: 240, height: 44)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .scaleEffect(isVisible ? 1 : 0.85)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isVisible = true
            }
        }
    }
}

// MARK: - Transcript card

/// Glass result card, styled after the dictation-card mockup: 26pt radius,
/// material + dark tint, top gloss, mono tag/meta header, serif transcript,
/// and a four-slot action bar (Copy / Original / Undo / Close).
/// Card height mirrors panelSizeForCurrentState in DictationController.
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
    static let baseHeight: CGFloat = 250
    static let noticeHeight: CGFloat = 298
    static let cardWidth: CGFloat = 400

    @State private var appeared = false
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
        if undone { return "Undone" }
        return showRaw ? "Original" : "Polished"
    }

    private var metaText: String {
        if undone { return "nothing pasted" }
        if formatting { return "polishing…" }
        let words = "\(wordCount) word\(wordCount == 1 ? "" : "s")"
        let state = inserted ? "pasted" : (copied ? "copied" : "")
        return state.isEmpty ? words : "\(words) · \(state)"
    }

    private var cardHeight: CGFloat {
        insertNotice.isEmpty ? Self.baseHeight : Self.noticeHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            transcriptScroll
            Divider()
                .overlay(DictationCardPalette.hairline)
                .padding(.bottom, 10)
            actionBar
            insertNoticeRow
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 14, trailing: 22))
        .frame(width: Self.cardWidth, height: cardHeight, alignment: .top)
        .background(cardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(DictationCardPalette.edge, lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 26))
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
        .scaleEffect(appeared ? 1 : 0.97)
        .offset(y: appeared ? 0 : 14)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.9, 0.3, 1, duration: 0.45)) {
                appeared = true
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(DictationCardPalette.accent)
                .frame(width: 7, height: 7)
                .shadow(color: DictationCardPalette.accent.opacity(0.85), radius: 5)

            Text(tagText)
                .font(JarvisFonts.mono(11))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(DictationCardPalette.muted)

            Spacer(minLength: 8)

            Text(metaText)
                .font(JarvisFonts.mono(11))
                .foregroundStyle(DictationCardPalette.muted)
        }
        .padding(.bottom, 12)
    }

    // MARK: Transcript

    private var transcriptScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(displayText)
                .font(JarvisFonts.serif(30))
                .foregroundStyle(undone ? DictationCardPalette.muted : DictationCardPalette.text)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .frame(minHeight: 92, maxHeight: 150)
        .animation(.easeInOut(duration: 0.16), value: displayText)
        .padding(.bottom, 14)
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: 4) {
            CardActionButton(
                icon: copiedFlash ? "checkmark" : "doc.on.doc",
                label: copiedFlash ? "Copied" : "Copy",
                primary: true,
                done: copiedFlash,
                disabled: undone
            ) {
                if showRaw {
                    onCopyOriginal()
                } else {
                    onCopy()
                }
                copiedFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    copiedFlash = false
                }
            }

            if canToggleOriginal {
                CardActionButton(
                    icon: "clock.arrow.circlepath",
                    label: showRaw ? "Polished" : "Original",
                    disabled: undone
                ) {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showRaw.toggle()
                    }
                }
                .help("Show what you actually said, before formatting")
            }

            CardActionButton(icon: "arrow.uturn.backward", label: "Undo", disabled: undone) {
                undone = true
                onUndo()
            }

            CardActionButton(icon: "xmark", label: "Close") {
                onClose()
            }
        }
    }

    @ViewBuilder
    private var insertNoticeRow: some View {
        if !insertNotice.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.open")
                    .font(.system(size: 10, weight: .medium))
                Text(insertNotice)
                    .font(JarvisFonts.sans(11))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onGrantAccessibility) {
                    Text("Grant")
                        .font(JarvisFonts.sans(11, weight: .semibold))
                        .foregroundStyle(DictationCardPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(DictationCardPalette.muted)
            .padding(.top, 12)
        }
    }

    private var cardBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 26)
                .fill(DictationCardPalette.cardTint.opacity(0.45))
            RoundedRectangle(cornerRadius: 26)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.10), .clear],
                        startPoint: .topLeading,
                        endPoint: .center))
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Mockup palette (dark) — the HTML design tokens 1:1.
enum DictationCardPalette {
    static let text     = Color(red: 0.949, green: 0.953, blue: 0.965)  // #F2F3F6
    static let muted    = Color(red: 0.604, green: 0.624, blue: 0.682)  // #9A9FAE
    static let accent   = Color(red: 0.561, green: 0.890, blue: 0.839)  // #8FE3D6
    static let ok       = Color(red: 0.498, green: 0.863, blue: 0.745)  // #7FDCBE
    static let ink      = Color(red: 0.031, green: 0.035, blue: 0.047)  // #08090C
    static let cardTint = Color(red: 0.118, green: 0.125, blue: 0.157)  // #1E2028
    static let edge     = Color.white.opacity(0.14)
    static let hairline = Color.white.opacity(0.09)
    static let hover    = Color.white.opacity(0.08)
}

/// One slot of the four-button bar: equal width, 13pt radius, hover fill,
/// filled/ink treatment for the primary Copy action, green when done.
private struct CardActionButton: View {
    let icon: String
    let label: String
    var primary: Bool = false
    var done: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                Text(label)
                    .font(JarvisFonts.sans(13, weight: primary ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background {
                RoundedRectangle(cornerRadius: 13)
                    .fill(background)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .onHover { inside in
            hovering = inside && !disabled
        }
    }

    private var foreground: Color {
        if primary { return DictationCardPalette.ink }
        if done { return DictationCardPalette.ok }
        return DictationCardPalette.muted
    }

    private var background: Color {
        if primary { return hovering ? Color.white.opacity(0.92) : DictationCardPalette.text }
        return hovering ? DictationCardPalette.hover : .clear
    }
}

// MARK: - Error / Download / Reload / Ready states

/// Shown when the panel exists but the core is idle-ready — e.g. the press
/// landed while Ready, or start_recording was refused. Guarantees the user
/// always sees *something* instead of a transparent 240×44 window.
struct DictationReadyView: View {
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(red: 0.35, green: 0.90, blue: 0.65))
                .frame(width: 8, height: 8)
                .padding(.leading, 14)
            Spacer(minLength: 2)
            Text(DictationController.shared.mode == .action ? "Ready — say a command" : "Ready — speak")
                .font(.system(size: 11, weight: .medium, design: .default))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.trailing, 14)
        }
        .frame(width: 240, height: 44)
        .background {
            RoundedRectangle(cornerRadius: 22)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .scaleEffect(isVisible ? 1 : 0.85)
        .opacity(isVisible ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isVisible = true
            }
        }
    }
}

/// Shown when the model is reloading after an idle-unload (5 min rule):
/// first use pays a multi-second mmap + warmup, and the pill must say so
/// instead of hanging on "Transcribing" or rendering nothing.
struct DictationReloadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.5))
                .padding(.leading, 14)
            Text("Reloading model…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.trailing, 14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }
}

struct DictationErrorView: View {
    let message: String
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.8))
            HStack {
                Button("Retry", action: onRetry)
                Spacer()
                Button("Dismiss", action: onDismiss)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }
}

struct DictationDownloadProgressView: View {
    let progress: Float
    let speed: String
    let remaining: String

    var body: some View {
        VStack(spacing: 10) {
            Text("Downloading Whisper model...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            ProgressView(value: Double(progress))
                .progressViewStyle(.linear)
            if !speed.isEmpty {
                HStack {
                    Text(speed)
                    Spacer()
                    Text(remaining)
                }
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
    }
}
