import Foundation

/// Whole-command parsing keeps device volume separate from Spotify's own
/// volume, microphone gain, display controls, questions and song titles.
enum SystemVolumeParser {
    static func route(_ raw: String) -> PlannedAction? {
        let text = LocalSearchParser.clean(raw).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?:,? please)$"#, with: "", options: .regularExpression)
        if ["system volume", "current volume", "volume level", "what is the volume",
            "what's the volume", "what is the current volume", "what's the current volume",
            "what is the volume level", "what is the current volume level", "what's the current volume level", "show volume", "show the volume", "check volume",
            "how loud is the volume"].contains(text) { return .systemInfo(.systemVolume) }
        if ["mute", "mute the sound", "mute audio", "mute sound", "mute the audio",
            "mute system audio", "mute system sound", "mute the volume", "sound off",
            "turn off sound", "turn the sound off", "silence", "go silent", "shut up", "be quiet"].contains(text) {
            return .volumeControl(.mute)
        }
        if ["unmute", "unmute the sound", "unmute audio", "unmute sound", "unmute the audio",
            "unmute system audio", "unmute system sound", "unmute the volume", "sound on",
            "turn on sound", "turn the sound on"].contains(text) { return .volumeControl(.unmute) }

        let noun = #"(?:(?:the |my )?(?:(?:system|output|speaker|mac|computer) )?(?:volume|sound|audio))"#
        let amount = #"([a-z0-9 -]+?)(?:\s*(?:%|percent|percentage points?))?"#
        let setPatterns = [
            "^(?:set|change|adjust|put|turn) \(noun)(?: level)? (?:to|at) \(amount)$",
            "^\(noun)(?: level)? (?:to|at) \(amount)$",
            "^set \(noun) \(amount)$"
        ]
        for pattern in setPatterns {
            if let fields = LocalSearchParser.captures(pattern, text), let value = number(fields[0]) {
                return .volumeControl(.setLevel(value))
            }
        }
        // “increase ... to 40” is absolute; “increase ... by 40” is a
        // 40-percentage-point delta. Never discard a supplied amount.
        let up = "(?:increase|raise|boost|bump up) \(noun)|turn up \(noun)|turn \(noun) up|\(noun) up|(?:make it )?louder|volume louder|bump the volume"
        let down = "(?:decrease|reduce|lower) \(noun)|turn down \(noun)|turn \(noun) down|\(noun) down|(?:make it )?quieter"
        for (verbs, increasing) in [(up, true), (down, false)] {
            if let fields = LocalSearchParser.captures("^(?:\(verbs)) to \(amount)$", text), let value = number(fields[0]) {
                return .volumeControl(.setLevel(value))
            }
            if let fields = LocalSearchParser.captures("^(?:\(verbs))(?: (?:by )?\(amount))?$", text) {
                let value: Int
                if fields[0].isEmpty { value = 10 }
                else if let parsed = number(fields[0]) { value = parsed }
                else { return nil }
                return .volumeControl(increasing ? .increase(by: value) : .decrease(by: value))
            }
        }
        return nil
    }

    static func number(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.range(of: #"^[0-9]{1,3}$"#, options: .regularExpression) != nil,
           let value = Int(text), (0...100).contains(value) { return value }
        let small = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                     "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        if let value = small.firstIndex(of: text) { return value }
        if text == "hundred" || text == "one hundred" { return 100 }
        let tens = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
        let words = text.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(String.init)
        guard let first = words.first, let base = tens[first] else { return nil }
        if words.count == 1 { return base }
        guard words.count == 2, let unit = small.firstIndex(of: words[1]), (1...9).contains(unit) else { return nil }
        return base + unit
    }
}
