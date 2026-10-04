import AppKit
import SwiftUI

/// System pane — Display card + Safety card + Dictation settings/history.
struct SystemPane: View {
    @ObservedObject var appState: AppState
    /// Dictation settings + last-dictation pair live on the controller (the
    /// same object the ⌘⇧D card observes), so toggles here change card
    /// behavior live.
    @ObservedObject private var dictation = DictationController.shared

    private var refreshButton: some View {
        JRefreshButton(help: "Re-read the exact brightness/contrast from the display") {
            appState.refreshBrightness()
            appState.refreshContrast()
        }
    }

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                JLabel(text: "Display")
                Spacer(minLength: 0)
                refreshButton
            }

            JCard {
                JRow(title: "Brightness", first: true) {
                    JStepper(
                        value: "\(appState.currentBrightness)%",
                        onDown: { appState.decreaseBrightnessUI() },
                        onUp: { appState.increaseBrightnessUI() },
                        downDisabled: appState.currentBrightness <= 0,
                        upDisabled: appState.currentBrightness >= 100
                    )
                }
                JRow(title: "Contrast", sub: "External displays only") {
                    JStepper(
                        value: "\(appState.currentContrast)%",
                        onDown: { appState.decreaseContrastUI() },
                        onUp: { appState.increaseContrastUI() },
                        downDisabled: appState.currentContrast <= 0,
                        upDisabled: appState.currentContrast >= 100
                    )
                }
                JRow(title: "Profile") {
                    Text(appState.displayProfileName)
                        .font(JType.kv)
                        .foregroundStyle(JColor.ink3)
                }
            }
            .padding(.top, 9)

            JLabel(text: "Safety")
                .padding(.top, 22)

            JCard {
                JRow(title: "Destructive actions",
                     sub: "Always blocked, no override",
                     first: true) {
                    JChip(text: "Locked", kind: .danger)
                }
                JRow(title: "Privileged commands",
                     sub: "sudo is never permitted") {
                    JChip(text: "Locked", kind: .danger)
                }
                JRow(title: "Package installs",
                     sub: "Preview only") {
                    JChip(text: "Preview", kind: .warn)
                }
            }
            .padding(.top, 9)

            JLabel(text: "Dictation")
                .padding(.top, 22)

            JCard {
                JRow(title: "Auto-paste at cursor",
                     sub: "Type the formatted text into the active app",
                     first: true) {
                    JSwitch(binding: $dictation.insertAtCursorEnabled)
                }
                JRow(title: "Copy original",
                     sub: "Offer the raw transcript on the ⌘⇧D card") {
                    JSwitch(binding: $dictation.copyOriginalEnabled)
                }
            }
            .padding(.top, 9)

            JLabel(text: "Last dictation")
                .padding(.top, 22)

            JCard(flush: true) {
                VStack(spacing: 1) {
                    if dictation.lastPolished.isEmpty && dictation.lastOriginal.isEmpty {
                        Text("Nothing yet — press ⌘⇧D and speak.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(JColor.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                    } else {
                        lastDictationRow(title: "POLISHED", text: dictation.lastPolished)
                        if dictation.copyOriginalEnabled {
                            lastDictationRow(title: "ORIGINAL", text: dictation.lastOriginal)
                        }
                    }
                }
                .padding(.vertical, 5)
            }
            .padding(.top, 9)

            Text("Only the latest dictation is kept — a new one replaces both lines immediately.")
                .font(.system(size: 10.5))
                .foregroundStyle(JColor.ink4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 9)
        }
    }

    /// One side of the persisted last-dictation pair, with a copy button.
    private func lastDictationRow(title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(JColor.ink4)
                Text(text.isEmpty ? "—" : text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(JColor.ink2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                copyToPasteboard(text)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(JColor.ink3)
            .disabled(text.isEmpty)
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 8)
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
