import Foundation

extension ActionPlanner {
    func parseVolumeCommand(_ lower: String) -> PlannedAction? {

        // ── Mute ─────────────────────────────────────────────────────
        let muteVariants = [
            "mute", "mute the sound", "mute audio", "mute sound",
            "sound off", "turn off sound", "silence", "go silent",
            "shut up", "be quiet",
        ]
        if muteVariants.contains(lower) {
            NSLog("[Intent] detected: mute")
            return .volumeControl(.mute)
        }

        // ── Unmute ───────────────────────────────────────────────────
        let unmuteVariants = [
            "unmute", "sound on", "turn on sound", "unmute the sound",
            "unmute audio", "unmute sound",
        ]
        if unmuteVariants.contains(lower) {
            NSLog("[Intent] detected: unmute")
            return .volumeControl(.unmute)
        }

        if lower.contains("set volume to ") || lower.contains("volume to ") {
            if let pct = extractVolumeAmount(from: lower) {
                NSLog("[Intent] detected: volume_set(%d%%)", pct)
                return .volumeControl(.setLevel(pct))
            }
        }

        // ── Increase: volume, sound, audio ───────────────────────────
        let increasePatterns = [
            "increase volume",  "increase the volume",
            "increase sound",   "increase the sound",
            "increase audio",   "increase the audio",
            "volume up", "sound up", "audio up",
            "turn up the volume", "turn up the sound", "turn up",
            "raise volume", "raise the volume",
            "louder", "make it louder", "volume louder",
            "bump up the volume", "bump the volume"
        ]
        if increasePatterns.contains(where: { lower.contains($0) }) {
            let amount = extractVolumeAmount(from: lower) ?? 10
            NSLog("[Intent] detected: volume_up(%d%%)", amount)
            return .volumeControl(.increase(by: amount))
        }

        // ── Decrease: volume, sound, audio ───────────────────────────
        let decreasePatterns = [
            "decrease volume",  "decrease the volume",
            "decrease sound",   "decrease the sound",
            "decrease audio",   "decrease the audio",
            "volume down", "sound down", "audio down",
            "turn down the volume", "turn down the sound", "turn down",
            "lower volume", "lower the volume", "lower sound",
            "quieter", "make it quieter",
            "reduce volume", "reduce the volume"
        ]
        if decreasePatterns.contains(where: { lower.contains($0) }) {
            let amount = extractVolumeAmount(from: lower) ?? 10
            NSLog("[Intent] detected: volume_down(%d%%)", amount)
            return .volumeControl(.decrease(by: amount))
        }

        return nil
    }

    // MARK: - Display command parser

    /// Parses brightness, contrast, and resolution commands.
    /// Returns nil if the input doesn't match any display pattern.
    func parseDisplayCommand(_ lower: String) -> PlannedAction? {

        // ── Brightness set ──────────────────────────────────────────
        let brightnessSetPatterns = [
            "set brightness to ", "brightness to ", "set the brightness to ",
            "set screen brightness to ", "screen brightness to "
        ]
        for pattern in brightnessSetPatterns where lower.hasPrefix(pattern) {
            if let pct = extractPercent(from: lower) {
                NSLog("[Intent] detected: set_brightness(%d%%)", pct)
                return .displayControl(.setBrightness(pct))
            }
        }
        // Handle "set brightness 70" (no "to")
        if lower.hasPrefix("set brightness ") || lower.hasPrefix("brightness ") {
            if let pct = extractPercent(from: lower), pct >= 0, pct <= 100 {
                return .displayControl(.setBrightness(pct))
            }
        }

        // ── Brightness increase ──────────────────────────────────────
        let brightnessUpPatterns = [
            "increase brightness", "increase the brightness",
            "brightness up", "brighter", "make it brighter",
            "make the screen brighter", "turn up brightness", "turn up the brightness",
            "raise brightness", "raise the brightness",
            "dim up", "screen brighter"
        ]
        if brightnessUpPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            NSLog("[Intent] detected: brightness_up(%d%%)", amount)
            return .displayControl(.increaseBrightness(by: amount))
        }

