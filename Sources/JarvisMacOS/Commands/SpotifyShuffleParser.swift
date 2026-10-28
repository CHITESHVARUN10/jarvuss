import Foundation

/// Keep playlist names and the requested shuffle state out of generative
/// inference. This path runs in both Swift and Rust routing modes.
enum SpotifyShuffleParser {
    static func parse(_ raw: String) -> MediaAction? {
        var text = LocalSearchParser.clean(raw)
        text = text.replacingOccurrences(of: #"(?i)\s+(?:on|in) spotify$"#, with: "", options: .regularExpression)
        let lower = text.lowercased()
        if LocalSearchParser.captures(#"^(?:turn|switch|set) (?:the )?shuffle(?: mode)? (on|off)$"#, lower) != nil {
            return .setShuffle(lower.hasSuffix("on"))
        }
        if lower == "turn on shuffle" || lower == "enable shuffle" || lower == "put shuffle on" { return .setShuffle(true) }
        if ["turn off shuffle", "disable shuffle", "stop shuffling", "don't shuffle"].contains(lower) { return .setShuffle(false) }
        if ["shuffle", "shuffle on", "shuffle it", "shuffle the music", "shuffle music", "shuffle this playlist", "shuffle the playlist", "shuffle current playlist"].contains(lower) { return .setShuffle(true) }
        if lower == "shuffle off" { return .setShuffle(false) }
        guard lower.hasPrefix("play ") || lower.hasPrefix("shuffle ") else { return nil }
        // A second unrelated action must reach the compound planner intact.
        guard lower.range(of: #"\b(?:and|then)\s+(?:open|close|find|search|delete|run|set|turn|pause|skip|play|resume|stop)\b"#, options: .regularExpression) == nil,
              lower.range(of: #"\b(?:and|then)\s+shuffle\s+(?!(?:it|them)\s*$)"#, options: .regularExpression) == nil else { return nil }

        let prefix = lower.hasPrefix("shuffle ")
        var enabled = true
        if !prefix {
            let off = #"(?i)\s+(?:without shuffle|with shuffle off|in order|sequentially)$"#
            let on = #"(?i)[,\s]+(?:(?:and|then)\s+)?(?:shuffle(?:\s+(?:it|them))?|(?:on|with|in) shuffle(?: mode)?|shuffled|in (?:a )?random order)$"#
            if let range = text.range(of: off, options: .regularExpression) {
                text.removeSubrange(range); enabled = false
            } else if let range = text.range(of: on, options: .regularExpression) {
                text.removeSubrange(range)
            } else if text.range(of: #"(?i)^play shuffled\s+"#, options: .regularExpression) != nil {
                text = text.replacingOccurrences(of: #"(?i)^play shuffled\s+"#, with: "play ", options: .regularExpression)
            } else { return nil }
        }

        if text.range(of: #"(?i)\bplaylist\b"#, options: .regularExpression) == nil,
           text.range(of: #"(?i)\b(?:(?:liked|light|saved|favorite|favourite)\s+(?:songs|tracks|music)|favorites|favourites)\b"#, options: .regularExpression) != nil {
            return .playLikedWithShuffle(enabled)
        }
        var name: String?
        if let match = LocalSearchParser.captures(#"\bplaylist\s+(?:(?:called|named)\s+)?(.+)$"#, text) {
            name = match[0]
        } else if let match = LocalSearchParser.captures(#"^(.+?)\s+playlist$"#, text) {
            name = match[0].replacingOccurrences(of: #"(?i)^(?:(?:play|shuffle|songs?|tracks?|music|a|some|from|in|my|the)\s+)+"#, with: "", options: .regularExpression)
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"“”"))),
              !name.isEmpty, name.count <= 200 else { return nil }
        return .playPlaylistWithShuffle(name: name, enabled: enabled)
    }
}
