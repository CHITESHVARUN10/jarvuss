import Foundation

/// Native-only commands are routed before app aliases, quick device reads, and
/// the learned router in both Swift and Rust pipeline modes.
enum LocalSearchParser {
    static func route(_ text: String) -> PlannedAction? {
        let cleaned = clean(text)
        if let pane = SystemSettingsPane.parse(cleaned) { return .openSettings(pane) }
        if let selection = selection(cleaned) { return .fileResult(selection) }
        if let request = search(cleaned) { return .searchFiles(request) }
        return nil
    }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(?i)^(?:(?:hey\s+)?jarvis[, ]+|please\s+|(?:can|could|would) you\s+)+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
    }

    static func selection(_ text: String) -> FileResultSelection? {
        let lower = clean(text).lowercased()
        if let match = captures(#"^(?:just )?(open|preview|quick look|reveal|show in finder)(?: (?:it|that|this|the selected (?:file|result)))?$"#, lower) {
            return FileResultSelection(operation: operation(match[0]), index: 0)
        }
        let ordinals = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        guard let match = captures(#"^(?:(open|preview|quick look|reveal|show in finder) )?(?:the |result |file |number )?(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|[0-9]{1,3}(?:st|nd|rd|th)?)(?: one| result| file| item)?(?: in finder)?$"#, lower) else { return nil }
        let index = ordinals.firstIndex(of: match[1]).map { $0 + 1 }
            ?? Int(match[1].filter(\.isNumber)) ?? 0
        guard index > 0, index <= 100 else { return nil }
        return FileResultSelection(operation: operation(match[0]), index: index)
    }

    private static func operation(_ word: String) -> FileResultOperation {
        if word == "preview" || word == "quick look" { return .preview }
        if word == "reveal" || word == "show in finder" { return .reveal }
        return .open
    }

    static func search(_ text: String) -> LocalSearchRequest? {
        var remaining = clean(text)
        let lower = remaining.lowercased()
        let explicitFile = lower.range(of: #"\b(files?|folders?|documents?|pdfs?|ppts?|pptx|presentations?|powerpoints?|spreadsheets?|images?|photos?|notes?|emails?|mail|word|slides?)\b"#, options: .regularExpression) != nil
        let hasVerb = lower.range(of: #"^(find|locate|search|look for|show|list)\b"#, options: .regularExpression) != nil
        guard explicitFile || lower.hasPrefix("find ") || lower.hasPrefix("locate ") else { return nil }
        guard hasVerb || lower.range(of: #"^(pdfs?|ppts?|presentations?|documents?|files?|folders?|images?|notes?|emails?)\b"#, options: .regularExpression) != nil else { return nil }
        // Preserve the existing folder counts/listing and newest/oldest actions.
        if lower.range(of: #"\b(how many|count|oldest|newest|latest|largest|total size)\b"#, options: .regularExpression) != nil { return nil }
        if !explicitFile && lower.range(of: #"\b(google|youtube|web|internet)\b"#, options: .regularExpression) != nil { return nil }
        if lower.range(of: #"\b(?:and|then)\s+(?:open|play|close|delete|run|set|search|find)\b"#, options: .regularExpression) != nil { return nil }

        var request = LocalSearchRequest()
        // Pull out content first so filenames/types inside the quoted search
        // text do not accidentally become filters.
        var content = ""
        if let range = remaining.range(of: #"(?i)\b(?:that\s+)?(?:mentions?|mentioning|contains?|containing|with text|whose contents? (?:includes?|contains?))\s+(?:the phrase\s+)?"#, options: .regularExpression) {
            content = String(remaining[range.upperBound...])
            remaining = String(remaining[..<range.lowerBound])
            request.mode = .content
        }
        if content.isEmpty, lower.hasPrefix("search "),
           let range = remaining.range(of: #"(?i)\s+for\s+"#, options: .regularExpression) {
            content = String(remaining[range.upperBound...])
            remaining = String(remaining[..<range.lowerBound])
            request.mode = .content
        }

        var literalQuery: String?
        // Quoted names/content are literal: “yesterday in Downloads” must
        // not silently turn into a date filter and a folder scope.
        let quotedPattern = #"[\"“]([^\"”]+)[\"”]"#
        if request.mode == .content {
            if let regex = try? NSRegularExpression(pattern: quotedPattern),
               let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
               let whole = Range(match.range, in: content), let inside = Range(match.range(at: 1), in: content) {
                literalQuery = String(content[inside]); content.removeSubrange(whole)
            }
        } else if let regex = try? NSRegularExpression(pattern: quotedPattern),
                  let match = regex.firstMatch(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)),
                  let whole = Range(match.range, in: remaining), let inside = Range(match.range(at: 1), in: remaining) {
            literalQuery = String(remaining[inside]); remaining.removeSubrange(whole)
        }

        func remove(_ pattern: String, from value: inout String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range, in: value) else { return nil }
            let groups = (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: value).map { String(value[$0]) } ?? "" }
            value.replaceSubrange(range, with: " ")
            return groups
        }

        // Filters may follow the content phrase: "mentions curves in Downloads".
        var filters = request.mode == .content ? content : remaining
        let dates: [(String, LocalSearchDate)] = [
            (#"\b(?:from |modified |changed |updated )?last week\b"#, .lastWeek),
            (#"\b(?:from |modified |changed |updated )?this week\b"#, .thisWeek),
            (#"\b(?:from |modified |changed |updated )?last month\b"#, .lastMonth),
            (#"\b(?:from |modified |changed |updated )?this month\b"#, .thisMonth),
            (#"\b(?:from |modified (?:in )?|changed |updated )?(?:the )?(?:last|past) (?:7|seven) days\b"#, .last7Days),
            (#"\b(?:from |modified |changed |updated )?(?:the )?(?:last|past) (?:30|thirty) days\b"#, .last30Days),
            (#"\b(?:from |modified |changed |updated )?yesterday\b"#, .yesterday),
            (#"\b(?:from |modified |changed |updated )?today\b"#, .today),
        ]
        for (pattern, date) in dates {
            if remove(pattern, from: &filters) != nil { request.date = date; break }
        }
        for (pattern, minimum) in [(#"\b(?:bigger|larger|greater|more) than\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b"#, true),
                                    (#"\b(?:smaller|less) than\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b"#, false),
                                    (#"\b(?:over|above|at least)\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b"#, true),
                                    (#"\b(?:under|below|at most)\s+([0-9]+(?:\.[0-9]+)?)\s*(kb|mb|gb|bytes?)\b"#, false)] {
            if let match = remove(pattern, from: &filters), let amount = Double(match[0]) {
                let multiplier: Double = ["kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000][match[1].lowercased()] ?? 1
                let bytes = amount * multiplier
                guard bytes.isFinite, bytes > 0, bytes < Double(Int64.max) else { return nil }
                if minimum { request.minimumBytes = Int64(bytes.rounded(.up)) }
                else { request.maximumBytes = Int64(bytes.rounded(.down)) }
            }
        }
        if let match = remove(#"\b(?:(?:that|which)\s+)?(?:(?:may|might|could)\s+be\s+|maybe\s+)?(?:in|inside|within|under)\s+(?:either\s+)?(.+)$"#, from: &filters) {
            request.scopes = match[0].components(separatedBy: .init(charactersIn: ","))
                .flatMap { $0.components(separatedBy: " or ") }
                .flatMap { $0.components(separatedBy: " and ") }
                .map { $0.replacingOccurrences(of: #"(?i)^(?:my |the )+|\s+folders?$"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if request.mode == .content { content = filters } else { remaining = filters }

        // A location/date may precede “containing”, not just follow its text.
        if request.mode == .content {
            for (pattern, date) in dates {
                if remove(pattern, from: &remaining) != nil { request.date = date; break }
            }
            if let match = remove(#"\b(?:(?:that|which)\s+)?(?:(?:may|might|could)\s+be\s+|maybe\s+)?(?:in|inside|within|under)\s+(?:either\s+)?(.+)$"#, from: &remaining) {
                request.scopes += match[0].components(separatedBy: " or ")
                    .flatMap { $0.components(separatedBy: " and ") }
                    .map { $0.replacingOccurrences(of: #"(?i)^(?:my |the )+|\s+folders?$"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }

        let kinds: [(String, LocalSearchKind)] = [
            (#"\b(?:pdfs?)\b"#, .pdf), (#"\b(?:ppts?|pptx|powerpoints?|presentations?|slide decks?|slides?)\b"#, .presentation),
            (#"\b(?:spreadsheets?|excel files?|xlsx)\b"#, .spreadsheet), (#"\b(?:word documents?|word files?|docx)\b"#, .document),
            (#"\b(?:images?|photos?|pictures?)\b"#, .image), (#"\b(?:audio files?|music files?)\b"#, .audio),
            (#"\b(?:videos?|movies?)\b"#, .video), (#"\b(?:emails?|mail messages?|mail)\b"#, .mail),
            (#"\b(?:notes?)\b"#, .note), (#"\b(?:folders?)\b"#, .folder),
        ]
        let nameMarker = remaining.range(of: #"(?i)\b(?:named|called|titled)\b"#, options: .regularExpression)
        var kindPart = nameMarker.map { String(remaining[..<$0.lowerBound]) } ?? remaining
        let namePart = nameMarker.map { String(remaining[$0.lowerBound...]) } ?? ""
        for (pattern, kind) in kinds {
            if remove(pattern, from: &kindPart) != nil { request.kind = kind; break }
        }
        remaining = kindPart + namePart
        remaining = remaining.replacingOccurrences(of: #"(?i)^(?:find|locate|search(?: for)?|look for|show|list)\s+(?:me\s+)?"#, with: "", options: .regularExpression)
        remaining = remaining.replacingOccurrences(of: #"(?i)\b(?:files?|documents?)\b"#, with: "", options: .regularExpression)
        remaining = remaining.replacingOccurrences(of: #"(?i)^(?:(?:all|my|the|a|an|any|named|called|titled|about|on|for)\s+)+"#, with: "", options: .regularExpression)
        remaining = remaining.replacingOccurrences(of: #"(?i)\b(?:named|called|titled)\s+"#, with: "", options: .regularExpression)
        request.query = (literalQuery ?? (request.mode == .content ? content : remaining))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'“”‘’")))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard request.query.count <= 512, request.scopes.count <= 8,
              !request.query.isEmpty || request.kind != .any || request.date != .any || request.minimumBytes > 0 || request.maximumBytes > 0 || !request.scopes.isEmpty else { return nil }
        return request
    }

    static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}
