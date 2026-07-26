import Foundation
import CoreGraphics

/// Monitor volume via DDC/CI using the Apple Silicon IOAVService path.
/// Delegates all hardware I/O to DDCController — this class is kept as a
/// thin adapter so VolumeController.swift's call sites are unchanged.
final class MonitorVolumeController {
    var onLog: ((String) -> Void)?

    private(set) var currentPercent: Int = 50
    private let ddc = DDCController()

    func setVolume(_ percent: Int) {
        _ = setVolumeResult(percent)
    }

    func increase(by delta: Int) {
        _ = setVolumeResult(currentPercent + delta)
    }

    func decrease(by delta: Int) {
        _ = setVolumeResult(currentPercent - delta)
    }

    @discardableResult
    func setVolumeResult(_ percent: Int) -> Bool {
        let safe = max(0, min(100, percent))
        ddc.onLog = onLog

        let displays = DDCController.externalDisplayIDs()
        guard let displayID = displays.first else {
            emit("[DDC] No external display found for volume control")
            return false
        }

        let ok = ddc.setVolume(displayID: displayID, percent: safe)
        if ok { currentPercent = safe }
        return ok
    }

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
