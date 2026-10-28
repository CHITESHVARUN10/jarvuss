import AppKit

/// Fixed pane identifiers, never an arbitrary model-generated settings URL.
enum SystemSettingsPane: String, CaseIterable {
    case bluetooth, wifi, network, sound, displays, keyboard, mouse, trackpad, accessibility
    case privacy, microphone, battery, notifications, storage, softwareUpdate = "software_update", spotlight, general

    var url: URL {
        let destinations: [Self: String] = [
            .bluetooth: "com.apple.BluetoothSettings", .wifi: "com.apple.wifi-settings-extension",
            .network: "com.apple.Network-Settings.extension", .sound: "com.apple.Sound-Settings.extension",
            .displays: "com.apple.Displays-Settings.extension", .keyboard: "com.apple.Keyboard-Settings.extension",
            .mouse: "com.apple.Mouse-Settings.extension", .trackpad: "com.apple.Trackpad-Settings.extension",
            .accessibility: "com.apple.Accessibility-Settings.extension", .privacy: "com.apple.preference.security",
            .microphone: "com.apple.preference.security?Privacy_Microphone", .battery: "com.apple.Battery-Settings.extension",
            .notifications: "com.apple.Notifications-Settings.extension", .storage: "com.apple.settings.Storage",
            .softwareUpdate: "com.apple.Software-Update-Settings.extension", .spotlight: "com.apple.Spotlight-Settings.extension",
            .general: "com.apple.systempreferences.GeneralSettings",
        ]
        return URL(string: "x-apple.systempreferences:" + destinations[self]!)!
    }

    static func parse(_ text: String) -> Self? {
        guard let match = LocalSearchParser.captures(#"^(?:open|show|go to|take me to) (?:me )?(?:the )?(.+?) (?:settings|preferences|pane)$"#, text) else { return nil }
        let name = match[0].lowercased().replacingOccurrences(of: "wi-fi", with: "wifi")
        switch name {
        case "display", "brightness": return .displays
        case "audio", "volume": return .sound
        case "notification": return .notifications
        case "privacy and security", "privacy & security", "security": return .privacy
        case "software update", "updates": return .softwareUpdate
        default: return Self(rawValue: name)
        }
    }

    @MainActor func open() -> ControllerResult {
        if NSWorkspace.shared.open(url) { return ControllerResult(message: "Opening \(rawValue.replacingOccurrences(of: "_", with: " ")) settings.", success: true) }
        // Pane identifiers can change between macOS versions. Fall back to
        // System Settings and accurately report that the deep link failed.
        _ = NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:")!)
        return ControllerResult(message: "Opened System Settings, but this macOS version did not accept the requested pane.", success: false)
    }
}
