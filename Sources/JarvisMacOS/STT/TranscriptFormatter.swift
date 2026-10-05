import Foundation

/// Wispr-Flow-style deterministic cleanup of a dictated transcript.
///
/// Phase-2 rules pass: ~0 ms and it can never change meaning, so anything it
/// can fix must never reach the LLM polish pass (`DictationPolisher`). Every
/// pass is deliberately conservative — the transcript is the user's words;
/// an over-eager edit lands worse than an unedited one.
enum TranscriptFormatter {

    struct Output {
        let text: String
        let fillerRemovals: Int
        let correctionResolves: Int
        let unboundedCorrections: Int
        let hasEnumeration: Bool
        let inputWords: Int

        var outputWords: Int { text.split(separator: " ").count }
    }

    /// Passes run in a fixed order because each shapes what the next one sees:
    /// corrections before fillers (so a retracted clause's fillers don't count),
    /// numbers before capitalization, punctuation last.
    static func format(_ raw: String) -> Output {
        let inputWords = raw.split(separator: " ").count

        var text = normalizeWhitespace(raw)

        let duplicates = collapseDuplicateRuns(text)
        text = duplicates.text

        let corrections = resolveSelfCorrections(text)
        text = corrections.text

        let fillers = removeFillers(text)
        text = fillers.text

        let numbers = normalizeNumbers(text)
        text = numbers.text

        text = capitalize(text)
        text = ensureTerminalPunctuation(text)

        return Output(
            text: text,
            fillerRemovals: fillers.count + duplicates.count,
            correctionResolves: corrections.count,
            unboundedCorrections: corrections.pending,
            hasEnumeration: containsEnumeration(text),
            inputWords: inputWords
        )
    }

    /// LLM-pass trigger (`DictationPolisher`): rules handle the common case at
    /// ~0 ms; the LLM only earns its latency on messy or structured input.
    static func shouldUseLLM(_ output: Output) -> Bool {
        if output.hasEnumeration { return true }
        // A retraction without a clause boundary ("meet Tuesday no wait
        // Wednesday") is left untouched — half-fixing it would drop words the
        // speaker did not retract — and forwarded to the LLM, which resolves
        // it from context.
        if output.unboundedCorrections > 0 { return true }
        if output.outputWords > 25 { return true }
        return output.fillerRemovals >= 2 && output.correctionResolves > 0
    }

    // MARK: - Pass A: whitespace

