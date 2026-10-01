import SwiftUI

/// System pane — Display card + Safety card.
struct SystemPane: View {
    @ObservedObject var appState: AppState

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
        }
    }
}
