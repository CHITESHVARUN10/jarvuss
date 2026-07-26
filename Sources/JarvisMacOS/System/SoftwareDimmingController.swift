import Foundation
import CoreGraphics

/// Controls display brightness at the GPU software level by scaling the display's
/// RGB color lookup tables (Gamma table) using CoreGraphics (`CGSetDisplayTransferByTable`).
///
/// This allows dimming the screen all the way to 100% pitch black (0 lux emission),
/// overcoming the physical hardware minimum backlight limit of external LCD monitors.
final class SoftwareDimmingController {

    var onLog: ((String) -> Void)?

    private struct OriginalGammaTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        let tableSize: Int
    }

    /// Cache of baseline hardware gamma tables per displayID
    private var originalTables: [CGDirectDisplayID: OriginalGammaTable] = [:]

    deinit {
        restoreAllGamma()
    }

    // MARK: - Public API

    /// Applies a software dimming factor from 0.0 (pitch black) to 1.0 (normal color).
    /// Returns true on success.
    @discardableResult
    func setDimmingFactor(_ factor: Float, for displayID: CGDirectDisplayID) -> Bool {
        let clampedFactor = CGGammaValue(min(max(factor, 0.0), 1.0))

        // Ensure we have captured baseline gamma table for this display
        guard let baseTable = getOrCaptureOriginalTable(for: displayID) else {
            emit("[SoftwareDimming][ERROR] Failed to capture baseline gamma table for display \(displayID)")
            return false
        }

        let count = baseTable.tableSize
        var scaledRed   = [CGGammaValue](repeating: 0, count: count)
        var scaledGreen = [CGGammaValue](repeating: 0, count: count)
        var scaledBlue  = [CGGammaValue](repeating: 0, count: count)

        for i in 0..<count {
            scaledRed[i]   = baseTable.red[i]   * clampedFactor
            scaledGreen[i] = baseTable.green[i] * clampedFactor
            scaledBlue[i]  = baseTable.blue[i]  * clampedFactor
        }

        let result = CGSetDisplayTransferByTable(
            displayID,
            UInt32(count),
            &scaledRed,
            &scaledGreen,
            &scaledBlue
        )

        if result == .success {
            emit("[SoftwareDimming] Display \(displayID) factor set to \(Int(clampedFactor * 100))%")
            return true
        } else {
            emit("[SoftwareDimming][ERROR] CGSetDisplayTransferByTable failed: \(result.rawValue)")
            return false
        }
    }

    /// Restores display gamma table back to 100% normal hardware default.
    @discardableResult
    func restoreGamma(for displayID: CGDirectDisplayID) -> Bool {
        guard let baseTable = originalTables[displayID] else {
            return CGSetDisplayTransferByFormula(displayID, 0, 1, 1, 0, 1, 1, 0, 1, 1) == .success
        }

        var red = baseTable.red
        var green = baseTable.green
        var blue = baseTable.blue

        let result = CGSetDisplayTransferByTable(
            displayID,
            UInt32(baseTable.tableSize),
            &red,
            &green,
            &blue
        )
        return result == .success
    }

    /// Restores all displays to baseline gamma.
    func restoreAllGamma() {
        for displayID in originalTables.keys {
            restoreGamma(for: displayID)
        }
        originalTables.removeAll()
    }

    // MARK: - Internal Capture

    private func getOrCaptureOriginalTable(for displayID: CGDirectDisplayID) -> OriginalGammaTable? {
        if let cached = originalTables[displayID] {
            return cached
        }

        var capacity: UInt32 = 0
        if CGGetDisplayTransferByTable(displayID, 0, nil, nil, nil, &capacity) != .success || capacity == 0 {
            // Default 256 entries if system returns 0
            capacity = 256
        }

        var red   = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue  = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0

        let result = CGGetDisplayTransferByTable(
            displayID,
            capacity,
            &red,
            &green,
            &blue,
            &sampleCount
        )

        if result == .success && sampleCount > 0 {
            let count = Int(sampleCount)
            let table = OriginalGammaTable(
                red: Array(red.prefix(count)),
                green: Array(green.prefix(count)),
                blue: Array(blue.prefix(count)),
                tableSize: count
            )
            originalTables[displayID] = table
            return table
        }

        // Fallback linear identity table if system table read is empty
        let count = 256
        var identityRed   = [CGGammaValue](repeating: 0, count: count)
        var identityGreen = [CGGammaValue](repeating: 0, count: count)
        var identityBlue  = [CGGammaValue](repeating: 0, count: count)
        for i in 0..<count {
            let val = CGGammaValue(i) / CGGammaValue(count - 1)
            identityRed[i]   = val
            identityGreen[i] = val
            identityBlue[i]  = val
        }
        let identityTable = OriginalGammaTable(red: identityRed, green: identityGreen, blue: identityBlue, tableSize: count)
        originalTables[displayID] = identityTable
        return identityTable
    }

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
