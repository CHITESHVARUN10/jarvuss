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
                .frame(width: 330)

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

/// 300pt glass card: scrollable text + pinned Copy (and, once text has been
/// inserted, Undo) buttons. A failed insert carries the Accessibility notice
/// with a one-tap grant; a running LLM polish shows a spinner row.
/// Card height mirrors panelSizeForCurrentState in DictationController.
struct DictationTranscriptOverlayView: View {
    let transcript: String
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

    @State private var isExpanded = false
    @State private var showCheck = false
    @State private var originalCopied = false

    private var cardHeight: CGFloat {
        if !insertNotice.isEmpty { return 218 }
        if formatting { return 205 }
        return 170
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            transcriptScroll
            polishRow
            Divider()
                .overlay(.white.opacity(0.1))
            actionRow
            insertNoticeRow
        }
        .padding(18)
        .frame(width: 330, height: cardHeight)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .scaleEffect(isExpanded ? 1 : 0.9)
        .opacity(isExpanded ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                isExpanded = true
            }
        }
    }

    private var transcriptScroll: some View {
        ScrollView {
            Text(transcript)
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: insertNotice.isEmpty ? 96 : 66)
    }

    @ViewBuilder
    private var polishRow: some View {
        if formatting {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Polishing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 6) {
            copyButton
            if showCopyOriginal {
                copyOriginalButton
            }
            if inserted {
                undoButton
            }
            Spacer()
            closeButton
        }
    }

    @ViewBuilder
    private var insertNoticeRow: some View {
        if !insertNotice.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "lock.open")
                    .font(.system(size: 10, weight: .medium))
                Text(insertNotice)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: {
                    onGrantAccessibility()
                }) {
                    Text("Grant")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var copyButton: some View {
        Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                showCheck = true
            }
            onCopy()
        }) {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
                Text(copied ? "Copied" : "Copy")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.white.opacity(0.15))
            }
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .scaleEffect(showCheck ? 1.05 : 1.0)
    }

    /// Copies the raw STT text — what was actually said, before rules and
    /// before the polish pass. Stays open so the polished Copy is still live.
    private var copyOriginalButton: some View {
        Button(action: {
            originalCopied = true
            onCopyOriginal()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                originalCopied = false
            }
        }) {
            HStack(spacing: 5) {
                Image(systemName: originalCopied ? "checkmark" : "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                Text(originalCopied ? "Copied" : "Original")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help("Copy what you actually said, before formatting")
    }

    private var undoButton: some View {
        Button(action: onUndo) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .medium))
                Text("Undo")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            HStack(spacing: 5) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                Text("Close")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .foregroundStyle(.white.opacity(0.6))
        }
        .buttonStyle(.plain)
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
