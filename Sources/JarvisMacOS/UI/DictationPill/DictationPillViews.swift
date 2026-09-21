import SwiftUI

// MARK: - HUD root

/// Dictation HUD content, hosted in a borderless NSPanel by DictationController.
/// Switches on the mirrored Rust phase: Recording → Transcribing →
/// transcript card. Glass pill language: 240×44, ultra-thin material,
//  0.5px white-12% border, soft shadow.
struct DictationHUDView: View {
    @ObservedObject private var model = DictationController.shared

    var body: some View {
        Group {
            switch model.phase {
            case .Recording:
                DictationRecordingPillView(
                    audioLevel: model.audioLevel,
                    livePreview: model.partialTranscript,
                    livePreviewEnabled: model.livePreviewEnabled
                )

            case .Processing:
                DictationTranscribingPillView()

            case .TranscriptReady:
                DictationTranscriptOverlayView(
                    transcript: model.transcript,
                    copied: model.copied,
                    onCopy: { model.copyTranscript() },
                    onClose: { model.closeTranscript() }
                )
                .frame(width: 300)

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
            DictationRecordingStatusDot()
                .padding(.leading, 14)

            Spacer(minLength: 2)

            PillWaveformView(audioLevel: audioLevel)
                .frame(height: 20)
                .frame(maxWidth: 110)

            Spacer(minLength: 2)

            Text("Recording")
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

/// 8px red status dot with soft glow and breathing pulse.
private struct DictationRecordingStatusDot: View {
    @State private var isPulsing = false

    private let dotColor = Color(red: 0.73, green: 0.10, blue: 0.10)

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

            Text("Transcribing")
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

/// 300×170 glass card: scrollable text + pinned Copy/Close buttons.
/// Copy flips to a checkmark; the controller auto-dismisses after 0.6 s.
struct DictationTranscriptOverlayView: View {
    let transcript: String
    var copied: Bool = false
    let onCopy: () -> Void
    let onClose: () -> Void

    @State private var isExpanded = false
    @State private var showCheck = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                Text(transcript)
                    .font(.system(size: 14, weight: .regular, design: .default))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 96)

            Divider()
                .overlay(.white.opacity(0.1))

            HStack(spacing: 8) {
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.white.opacity(0.15))
                    }
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .scaleEffect(showCheck ? 1.05 : 1.0)

                Spacer()

                Button(action: onClose) {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                        Text("Close")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 300, height: 170)
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
}

// MARK: - Error / Download states

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