    private static func normalizeWhitespace(_ text: String) -> String {
        var out = text.replacingOccurrences(
            of: #"[\t\n\r]+"#, with: " ", options: .regularExpression)
        // Whisper sometimes emits a space before punctuation ("open chrome .").
        out = out.replacingOccurrences(
            of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pass B: repeated-word collapse

    /// Adjacent case-insensitive duplicates ("the the", "and and") collapse —
    /// mirrors `AppState.collapseRepeatedWords`, but NOT across sentence-final
    /// punctuation (a period between the two words means they are not a
    /// stutter), and never across "had had"-style past-perfect pairs is a
    /// known false positive we accept, matching the command-path behavior.
    private static func collapseDuplicateRuns(_ text: String) -> (text: String, count: Int) {
        let tokens = text.split(separator: " ").map(String.init)
        var kept: [String] = []
        var removed = 0

        for token in tokens {
            if let previous = kept.last,
               previous.lowercased() == token.lowercased(),
               !endsSentenceBreak(previous) {
                removed += 1
                continue
            }
            kept.append(token)
        }

        guard removed > 0 else { return (text, 0) }
        return (kept.joined(separator: " "), removed)
    }

    // MARK: - Pass C: self-corrections

    /// Unambiguous retraction markers. "I mean" is deliberately absent: spoken
    /// mid-sentence it reads more often as clarification than retraction
    /// ("use the blue one, I mean, the dark one"), and stripping it would
    /// change meaning — it lives in the soft-filler set instead.
    private static let retractionMarkers: [[String]] = [
        ["no", "wait"],
        ["wait", "no"],
        ["scratch", "that"],
        ["or", "rather"],
        ["actually", "make", "that"],
    ]

    private static func resolveSelfCorrections(_ text: String) -> (text: String, count: Int, pending: Int) {
        var working = text
        var resolved = 0
        var pending = 0
        var keepGoing = true
        // Cap only bounds RESOLVED corrections (each rebuilds the text);
        // ONE unresolved marker is enough to send the whole text to the LLM.
        while keepGoing, resolved < 5 {
            guard let applied = applyOneSelfCorrection(working) else { break }
            switch applied {
            case .resolved(let rebuilt):
                working = rebuilt
                resolved += 1
            case .left:
                pending = 1
                keepGoing = false
            }
        }
        return (working, resolved, pending)
    }

    private enum CorrectionPass {
        case resolved(String)
        /// Marker present but unbounded (no clause punctuation before it):
        /// the text is left untouched and marked for the LLM pass.
        case left
    }

    /// Token-level retraction for "Tuesday, no wait, Wednesday" speech:
    ///
    ///   retracted = [ last comma token .. marker ), correction = marker's tail
    ///
    /// "let's meet Tuesday, no wait Wednesday" → retracted "Tuesday," →
    /// "let's meet Wednesday". Bounded by CLAUSE punctuation on both sides,
    /// never crossing a sentence break backwards, so a correction inside the
    /// second sentence can never erase the first.
    private static func applyOneSelfCorrection(_ text: String) -> CorrectionPass? {
        let tokens = text.split(separator: " ").map(String.init)

        for index in tokens.indices {
            guard let markerLength = retractionMatchStarting(at: index, in: tokens) else { continue }

            // Walk back to the clause boundary the marker opens.
            var commaIndex: Int?
            var sentenceStart = index
            for j in stride(from: index - 1, through: 0, by: -1) {
                if tokens[j].hasSuffix(",") {
                    commaIndex = j
                    sentenceStart = j
                    break
                }
                if endsSentenceBreak(tokens[j]) {
                    sentenceStart = j + 1
                    break
                }
            }

            // The retracted span is the comma-bounded clause tail between the
            // marker and the comma that precedes it. Without that comma the
            // span is unknowable without semantics — the LLM's job.
            guard let commaIndex, commaIndex < index else {
                return .left
            }

            let correction = Array(tokens[(index + markerLength)...])
            // A marker with nothing after it is not a correction — the
            // speaker trailed off — so leave the text untouched.
            guard correction.contains(where: { !cleanedWord($0).isEmpty }) else {
                return .left
            }

            let rebuilt = Array(tokens[0..<commaIndex]) + correction
            return .resolved(normalizeWhitespace(rebuilt.joined(separator: " ")))
        }
        return nil
    }

    private static func retractionMatchStarting(at index: Int, in tokens: [String]) -> Int? {
        for marker in retractionMarkers {
            guard index + marker.count <= tokens.count else { continue }
            var isMatch = true
            for (offset, word) in marker.enumerated() where cleanedWord(tokens[index + offset]) != word {
                isMatch = false
                break
            }
            if isMatch {
                return marker.count
            }
        }
        return nil
    }

    // MARK: - Pass D: fillers

    /// Removed on sight — pure disfluencies, never content. "Oh"/"ah" stay:
    /// they can carry affect the user chose ("Oh nice!").
    private static let hardFillerTokens: Set<String> = [
        "um", "uh", "uhm", "umm", "uhhh", "erm", "er", "hmm", "hmmm",
        "mmm", "mm", "mhm", "huh",
    ]

    /// Removed only when comma-delimited, utterance-initial, or sentence-
    /// initial. "Like" is the deliberate hard case: "I like it" keeps its
    /// verb; "so, like, go" loses the filler. Standalone "you"/"mean"/"sort"/
    /// "kind" are absent — those words are only removable as the phrases
    /// below ("you know", "I mean", "sort of", "kind of").
    private static let softFillerTokens: Set<String> = [
        "basically", "actually", "literally", "kinda", "sorta", "like",
    ]

    private static let softFillerPhrases: [[String]] = [
        ["you", "know"],
        ["i", "mean"],
        ["sort", "of"],
        ["kind", "of"],
    ]

    private static func removeFillers(_ text: String) -> (text: String, count: Int) {
        var tokens = text.split(separator: " ").map(String.init)

        var kept: [String] = []
        var removed = 0
        var afterSentenceBreak = true
        var commaBefore = false

        var index = 0
        while index < tokens.count {
            let raw = tokens[index]
            let cleaned = raw.lowercased()
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)

            if cleaned.isEmpty {
                // Stray punctuation token; pass A cleans spacing, keep verbatim.
                kept.append(raw)
                index += 1
                continue
            }

            // Phrase fillers match before single words ("you know", "i mean").
            if index + 1 < tokens.count {
                let second = tokens[index + 1].lowercased()
                    .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                if softFillerPhrases.contains(where: { $0 == [cleaned, second] }),
                   afterSentenceBreak || commaBefore || raw.hasPrefix(",") {
                    let outcome = removeCommaDelimited(
                        kept: &kept, tokens: &tokens, index: index,
                        span: 2, ownTrailingComma: tokens[index + 1].hasSuffix(","))
                    removed += outcome.removed
                    // A comma consumed with the filler is gone from the
                    // output — the next token must not inherit it as a
                    // delimiter (else ", actually, like" eats the verb).
                    if outcome.strippedPriorComma { commaBefore = false }
                    index += 2
                    continue
                }
            }

            var removal = 0
            if hardFillerTokens.contains(cleaned) {
                removal = 1
            } else if softFillerTokens.contains(cleaned),
                      afterSentenceBreak || commaBefore || raw.hasPrefix(",") {
                removal = 1
            }

            if removal > 0 {
                let outcome = removeCommaDelimited(
                    kept: &kept, tokens: &tokens, index: index,
                    span: 1, ownTrailingComma: raw.hasSuffix(","))
                removed += outcome.removed
                if outcome.strippedPriorComma { commaBefore = false }
                index += 1
                continue
            }

            kept.append(raw)
            if endsSentenceBreak(raw) {
                afterSentenceBreak = true
                commaBefore = false
            } else {
                afterSentenceBreak = false
                commaBefore = raw.hasSuffix(",")
            }
            index += 1
        }

        guard removed > 0 else { return (text, 0) }
        return (normalizeWhitespace(kept.joined(separator: " ")), removed)
    }

    /// Removes the filler token(s) with the comma semantics that keep the
    /// user's own list structure: when the filler sat BETWEEN two commas
    /// ("X, you know, Y" → "X Y") both commas collapse; when it only followed
    /// a comma ("X, basically Y" → "X, Y") the comma stays, because it joins
    /// the next content — it was never the filler's.
    /// Returns whether the PRIOR token's comma was consumed (so the caller
    /// can clear its comma-before context).
    private static func removeCommaDelimited(
        kept: inout [String], tokens: inout [String], index: Int, span: Int, ownTrailingComma: Bool
    ) -> (removed: Int, strippedPriorComma: Bool) {
        var strippedPriorComma = false
        if ownTrailingComma, let last = kept.last, last.hasSuffix(",") {
            kept[kept.count - 1] = String(last.dropLast())
            strippedPriorComma = true
        }
        // Fold the NEXT token's leading comma into place too (", um," patterns).
        if index + span < tokens.count, tokens[index + span].hasPrefix(",") {
            tokens[index + span] = String(tokens[index + span].dropFirst())
        }
        return (span, strippedPriorComma)
    }

    // MARK: - Pass E: numbers / units

    private static let tensNumerals: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let simpleNumerals: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    /// Rewrites ONLY where ambiguity is low: a spelled number immediately
    /// followed by a unit ("twenty five percent" → "25%", "three pm" → "3pm").
    /// Bare spelled counts ("five thousand people") stay words — they are
    /// amounts, addresses and song titles too often to risk guessing.
    private static func normalizeNumbers(_ text: String) -> (text: String, rewrites: Int) {
        let tokens = text.split(separator: " ").map(String.init)
        var rebuilt: [String] = []
        var rewrites = 0

        var index = 0
        while index < tokens.count {
            if let number = matchPhoneNumber(tokens, at: index) {
                let afterIndex = index + number.consumed
                if afterIndex < tokens.count, isNumberUnit(tokens[afterIndex], for: number.value) {
                    let unit = cleanedWord(tokens[afterIndex])
                    rebuilt.append(
                        unit == "percent" ? "\(number.value)%" : "\(number.value)\(unit)")
                    rewrites += 1
                    index = afterIndex + 1
                    continue
                }
            }
            rebuilt.append(String(tokens[index]))
            index += 1
        }

        guard rewrites > 0 else { return (text, 0) }
        return (rebuilt.joined(separator: " "), rewrites)
    }

    private static func matchPhoneNumber(_ tokens: [String], at index: Int) -> (value: Int, consumed: Int)? {
        let first = cleanedWord(tokens[index])

        // Tens + ones: "twenty five".
        if let tens = tensNumerals[first], index + 1 < tokens.count,
           let ones = simpleNumerals[cleanedWord(tokens[index + 1])] {
            return (tens + ones, 2)
        }
        if let single = simpleNumerals[first] ?? tensNumerals[first] {
            return (single, 1)
        }
        return nil
    }

    private static func isNumberUnit(_ token: String, for value: Int) -> Bool {
        let unit = cleanedWord(token)
        if unit == "percent" { return true }
        return (unit == "am" || unit == "pm") && (1...12).contains(value)
    }

    // MARK: - Pass F: capitalization

    /// Words whose casing is never in question in dictated prose. "I" and its
    /// contractions live here too so one pass handles all casing fixes.
    private static let properNouns: [String: String] = {
        var map: [String: String] = [:]

        let words = [
            "Chrome", "Safari", "Firefox", "Spotify", "WhatsApp", "Telegram",
            "Slack", "Notes", "Xcode", "Photoshop", "Figma", "Notion",
            "Terminal", "Finder", "Google", "Apple", "iPhone", "iPad",
            "Bluetooth", "Python", "Rust", "Docker", "Linux", "OpenAI",
            "Anthropic", "Claude", "Zoom", "GitHub", "YouTube",
        ]
        for word in words { map[word.lowercased()] = word }
        map["macos"] = "macOS"
        map["wifi"] = "Wi-Fi"
        map["swift"] = "Swift"

        let days = ["Monday", "Tuesday", "Wednesday", "Thursday",
                    "Friday", "Saturday", "Sunday"]
        let months = ["January", "February", "March", "April", "May", "June",
                      "July", "August", "September", "October", "November",
                      "December"]
        for word in days + months { map[word.lowercased()] = word }

        map["i"] = "I"
        map["i'm"] = "I'm"
        map["i've"] = "I've"
        map["i'll"] = "I'll"
        map["i'd"] = "I'd"
        return map
    }()

    /// The deterministic casing/punctuation authority, exposed separately for
    /// the LLM pass: a model that solves self-corrections can STILL unfix
    /// capitalization ("so i think…" — observed with qwen2.5:1.5b-instruct),
    /// so whatever the LLM returns passes back through these two rules.
    static func recapitalize(_ text: String) -> String {
        ensureTerminalPunctuation(capitalize(text))
    }

    private static func capitalize(_ text: String) -> String {
        var out = text
        for (spoken, canonical) in properNouns {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: spoken) + #"\b"#
            guard spoken.count > 1 || spoken == "i" else { continue }
            if let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) {
                let range = NSRange(out.startIndex..., in: out)
                out = regex.stringByReplacingMatches(
                    in: out, range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: canonical))
            }
        }

