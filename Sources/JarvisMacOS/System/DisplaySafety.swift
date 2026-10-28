import Foundation

enum DisplaySafety {
    static let minimumBrightness = 10
    static let minimumContrast = 20
    static let minimumSoftwareFactor: Float = 0.2
    static let recoveryBrightness = 60
    static let recoveryContrast = 50
    static let recoveryPhrase = "Restore my display"
    static let recoveryShortcut = "⌘⇧R"

    static func brightness(_ value: Int) -> Int { min(100, max(minimumBrightness, value)) }
    static func contrast(_ value: Int) -> Int { min(100, max(minimumContrast, value)) }
    static func adjustedBrightness(current: Int, delta: Int, increasing: Bool) -> Int {
        brightness(adjusted(current: current, delta: delta, increasing: increasing))
    }
    static func adjustedContrast(current: Int, delta: Int, increasing: Bool) -> Int {
        contrast(adjusted(current: current, delta: delta, increasing: increasing))
    }
    private static func adjusted(current: Int, delta: Int, increasing: Bool) -> Int {
        let base = min(100, max(0, current)), step = min(100, max(0, delta))
        return increasing ? base + step : base - step
    }
    static func hardwareBrightness(_ value: Float) -> Float {
        value.isFinite ? min(1, max(Float(minimumBrightness) / 100, value)) : Float(recoveryBrightness) / 100
    }
    static func softwareFactor(_ value: Float) -> Float {
        value.isFinite ? min(1, max(minimumSoftwareFactor, value)) : 1
    }
    static func safeVCPValue(_ code: UInt8, _ value: UInt16) -> UInt16 {
        if code == 0x10 { return UInt16(brightness(Int(value))) }
        if code == 0x12 { return UInt16(contrast(Int(value))) }
        return value // Volume can still reach zero/mute.
    }

    /// Whole-utterance whitelist. Never bypass verification for appended or
    /// embedded commands, negations, or ordinary dictation (⌘⇧D).
    static func isRecoveryRequest(_ text: String) -> Bool {
        var words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if words.first == "jarvis" { words.removeFirst() }
        return ["restore my display", "restore display", "restore my screen", "screen rescue"].contains(words.joined(separator: " "))
    }
}