        // ── Brightness decrease ──────────────────────────────────────
        let brightnessDownPatterns = [
            "decrease brightness", "decrease the brightness",
            "brightness down", "dimmer", "dim the screen",
            "make it dimmer", "make the screen dimmer",
            "turn down brightness", "turn down the brightness",
            "lower brightness", "lower the brightness",
            "reduce brightness", "reduce the brightness",
            "darker", "screen darker"
        ]
        if brightnessDownPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            NSLog("[Intent] detected: brightness_down(%d%%)", amount)
            return .displayControl(.decreaseBrightness(by: amount))
        }

        // ── Contrast set ────────────────────────────────────────────
        let contrastSetPatterns = [
            "set contrast to ", "contrast to ", "set the contrast to "
        ]
        for pattern in contrastSetPatterns where lower.hasPrefix(pattern) {
            if let pct = extractPercent(from: lower) {
                NSLog("[Intent] detected: set_contrast(%d%%)", pct)
                return .displayControl(.setContrast(pct))
            }
        }

        // ── Contrast increase ────────────────────────────────────────
        let contrastUpPatterns = ["increase contrast", "contrast up", "more contrast"]
        if contrastUpPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            return .displayControl(.increaseContrast(by: amount))
        }

        // ── Contrast decrease ────────────────────────────────────────
        let contrastDownPatterns = ["decrease contrast", "contrast down", "less contrast", "reduce contrast"]
        if contrastDownPatterns.contains(where: { lower.contains($0) }) {
            let amount = extractPercent(from: lower) ?? 10
            return .displayControl(.decreaseContrast(by: amount))
        }

        // ── List resolutions ─────────────────────────────────────────
        let listResPatterns = ["list resolutions", "list the resolutions",
                               "show resolutions", "show the resolutions",
                               "available resolutions",
                               "what resolutions", "list display modes", "show display modes"]
        if listResPatterns.contains(where: { lower.contains($0) }) {
            return .displayControl(.listResolutions)
        }

        // ── Set resolution by shorthand ("4k", "1080p", "1440p") ────
        let resolutionTriggers = ["resolution to ", "switch to ", "change to ",
                                  "set display to ", "change resolution to ", "switch resolution to "]
        for trigger in resolutionTriggers {
            if lower.contains(trigger) {
                if let range = lower.range(of: trigger),
                   let resolved = DisplayModeController.resolveShorthand(String(lower[range.upperBound...])) {
                    NSLog("[Intent] detected: set_resolution(%d×%d)", resolved.width, resolved.height)
                    return .displayControl(.setResolution(width: resolved.width, height: resolved.height, refreshRate: nil))
                }
                if let parsed = parseExplicitResolution(from: lower) {
                    return .displayControl(.setResolution(width: parsed.width, height: parsed.height, refreshRate: parsed.refresh))
                }
            }
        }
        if lower.contains("resolution") {
            if let parsed = parseExplicitResolution(from: lower) {
                return .displayControl(.setResolution(width: parsed.width, height: parsed.height, refreshRate: parsed.refresh))
            }
        }

        return nil
    }

    /// Parses explicit resolution strings like "1920x1080", "1920 by 1080",
    /// optionally followed by "at 60hz" or "60 hertz".
    func parseExplicitResolution(from lower: String) -> (width: Int, height: Int, refresh: Double?)? {
        let pattern = #"(\d{3,4})\s*(?:x|by)\s*(\d{3,4})(?:\s*(?:@|at)\s*(\d+)\s*(?:hz|hertz))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)) else {
            return nil
        }
        func group(_ i: Int) -> String? {
            guard let range = Range(match.range(at: i), in: lower) else { return nil }
            return String(lower[range])
        }
        guard let w = group(1).flatMap(Int.init),
              let h = group(2).flatMap(Int.init) else { return nil }
        let hz = group(3).flatMap(Double.init)
        return (width: w, height: h, refresh: hz)
    }

    /// Extract a percentage/amount from spoken text.
    /// Handles:
    ///   "by 10%" → 10
    ///   "by ten" → 10
    ///   "by hundred" → 100
    ///   "by hundred percent" → 100
    ///   "100" → 100
    func extractVolumeAmount(from lower: String) -> Int? {
        // Word-number mapping
        let wordNumbers: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
            "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
            "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100
        ]

        // Try word-number match first (e.g. "by ten", "by hundred percent")
        for (word, value) in wordNumbers {
            let patterns = ["by \(word) percent", "by \(word)", " \(word) percent", " \(word)"]
            for pattern in patterns {
                if lower.contains(pattern) {
                    return min(100, max(0, value))
                }
            }
        }

        // Try digit-based match (e.g. "by 10%", "increase volume by 10", "100")
        let pattern = #"(?:by\s+)?(\d+)\s*%?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let range = Range(match.range(at: 1), in: lower),
              let value = Int(lower[range]) else { return nil }
        return min(100, max(0, value))
    }

    /// Legacy alias kept for compatibility (delegates to extractVolumeAmount)
    func extractPercent(from lower: String) -> Int? {
        extractVolumeAmount(from: lower)
    }

    // MARK: - Search query parser
    // NOTE: This is called BEFORE parseSinglePhrase so "search YouTube for X"
    // never falls through to the AI / Ollama path.

}
