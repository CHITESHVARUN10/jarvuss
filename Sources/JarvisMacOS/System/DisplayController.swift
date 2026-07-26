import Foundation
import CoreGraphics

// MARK: - DisplayAction

/// All voice-triggerable display actions.
enum DisplayAction: Equatable, CustomStringConvertible {
    // Brightness (applies to built-in OR external depending on context)
    case setBrightness(Int)             // absolute 0–100
    case increaseBrightness(by: Int)    // delta 0–100
    case decreaseBrightness(by: Int)

    // Contrast (external displays via DDC only)
    case setContrast(Int)
    case increaseContrast(by: Int)
    case decreaseContrast(by: Int)

    // Resolution / display mode
    case setResolution(width: Int, height: Int, refreshRate: Double?)
    case listResolutions

    var description: String {
        switch self {
        case .setBrightness(let v):           return "Set brightness to \(v)%"
        case .increaseBrightness(let d):      return "Increase brightness by \(d)%"
        case .decreaseBrightness(let d):      return "Decrease brightness by \(d)%"
        case .setContrast(let v):             return "Set contrast to \(v)%"
        case .increaseContrast(let d):        return "Increase contrast by \(d)%"
        case .decreaseContrast(let d):        return "Decrease contrast by \(d)%"
        case .setResolution(let w, let h, _): return "Set resolution to \(w)×\(h)"
        case .listResolutions:                return "List available resolutions"
        }
    }

    /// Human-readable spoken response for ResponseEngine.
    var responseText: String {
        switch self {
        case .setBrightness(let v):           return "Brightness set to \(v) percent"
        case .increaseBrightness(let d):      return "Brightness increased by \(d) percent"
        case .decreaseBrightness(let d):      return "Brightness decreased by \(d) percent"
        case .setContrast(let v):             return "Contrast set to \(v) percent"
        case .increaseContrast(let d):        return "Contrast increased by \(d) percent"
        case .decreaseContrast(let d):        return "Contrast decreased by \(d) percent"
        case .setResolution(let w, let h, _): return "Resolution changed to \(w) by \(h)"
        case .listResolutions:                return "Listing available display resolutions"
        }
    }
}

// MARK: - DisplayController

/// Top-level dispatch layer for all display hardware control.
/// Routes actions to the appropriate sub-controller based on action type
/// and which displays are connected.
///
/// Routing rules:
/// - Brightness: built-in first (BuiltInBrightnessController), then external via DDC.
/// - Contrast:   external only (DDC). No contrast control for built-in.
/// - Resolution: DisplayModeController (public CoreGraphics API, works for all displays).
final class DisplayController {

    var onLog: ((String) -> Void)? {
        didSet {
            ddc.onLog = onLog
            builtIn.onLog = onLog
            modeController.onLog = onLog
        }
    }

    private let ddc            = DDCController()
    private let builtIn        = BuiltInBrightnessController()
    private let modeController = DisplayModeController()

    // MARK: - Execute

    func execute(_ action: DisplayAction) -> String {
        switch action {

        // ── Brightness ──────────────────────────────────────────────
        case .setBrightness(let percent):
            return setBrightness(percent)

        case .increaseBrightness(let delta):
            return adjustBrightness(delta: Float(delta) / 100.0, direction: .up)

        case .decreaseBrightness(let delta):
            return adjustBrightness(delta: Float(delta) / 100.0, direction: .down)

        // ── Contrast ────────────────────────────────────────────────
        case .setContrast(let percent):
            return setContrast(percent)

        case .increaseContrast(let delta):
            return adjustContrast(delta: delta, direction: .up)

        case .decreaseContrast(let delta):
            return adjustContrast(delta: delta, direction: .down)

        // ── Resolution ──────────────────────────────────────────────
        case .setResolution(let w, let h, let hz):
            return setResolution(width: w, height: h, refreshRate: hz)

        case .listResolutions:
            return listResolutions()
        }
    }

    // MARK: - Brightness

