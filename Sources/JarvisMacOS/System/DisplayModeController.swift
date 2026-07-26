import Foundation
import CoreGraphics

// MARK: - DisplayModeController

/// Enumerates and switches display modes (resolution + refresh rate) using
/// fully public Core Graphics APIs.
///
/// ✅ API Stability: CGDisplayCopyAllDisplayModes and CGDisplaySetDisplayMode
/// are public, documented, and stable. No private APIs used here.
final class DisplayModeController {

    var onLog: ((String) -> Void)?

    // MARK: - DisplayMode

    struct DisplayMode: CustomStringConvertible {
        let cgMode: CGDisplayMode
        let width: Int
        let height: Int
        let refreshRate: Double
        let pixelWidth: Int    // physical pixels (for HiDPI detection)
        let pixelHeight: Int

        /// True if this is a HiDPI / Retina mode (pixel count > logical count).
        var isHiDPI: Bool { pixelWidth > width || pixelHeight > height }

        var description: String {
            let hdpi = isHiDPI ? " (HiDPI)" : ""
            let hz   = refreshRate > 0 ? " @\(Int(refreshRate))Hz" : ""
            return "\(width)×\(height)\(hz)\(hdpi)"
        }
    }

    // MARK: - Display enumeration

    /// All currently connected display IDs (built-in + external).
    static func connectedDisplayIDs() -> [CGDirectDisplayID] {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &displays, &count)
        return Array(displays.prefix(Int(count)))
    }

    /// The primary display ID.
    static func mainDisplayID() -> CGDirectDisplayID {
        CGMainDisplayID()
    }

    // MARK: - Mode enumeration

    /// Returns all available display modes for a given display.
    func availableModes(for displayID: CGDirectDisplayID) -> [DisplayMode] {
        // Include duplicate low-resolution modes so the user can explicitly
        // ask for non-HiDPI variants.
        let options: CFDictionary = [
            kCGDisplayShowDuplicateLowResolutionModes as String: true
        ] as CFDictionary

        guard let cgModes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            emit("[Resolution] Failed to enumerate modes for display \(displayID)")
            return []
        }

        return cgModes.map { mode in
            DisplayMode(
                cgMode:      mode,
                width:       mode.width,
                height:      mode.height,
                refreshRate: mode.refreshRate,
                pixelWidth:  mode.pixelWidth,
                pixelHeight: mode.pixelHeight
            )
        }
        .sorted { a, b in
            if a.width != b.width  { return a.width  > b.width  }
            if a.height != b.height { return a.height > b.height }
            return a.refreshRate > b.refreshRate
        }
    }

    /// Returns the currently active display mode.
    func currentMode(for displayID: CGDirectDisplayID) -> DisplayMode? {
        guard let cgMode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return DisplayMode(
            cgMode:      cgMode,
            width:       cgMode.width,
            height:      cgMode.height,
            refreshRate: cgMode.refreshRate,
            pixelWidth:  cgMode.pixelWidth,
            pixelHeight: cgMode.pixelHeight
        )
    }

    // MARK: - Mode switching

    /// Switches the display to the closest matching mode.
    /// Matching priority: width → height → refreshRate (exact or closest).
    /// Returns a human-readable result string.
    @discardableResult
    func setMode(
        displayID: CGDirectDisplayID,
        width: Int,
        height: Int,
        refreshRate: Double? = nil
    ) -> String {
        let modes = availableModes(for: displayID)
        guard !modes.isEmpty else {
            return "No display modes available for display \(displayID)"
        }

        // Score-based matching: prefer exact width/height, then closest refresh.
        let candidates = modes.filter { $0.width == width && $0.height == height }
        if candidates.isEmpty {
            let available = modes.map { $0.description }.prefix(5).joined(separator: ", ")
            return "No mode matching \(width)×\(height) found. Available: \(available)…"
        }

        // Among matching width×height, pick by refresh rate preference.
        let best: DisplayMode
        if let targetHz = refreshRate {
            best = candidates.min(by: { abs($0.refreshRate - targetHz) < abs($1.refreshRate - targetHz) })
                ?? candidates[0]
        } else {
            // Prefer HiDPI if available, then highest refresh rate.
            best = candidates.sorted { a, b in
                if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
                return a.refreshRate > b.refreshRate
            }.first ?? candidates[0]
        }

        emit("[Resolution] Applying mode: \(best)")

        // CGDisplaySetDisplayMode requires a CGDisplayConfigRef transaction.
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else {
            return "Failed to begin display configuration"
        }

        let configResult = CGConfigureDisplayWithDisplayMode(config, displayID, best.cgMode, nil)
        guard configResult == .success else {
            CGCancelDisplayConfiguration(config)
            return "Failed to configure display mode (CGError \(configResult.rawValue))"
        }

        let applyResult = CGCompleteDisplayConfiguration(config, .forSession)
        if applyResult == .success {
            let msg = "Resolution changed to \(best)"
            emit("[Resolution] \(msg)")
            return msg
        } else {
            CGCancelDisplayConfiguration(config)
            return "Failed to apply display mode (CGError \(applyResult.rawValue))"
        }
    }

    // MARK: - List helper

    /// Returns a formatted list of modes for voice/text display.
    func listModes(for displayID: CGDirectDisplayID) -> String {
        let modes = availableModes(for: displayID)
        if modes.isEmpty { return "No display modes available" }
        let lines = modes.prefix(8).map { "  • \($0)" }.joined(separator: "\n")
        return "Available modes:\n\(lines)"
    }

    // MARK: - Resolution from voice keywords

    /// Maps common voice shorthand (e.g. "1080p", "4k") to width × height.
    static func resolveShorthand(_ input: String) -> (width: Int, height: Int)? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)
        switch lower {
        case "4k", "uhd", "2160p":          return (3840, 2160)
        case "1440p", "qhd", "2k":          return (2560, 1440)
        case "1080p", "fhd", "full hd":     return (1920, 1080)
        case "720p", "hd":                  return (1280, 720)
        case "1080":                        return (1920, 1080)
        case "1440":                        return (2560, 1440)
        case "2160":                        return (3840, 2160)
        default:                            return nil
        }
    }

    // MARK: - Helpers

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
