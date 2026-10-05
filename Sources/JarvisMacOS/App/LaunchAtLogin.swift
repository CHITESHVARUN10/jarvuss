import Foundation
import ServiceManagement

/// "Start at login" backed by `SMAppService.mainApp` (macOS 13+).
///
/// The system is the source of truth: every change is followed by a status
/// re-read, so the toggle can never disagree with what macOS will actually
/// do. Registration only sticks for a bundled, signed copy of the app —
/// a bare `swift run` binary surfaces the error instead of pretending.
@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    /// True when macOS wants the user to allow the item manually
    /// (System Settings → General → Login Items).
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorText: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        errorText = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorText = "\(error.localizedDescription) — use the packaged app (scripts/package_jarvis_app.zsh)."
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