    /// Returns current display brightness (0-100), checking built-in first then external DDC.
    func getCurrentBrightness() -> Int? {
        if builtIn.canChangeBrightness(), let b = builtIn.getBrightness() {
            return Int(round(b * 100))
        }
        for displayID in DDCController.externalDisplayIDs() {
            ddc.onLog = onLog
            if let cur = ddc.getBrightness(displayID: displayID) {
                return Int(cur.current)
            }
        }
        return nil
    }

    private var cachedBrightnessPct: Int = 50
    private var cachedContrastPct: Int = 50

    private func setBrightness(_ percent: Int) -> String {
        let safePct = clamp(percent, 0, 100)
        let level = Float(safePct) / 100.0

        // Try built-in first.
        if builtIn.canChangeBrightness() {
            let ok = builtIn.setBrightness(level)
            if ok {
                cachedBrightnessPct = safePct
                return "Brightness set to \(safePct)%"
            }
            emit("[Display] Built-in brightness failed, trying external DDC")
        }

        // Try external display via DDC.
        for displayID in DDCController.externalDisplayIDs() {
            ddc.onLog = onLog
            if ddc.setBrightness(displayID: displayID, percent: safePct) {
                cachedBrightnessPct = safePct
                return "External display brightness set to \(safePct)%"
            }
        }

        return "Brightness change failed — no controllable display found"
    }

    private enum Direction { case up, down }

    private func adjustBrightness(delta: Float, direction: Direction) -> String {
        if builtIn.canChangeBrightness() {
            let current = builtIn.getBrightness() ?? Float(cachedBrightnessPct) / 100.0
            let newLevel = direction == .up ? current + delta : current - delta
            let ok = builtIn.setBrightness(newLevel)
            if ok {
                let pct = Int(min(max(newLevel, 0), 1) * 100)
                cachedBrightnessPct = pct
                return "Brightness \(direction == .up ? "increased" : "decreased") to \(pct)%"
            }
        }

        // External display: attempt DDC read, or fall back to cached value if DDC read is unsupported.
        for displayID in DDCController.externalDisplayIDs() {
            ddc.onLog = onLog
            let step = Int(delta * 100)
            let currentPct = ddc.getBrightness(displayID: displayID)?.current ?? clamp(cachedBrightnessPct, 0, 100)
            let newPct = clamp(direction == .up ? currentPct + step : currentPct - step, 0, 100)
            if ddc.setBrightness(displayID: displayID, percent: newPct) {
                cachedBrightnessPct = newPct
                return "External display brightness \(direction == .up ? "increased" : "decreased") to \(newPct)%"
            }
        }

        return "Brightness adjustment failed — no controllable display found"
    }

    // MARK: - Contrast

    private func setContrast(_ percent: Int) -> String {
        ddc.onLog = onLog
        for displayID in DDCController.externalDisplayIDs() {
            if ddc.setContrast(displayID: displayID, percent: percent) {
                return "Contrast set to \(percent)%"
            }
        }
        return "Contrast control requires an external monitor connected via DDC/CI"
    }

    private func adjustContrast(delta: Int, direction: Direction) -> String {
        ddc.onLog = onLog
        for displayID in DDCController.externalDisplayIDs() {
            if let current = ddc.getContrast(displayID: displayID) {
                let newPct = clamp(direction == .up ? current.current + delta : current.current - delta, 0, current.max)
                if ddc.setContrast(displayID: displayID, percent: newPct) {
                    return "Contrast \(direction == .up ? "increased" : "decreased") to \(newPct)%"
                }
            }
        }
        return "Contrast adjustment requires an external monitor connected via DDC/CI"
    }

    // MARK: - Resolution

    private func setResolution(width: Int, height: Int, refreshRate: Double?) -> String {
        let displayID = DisplayModeController.mainDisplayID()
        modeController.onLog = onLog
        return modeController.setMode(displayID: displayID, width: width,
                                      height: height, refreshRate: refreshRate)
    }

    private func listResolutions() -> String {
        let displayID = DisplayModeController.mainDisplayID()
        modeController.onLog = onLog
        return modeController.listModes(for: displayID)
    }

    // MARK: - Helpers

    private func clamp(_ value: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(value, lo), hi)
    }

    private func emit(_ message: String) {
        onLog?(message) ?? { print(message) }()
    }
}
