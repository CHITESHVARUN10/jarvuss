import SwiftUI
import AppKit

// MARK: - System & dictation

struct NoirSystemPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var dictation = DictationController.shared
    @ObservedObject private var recovery = DisplayRecovery.shared
    @EnvironmentObject private var toasts: ToastCenter

    @State private var brightness: Double = 65
    @State private var contrast: Double = 50
    @State private var editingBrightness = false
    @State private var editingContrast = false

    var body: some View {
        NoirPage(
            eyebrow: "The details that make it yours",
            title: "A comfortable workspace.",
            sub: "Fine-tune your display, dictation, and command safeguards."
        ) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    NoirSectionHeading(
                        title: "Display",
                        trailing: AnyView(
                            NoirIconButton(icon: "arrow.clockwise", help: "Refresh display values") {
                                appState.refreshBrightness()
                                appState.refreshContrast()
                                syncDisplayValues()
                            }
                        ),
                        minHeight: 30
                    )

                    NoirCard {
                        VStack(spacing: 0) {
                            NoirSettingRow(title: "Brightness") {
                                displayControl(value: $brightness, editing: $editingBrightness) {
                                    appState.setBrightnessUI(Int(brightness.rounded()))
                                }
                            }
                            NoirDivider()
                            NoirSettingRow(title: "Contrast", sub: "External displays only.") {
                                displayControl(value: $contrast, editing: $editingContrast) {
                                    appState.setContrastUI(Int(contrast.rounded()))
                                }
                            }
                            NoirDivider()
                            NoirSettingRow(title: "Display profile") {
                                Text(appState.displayProfileName)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(NoirPalette.secondary)
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    NoirSectionHeading(title: "Command safeguards", minHeight: 30)
                    NoirCard {
                        VStack(spacing: 0) {
                            NoirSettingRow(title: "Destructive actions", sub: "Always blocked.") {
                                NoirTag(text: "Locked", kind: .red, icon: "lock")
                            }
                            NoirDivider()
                            NoirSettingRow(title: "Privileged commands", sub: "sudo is never permitted.") {
                                NoirTag(text: "Locked", kind: .red, icon: "lock")
                            }
                            NoirDivider()
                            NoirSettingRow(title: "Package installs", sub: "Installation is never executed.") {
                                NoirTag(text: "Preview only", kind: .amber)
                            }
                        }
                    }
                }
            }

            NoirSectionHeading(title: "Display safety")
            NoirCard(padded: true) {
                Text("Jarvis keeps brightness at 10% or higher, contrast at 20% or higher, and software dimming above zero.")
                    .font(.system(size: 12))
                    .foregroundStyle(NoirPalette.secondary)
                Text("If the screen becomes unreadable, press ⌘⇧R. Or press ⌘⇧A, say ‘Restore my display’, then press ⌘⇧A again to finish. Recovery bypasses verification only for this exact, safe action.")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Text("Requests 60% brightness, 50% external contrast and normal software brightness using macOS and supported display controls. BetterDisplay is optional. If you use it, keep its notification integration enabled to release its dimming; software image adjustments are suspended until you re-enable them in BetterDisplay. Jarvis must be running.")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                Button(recovery.isRestoring ? "Restoring…" : "Restore display visibility") { recovery.restore() }
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    .disabled(recovery.isRestoring)
                    .padding(.top, 12)
                if !recovery.shortcutRegistered {
                    Text("⌘⇧R is unavailable. Another app may already use it; the button and voice phrase still work.")
                        .font(.system(size: 11)).foregroundStyle(NoirPalette.orange).padding(.top, 8)
                }
                if !recovery.status.isEmpty {
                    Text(recovery.status).font(.system(size: 11)).foregroundStyle(NoirPalette.secondary).padding(.top, 8)
                }
            }

            NoirSectionHeading(
                title: "Dictation",
                trailing: AnyView(
                    Button {
                        PillShortcutCoordinator.shared.press(.dictate)
                        toasts.show("Dictation is opening.")
                    } label: {
                        Label("Try dictation", systemImage: "mic")
                    }
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                )
            )

            NoirCard {
                VStack(spacing: 0) {
                    NoirSettingRow(
                        title: "Paste at the cursor",
                        sub: "Insert formatted text directly into your active application."
                    ) {
                        NoirSwitch(isOn: $dictation.insertAtCursorEnabled)
                    }
                    NoirDivider()
                    NoirSettingRow(
                        title: "Keep the original",
                        sub: "Offer the unformatted transcript alongside the polished result."
                    ) {
                        NoirSwitch(isOn: $dictation.copyOriginalEnabled)
                    }
                    NoirDivider()
                    NoirSettingRow(
                        title: "Maximum recording time",
                        sub: "1–60 minutes for dictation and shortcut commands. Applies to the next recording."
                    ) {
                        Stepper(value: $dictation.recordingLimitMinutes, in: 1...60) {
                            Text("\(dictation.recordingLimitMinutes) min")
                                .font(.system(size: 12, design: .monospaced))
                        }
                        .frame(width: 126)
                        .accessibilityLabel("Maximum recording time in minutes")
                    }
                    NoirDivider()
                    NoirSettingRow(
                        title: "Card stays visible",
                        sub: "How long the floating card stays after transcription."
                    ) {
                        NoirSelect(
                            options: (1...10).map { ($0, "\($0) s") },
                            selection: $dictation.cardDismissSeconds,
                            width: 90
                        )
                    }
                }
            }

            NoirSectionHeading(
                title: "Last dictation",
                trailing: AnyView(
                    Text("Latest only")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(NoirPalette.muted)
                )
            )

            NoirCard(padded: true) {
                if dictation.lastPolished.isEmpty && dictation.lastOriginal.isEmpty {
                    Text("No dictation yet. Try the button above.")
                        .font(.system(size: 12))
                        .foregroundStyle(NoirPalette.muted)
                        .padding(.vertical, 6)
                } else {
                    dictationBlock(
                        label: "Polished",
                        text: dictation.lastPolished.isEmpty ? "—" : dictation.lastPolished
                    )

                    if dictation.copyOriginalEnabled {
                        NoirDivider().padding(.vertical, 16)
                        dictationBlock(
                            label: "Original",
                            text: dictation.lastOriginal.isEmpty ? "—" : dictation.lastOriginal,
                            muted: true
                        )
                    }
                }
            }

            Text("Each new dictation replaces the previous one.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 14)
        }
        .onAppear {
            syncDisplayValues()
        }
        .onChange(of: appState.currentBrightness) { _, value in
            if !editingBrightness { brightness = Double(value) }
        }
        .onChange(of: appState.currentContrast) { _, value in
            if !editingContrast { contrast = Double(value) }
        }
    }

    private func displayControl(
        value: Binding<Double>,
        editing: Binding<Bool>,
        onCommit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            NoirSlider(
                value: value,
                onEditingChanged: { editing.wrappedValue = $0 },
                onCommit: onCommit
            )
            .frame(width: 118)

            Text("\(Int(value.wrappedValue.rounded()))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NoirPalette.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .frame(width: 170)
    }

    private func syncDisplayValues() {
        brightness = Double(appState.currentBrightness)
        contrast = Double(appState.currentContrast)
    }

    private struct NoirSlider: View {
        @Binding var value: Double
        let onEditingChanged: (Bool) -> Void
        let onCommit: () -> Void

        var body: some View {
            GeometryReader { proxy in
                let fraction = min(max(value / 100, 0), 1)
                let width = proxy.size.width

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 3)
                    Capsule(style: .continuous)
                        .fill(NoirPalette.accent)
                        .frame(width: max(0, width * fraction), height: 3)
                    Circle()
                        .fill(NoirPalette.text)
                        .frame(width: 13, height: 13)
                        .overlay(
                            Circle().strokeBorder(NoirPalette.base.opacity(0.5), lineWidth: 1)
                        )
                        .offset(x: max(0, min(width - 13, width * fraction - 6.5)))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            onEditingChanged(true)
                            let raw = min(max(drag.location.x / width, 0), 1)
                            value = (raw * 100).rounded()
                        }
                        .onEnded { _ in
                            onEditingChanged(false)
                            onCommit()
                        }
                )
            }
            .frame(height: 20)
            .accessibilityElement()
            .accessibilityLabel("Slider")
            .accessibilityValue("\(Int(value.rounded())) percent")
        }
    }

    private func dictationBlock(label: String, text: String, muted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.6)
                    .foregroundStyle(NoirPalette.muted)
                Spacer(minLength: 8)
                NoirIconButton(icon: "doc.on.doc", help: "Copy \(label.lowercased()) text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    toasts.show("Copied \(label.lowercased()) text.")
                }
            }
            Text(text)
                .font(.system(size: 12))
                .lineSpacing(5)
                .foregroundStyle(muted ? NoirPalette.muted : NoirPalette.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
    }
}
