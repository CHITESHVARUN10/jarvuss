import Foundation

extension ActionPlanner {
    func parseMediaCommand(_ lower: String) -> PlannedAction? {
        if let shuffle = SpotifyShuffleParser.parse(lower) { return .mediaControl(shuffle) }
        let compact = lower.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }

        if containsAnyWord(compact, words: ["open", "close", "launch", "quit"]) {
            return nil
        }

        let explicitMediaIntent = containsAnyWord(
            compact,
            words: ["play", "song", "songs", "music", "track", "liked", "playlist", "next", "previous", "prev", "pause", "resume", "skip", "back"]
        )
        guard explicitMediaIntent else { return nil }

        if containsAnyWord(compact, words: ["next", "skip"]) {
            NSLog("[Intent] detected: next_track")
            return .mediaControl(.nextTrack)
        }
        if containsAnyWord(compact, words: ["previous", "prev", "back"]) {
            NSLog("[Intent] detected: previous_track")
            return .mediaControl(.previousTrack)
        }
        if containsAnyWord(compact, words: ["pause", "stop"]) {
            NSLog("[Intent] detected: pause")
            return .mediaControl(.pause)
        }

        let normalizedIntent = normalizeMediaIntentText(compact)
        let normalizedTokens = normalizedIntent
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
        let normalizedJoined = normalizedTokens.joined(separator: " ")

        if containsAnyWord(normalizedJoined, words: ["next", "skip"]) {
            NSLog("[Intent] detected: next_track")
            return .mediaControl(.nextTrack)
        }
        if containsAnyWord(normalizedJoined, words: ["previous", "prev", "back"]) {
            NSLog("[Intent] detected: previous_track")
            return .mediaControl(.previousTrack)
        }

        if containsAnyWord(normalizedJoined, words: ["liked", "favorites", "favourites", "saved"]) || isLikedSongsQuery(compact) {
            NSLog("[Intent] detected: liked_songs")
            return .mediaControl(.playLikedSongs)
        }

        if normalizedJoined.isEmpty || normalizedJoined == "resume" || normalizedJoined == "playback" {
            NSLog("[Intent] detected: play")
            return .mediaControl(.play)
        }

        let webKeywords = ["youtube", "netflix", "on youtube", "spotify web"]
        if webKeywords.contains(where: { compact.contains($0) }) {
            return nil
        }

        if isPlaylistQuery(compact) || containsAnyWord(compact, words: ["playlist"]) {
            let playlistName = extractPlaylistName(normalizedIntent)
            NSLog("[Intent] detected: play_playlist → '%@'", playlistName)
            return .mediaControl(.playPlaylist(playlistName))
        }

        // A sentence that merely CONTAINS "play" and "song" is not a song
        // title. "in spotify, could you play a song for me?" used to become
        // playSong("in spotify, could you a for me?") — every content word is
        // a trigger/filler, so it is a plain "start playing" request.
        if mediaContentTokens(compact).isEmpty {
            NSLog("[Intent] detected: play (no title in '%@')", compact)
            return .mediaControl(.play)
        }

