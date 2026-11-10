import SwiftUI
import AppKit

/// Dictation settings and the latest transcript belong beside speech recognition.
struct ObsidianDictationPreferences: View {
    @ObservedObject private var dictation = DictationController.shared
    @EnvironmentObject private var toasts: ToastCenter
    @Environment(\.obsidianWindowWidth) private var windowWidth
    @State private var showOriginal = false
    @State private var recordingOptions = false
    @State private var showFullTranscript = false

    var body: some View {
        let columns = windowWidth >= 1500
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 26))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        columns {
            preferences.frame(maxWidth: .infinity, alignment: .topLeading)
            latest.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Dictation preferences", trailing: AnyView(
                Button {
                    PillShortcutCoordinator.shared.press(.dictate)
                    toasts.show("Dictation is opening.")
                } label: { Label("Try dictation", systemImage: "mic") }
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
            ))
            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(title: "AI formatting", sub: "Optional local formatting after transcription. Off preserves your spoken wording.") {
                        NoirSwitch(isOn: $dictation.aiFormattingEnabled)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Paste at the cursor", sub: "Insert text into your active application.") {
                        NoirSwitch(isOn: $dictation.insertAtCursorEnabled)
                    }
                    NoirDivider()
                    NoirSettingRow(title: "Keep the original", sub: "Offer the raw transcript alongside the formatted result.") {
                        NoirSwitch(isOn: $dictation.copyOriginalEnabled)
                    }
                    NoirDivider()
                    DisclosureGroup("Recording & result panel", isExpanded: $recordingOptions) {
                        VStack(spacing: 0) {
                            NoirSettingRow(title: "Maximum recording time", sub: "Applies to the next recording, including command shortcuts.") {
                                Stepper(value: $dictation.recordingLimitMinutes, in: 1...60) {
                                    Text("\(dictation.recordingLimitMinutes) min").obsidianFont(size: 12, design: .monospaced)
                                }.frame(width: 126).accessibilityLabel("Maximum recording time in minutes")
                            }
                            NoirDivider()
                            NoirSettingRow(title: "Result stays visible", sub: "Automatic dismissal after transcription.") {
                                NoirSelect(options: (1...10).map { ($0, "\($0) s") }, selection: $dictation.cardDismissSeconds, width: 90)
                            }
                        }
                    }.obsidianFont(size: 12).tint(NoirPalette.accent).padding(18)
                }
            }
        }
    }

    private var latest: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoirSectionHeading(title: "Last dictation", trailing: AnyView(
                Text("Latest only").obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
            ))
            NoirCard(padded: true) {
                if dictation.lastPolished.isEmpty && dictation.lastOriginal.isEmpty {
                    Text("No dictation yet. Use Try dictation to get started.")
                        .obsidianFont(size: 12).foregroundStyle(NoirPalette.muted).padding(.vertical, 6)
                } else {
                    dictationBlock(label: "Formatted", text: dictation.lastPolished.isEmpty ? dictation.lastOriginal : dictation.lastPolished)
                    if dictation.copyOriginalEnabled && !dictation.lastOriginal.isEmpty {
                        NoirDivider().padding(.vertical, 16)
                        DisclosureGroup("Original transcript", isExpanded: $showOriginal) {
                            dictationBlock(label: "Original", text: dictation.lastOriginal, muted: true).padding(.top, 12)
                        }.obsidianFont(size: 11).tint(NoirPalette.accent).foregroundStyle(NoirPalette.muted)
                    }
                }
            }
            Text("Each new dictation replaces the previous one.").obsidianFont(size: 11).foregroundStyle(NoirPalette.muted).padding(.top, 14)
        }
        .onChange(of: dictation.lastOriginal) { _, _ in showOriginal = false }
        .onChange(of: dictation.lastPolished) { _, _ in showFullTranscript = false }
    }

    private func dictationBlock(label: String, text: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label).obsidianFont(size: 11, weight: .medium).foregroundStyle(NoirPalette.muted)
                Spacer(minLength: 8)
                NoirIconButton(icon: "doc.on.doc", help: "Copy \(label.lowercased()) text") {
                    NSPasteboard.general.clearContents()
                    let copied = NSPasteboard.general.setString(text, forType: .string)
                    toasts.show(copied ? "Copied \(label.lowercased()) text." : "Could not copy text.")
                }
            }
            Text(text).obsidianFont(size: 13).lineSpacing(5)
                .foregroundStyle(muted ? NoirPalette.muted : NoirPalette.secondary).textSelection(.enabled)
                .lineLimit(showFullTranscript ? nil : 8)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            if text.count > 500 {
                Button(showFullTranscript ? "Show less" : "Show full transcript") { showFullTranscript.toggle() }
                    .buttonStyle(.plain).obsidianFont(size: 11).foregroundStyle(NoirPalette.accent).padding(.top, 10)
            }
        }
    }
}