        // Sentence starts: utterance start and anything after `.`, `!`, `?`,
        // including a newline (the LLM's list/paragraph structures count).
        var rebuilt = ""
        var capitaliseNext = true
        for character in out {
            if capitaliseNext, character.isLetter {
                rebuilt.append(Character(character.uppercased()))
                capitaliseNext = false
                continue
            }
            rebuilt.append(character)
            if character.isLetter || character.isNumber {
                capitaliseNext = false
            } else if ".!?".contains(character) || character.isNewline {
                capitaliseNext = true
            }
        }
        return rebuilt
    }

    // MARK: - Pass G: terminal punctuation

    private static func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        // Lists end without a period: "1. Milk\n2. Eggs\n3. Bread".
        if let finalLine = text.split(separator: "\n").last {
            let line = finalLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
                return text
            }
        }
        switch last {
        case ".", "?", "!", "…":
            return text
        case ",", ";", ":":
            return String(text.dropLast()) + "."
        case "\"", "'", ")", "”", "’":
            return text + "."
        default:
            return text + "."
        }
    }

    // MARK: - Enumeration detection

    /// Two or more ordinal/list markers means the speaker is dictating a
    /// structure the rules pass cannot typeset — that's the LLM's job.
    private static func containsEnumeration(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\b(first(?:ly)?|second(?:ly)?|third(?:ly)?|numbered|bullet(?: point)?s?|list|finally|lastly)\b"#) else {
            return false
        }
        let hits = regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        return hits >= 2
    }

    // MARK: - Token helpers

    private static func cleanedWord(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private static func endsSentenceBreak(_ token: String) -> Bool {
        guard let last = token.last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}
