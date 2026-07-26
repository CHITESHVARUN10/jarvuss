import Foundation
import CoreGraphics

/// Combines Hardware DDC Backlight (VCP 0x10), Hardware Contrast (VCP 0x12),
/// and Software GPU Gamma Scaling (`SoftwareDimmingController`) into a seamless
/// 0% - 100% combined brightness spectrum.
///
/// Scale:
/// - 0%   = Pitch Black (Software Gamma 0.0, DDC Backlight 0, DDC Contrast 30)
/// - 30%  = DDC Hardware Floor (Software Gamma 1.0, DDC Backlight 0, DDC Contrast 50)
/// - 100% = Maximum Lumens (Software Gamma 1.0, DDC Backlight 100, DDC Contrast 100)
final class CombinedBrightnessController {

    var onLog: ((String) -> Void)? {
        didSet {
            ddc.onLog = onLog
            builtIn.onLog = onLog
            softwareDimmer.onLog = onLog
        }
    }

    private let ddc = DDCController()
    private let builtIn = BuiltInBrightnessController()
    private let softwareDimmer = SoftwareDimmingController()

    private(set) var currentCombinedLevel: Int = 50

    // MARK: - Public API

    /// Sets combined brightness from 0 (pitch black) to 100 (max hardware backlight).
    @discardableResult
    func setCombinedBrightness(_ percent: Int) -> String {
        let level = min(max(percent, 0), 100)
        currentCombinedLevel = level

        // 1. Try built-in panel (MacBook)
        if builtIn.canChangeBrightness() {
            let floatLevel = Float(level) / 100.0
            _ = builtIn.setBrightness(floatLevel)
            return "Built-in panel brightness set to \(level)%"
        }

        // 2. External displays via DDC + Software Dimming
        let externalIDs = DDCController.externalDisplayIDs()
        guard !externalIDs.isEmpty else {
            return "No external display detected for combined brightness"
        }

        var results: [String] = []
        for displayID in externalIDs {
            let msg = applyCombined(level: level, displayID: displayID)
            results.append(msg)
        }

        return results.joined(separator: " | ")
    }

    /// Increase combined brightness by delta percent.
    @discardableResult
    func increase(by delta: Int) -> String {
        setCombinedBrightness(currentCombinedLevel + delta)
    }

    /// Decrease combined brightness by delta percent.
    @discardableResult
    func decrease(by delta: Int) -> String {
        setCombinedBrightness(currentCombinedLevel - delta)
    }

    // MARK: - Core Combining Logic

    private func applyCombined(level: Int, displayID: CGDirectDisplayID) -> String {
        let fLevel = Float(level)

        if fLevel <= 30.0 {
            // --- Sub-zero range (0% to 30%) ---
            // Scale software GPU gamma from 0.0 (pitch black) to 1.0 (normal)
            let dimmingFactor = fLevel / 30.0
            let ddcContrast = 30 + Int((fLevel / 30.0) * 20.0) // 30 to 50
            let ddcBacklight = 0

            // Apply software gamma dimming
            _ = softwareDimmer.setDimmingFactor(dimmingFactor, for: displayID)

            // Set DDC backlight to 0 and contrast to lower floor
            _ = ddc.setBrightness(displayID: displayID, percent: ddcBacklight)
            _ = ddc.setContrast(displayID: displayID, percent: ddcContrast)

            let desc = level == 0 ? "Pitch Black (0%)" : "Sub-Zero Software Dimming (\(level)%)"
            emit("[Combined] \(desc) on display \(displayID)")
            return "Combined brightness: \(desc)"
        } else {
            // --- Standard range (30% to 100%) ---
            // Keep software GPU gamma at 100% normal
            _ = softwareDimmer.setDimmingFactor(1.0, for: displayID)

            let progress = (fLevel - 30.0) / 70.0 // 0.0 to 1.0
            let ddcBacklight = Int(progress * 100.0) // 0 to 100
            let ddcContrast = 50 + Int(progress * 50.0) // 50 to 100

            _ = ddc.setBrightness(displayID: displayID, percent: ddcBacklight)
            _ = ddc.setContrast(displayID: displayID, percent: ddcContrast)

            emit("[Combined] DDC Backlight \(ddcBacklight)%, Contrast \(ddcContrast)% on display \(displayID)")
            return "Combined brightness: \(level)%"
        }
    }

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
