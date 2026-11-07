import Foundation

/// Rust interprets search/filter/result requests. Spotlight and native execution stay in Swift.
enum LocalSearchParser {
    static func route(_ text: String) -> PlannedAction? {
        let cleaned = clean(text)
        if let pane = SystemSettingsPane.parse(cleaned) { return .openSettings(pane) }
        if let selection = selection(cleaned) { return .fileResult(selection) }
        if let request = search(cleaned) { return .searchFiles(request) }
        return nil
    }
    static func clean(_ text: String) -> String { coreCleanSearchText(raw: text) }
    static func selection(_ text: String) -> FileResultSelection? {
        guard let value = coreParseFileSelection(raw: text) else { return nil }
        let operation: FileResultOperation
        switch value.operation {
        case .open: operation = .open
        case .preview: operation = .preview
        case .reveal: operation = .reveal
        }
        return FileResultSelection(operation: operation, index: Int(value.index))
    }
    static func search(_ text: String) -> LocalSearchRequest? {
        guard let value = coreParseFileSearch(raw: text) else { return nil }
        let kind: LocalSearchKind
        switch value.kind {
        case .any: kind = .any
        case .folder: kind = .folder
        case .pdf: kind = .pdf
        case .presentation: kind = .presentation
        case .document: kind = .document
        case .spreadsheet: kind = .spreadsheet
        case .image: kind = .image
        case .audio: kind = .audio
        case .video: kind = .video
        case .mail: kind = .mail
        case .note: kind = .note
        }
        let date: LocalSearchDate
        switch value.date {
        case .any: date = .any
        case .today: date = .today
        case .yesterday: date = .yesterday
        case .thisWeek: date = .thisWeek
        case .lastWeek: date = .lastWeek
        case .thisMonth: date = .thisMonth
        case .lastMonth: date = .lastMonth
        case .last7Days: date = .last7Days
        case .last30Days: date = .last30Days
        }
        let mode: LocalSearchRequest.Mode
        switch value.mode { case .name: mode = .name; case .content: mode = .content }
        return LocalSearchRequest(query: value.query, mode: mode, kind: kind, scopes: value.scopes,
                                  date: date, minimumBytes: value.minimumBytes, maximumBytes: value.maximumBytes)
    }

    // Regex helper retained for the native settings-pane adapter.
    static func captures(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
}