        let songName = cleanSongTitle(extractSongName(normalizedIntent))
        guard !songName.isEmpty else {
            NSLog("[Intent] detected: play (empty title after cleanup)")
            return .mediaControl(.play)
        }
        NSLog("[Intent] detected: play_song → '%@'", songName)
        return .mediaControl(.playSong(songName))
    }

    /// Words that carry no song-title information: the media triggers
    /// themselves, question/politeness filler, and app/context nouns.
    /// Deliberately excludes short words that appear inside real titles
    /// ("of" in "shape of you").
    static let mediaNonTitleWords: Set<String> = [
        "play", "plays", "playing", "song", "songs", "music", "track", "tracks",
        "playlist", "playlists", "tune", "tunes", "some", "any", "something",
        "anything", "one", "it", "that", "this", "these", "those",
        "a", "an", "the", "in", "on", "to", "at", "for", "me", "us", "my", "your",
        "could", "would", "can", "will", "please", "kindly", "just", "now",
        "again", "aloud", "jarvis", "spotify", "app", "application", "player",
        "like", "want", "wanna", "need", "let", "have", "got", "get", "give",
        "put", "start", "starting", "hear", "listen", "listening", "back",
        "do", "does", "did", "is", "are", "was", "were", "be", "you", "i",
    ]

    /// Content words of the utterance that could name a song.
    func mediaContentTokens(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased() }
            .filter { !$0.isEmpty }
            .filter { !Self.mediaNonTitleWords.contains($0) }
    }

    /// Strip leading articles/possessives and trailing "on spotify"-style
    /// context so the title sent to Spotify is the name the user spoke.
    func cleanSongTitle(_ raw: String) -> String {
        var words = raw
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }

        let leadingNoise: Set<String> = ["a", "an", "the", "my", "some", "that", "this", "please"]
        while let first = words.first?.lowercased(), leadingNoise.contains(first) {
            words.removeFirst()
        }

        let trailingNoise: Set<String> = ["spotify", "app", "player", "music", "song", "track", "please"]
        while let last = words.last?.lowercased(), trailingNoise.contains(last) {
            words.removeLast()
            if words.last?.lowercased() == "on" || words.last?.lowercased() == "in" || words.last?.lowercased() == "from" {
                words.removeLast()
            }
        }

        return words.joined(separator: " ")
    }

    func normalizeMediaIntentText(_ text: String) -> String {
        let removable: Set<String> = ["play", "music", "song", "songs", "track", "tracks", "from"]
        let tokens = text
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)

        let cleaned = tokens.filter { token in
            let normalized = token
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            return !removable.contains(normalized)
        }

        return cleaned.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func containsAnyWord(_ text: String, words: [String]) -> Bool {
        let tokenSet = Set(
            text.lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
                .filter { !$0.isEmpty }
        )
        return words.contains(where: { tokenSet.contains($0) })
    }

    func preferredSingleControlAction(from actions: [PlannedAction]) -> PlannedAction? {
        // Only collapse when the utterance is media control and NOTHING else.
        // Otherwise "open spotify, open whatsapp and play a song" would be
        // reduced to just `play`, silently dropping the app opens.
        let allMedia = actions.allSatisfy { action in
            if case .mediaControl = action { return true }
            return false
        }
        guard allMedia, actions.count > 1 else { return nil }

        let controlOrder: [MediaAction] = [.nextTrack, .previousTrack, .pause, .play]
        let mediaActions = actions.compactMap { action -> MediaAction? in
            if case .mediaControl(let media) = action { return media }
            return nil
        }

        for control in controlOrder where mediaActions.contains(control) {
            return .mediaControl(control)
        }
        return nil
    }

    func commandCheatSheet() -> String {
        """
        SYSTEM:
        - open chrome
        - open spotify
        - close spotify
        - open whatsapp
        - chrome / spotify / whatsapp

        MEDIA:
        - play song <name>
        - play liked songs
        - shuffle my liked songs
        - play my gym playlist on shuffle
        - turn shuffle off
        - play <playlist>
        - next track
        - previous track

        INFO:
        - what time is it
        - what is today's date
        - which wifi am I connected to
        - which bluetooth devices are connected
        - battery status
        - system volume

        GENERAL:
        - ask anything (AI fallback)
        """
    }

    /// Extracts a meaningful playlist name from speech.
    /// Strips filler like "from", "songs", "playlist" before returning.
    /// Examples:
    ///   "songs from gym playlist" → "gym"
    ///   "music from chill vibes"  → "chill vibes"
    ///   "workout songs"           → "workout"
    func extractPlaylistName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let fillerWords: Set<String> = ["play", "from", "playlist", "my", "the", "some"]
        let playlistSuffixes: Set<String> = ["songs", "tracks", "music", "station", "mix"]

        let tokens = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)

        var cleaned: [String] = []
        for token in tokens {
            let normalized = token
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            guard !normalized.isEmpty else { continue }
            if fillerWords.contains(normalized) { continue }
            cleaned.append(token)
        }

        while let last = cleaned.last {
            let normalized = last
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            if playlistSuffixes.contains(normalized) {
                cleaned.removeLast()
            } else {
                break
            }
        }

        let leadingNoise: Set<String> = ["play", "music", "song", "songs", "track", "tracks", "some"]
        while cleaned.count > 1, let first = cleaned.first {
            let normalized = first
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            if leadingNoise.contains(normalized) {
                cleaned.removeFirst()
            } else {
                break
            }
        }

        let extracted = cleaned.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return extracted.isEmpty ? trimmed : extracted
    }

    func extractSongName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        let lower = name.lowercased()

        let leadingFillers = ["play song ", "play track ", "play ", "song ", "track ", "the song ", "the track ", "music "]
        for filler in leadingFillers where lower.hasPrefix(filler) {
            name = String(name.dropFirst(filler.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        let trailingFillers = [" song", " track", " music", " playlist"]
        for suffix in trailingFillers where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            break
        }

        return name.isEmpty ? raw : name
    }

    func isPlaylistQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let playlistKeywords = ["playlist", "my playlist", "from playlist", "playlist called", "playlist named"]
        return playlistKeywords.contains(where: { lower.contains($0) })
    }

    func isLikedSongsQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let likedKeywords = [
            "liked songs", "my liked songs", "liked", "my liked",
            "saved songs", "my saved songs", "favorites", "my favorites"
        ]
        return likedKeywords.contains(where: { lower == $0 || lower.hasPrefix("\($0) ") || lower.hasSuffix(" \($0)") })
    }

    // MARK: - Volume command parser

    /// Parses spoken volume commands into a VolumeAction.
    /// All variants of "sound"/"volume"/"audio" are handled here — NEVER goes to AI.
}
