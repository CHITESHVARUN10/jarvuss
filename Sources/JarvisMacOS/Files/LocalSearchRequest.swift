import Foundation
import CoreFoundation

enum LocalSearchKind: String, CaseIterable, Codable {
    case any, folder, pdf, presentation, document, spreadsheet, image, audio, video, mail, note

    var contentTypes: [String] {
        switch self {
        case .any: return []
        case .folder: return ["public.folder"]
        case .pdf: return ["com.adobe.pdf"]
        case .presentation: return ["public.presentation", "com.microsoft.powerpoint.ppt", "org.openxmlformats.presentationml.presentation", "com.apple.keynote.key"]
        case .document: return ["com.microsoft.word.doc", "org.openxmlformats.wordprocessingml.document"]
        case .spreadsheet: return ["public.spreadsheet", "com.microsoft.excel.xls", "org.openxmlformats.spreadsheetml.sheet", "com.apple.iwork.numbers.numbers"]
        case .image: return ["public.image"]
        case .audio: return ["public.audio"]
        case .video: return ["public.movie"]
        case .mail: return ["public.email-message", "com.apple.mail.emlx"]
        case .note: return ["com.apple.notes.note", "net.daringfireball.markdown", "public.plain-text"]
        }
    }
}

enum LocalSearchDate: String, CaseIterable, Codable {
    case any, today, yesterday, thisWeek = "this_week", lastWeek = "last_week"
    case thisMonth = "this_month", lastMonth = "last_month", last7Days = "last_7_days", last30Days = "last_30_days"

    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let start = calendar.startOfDay(for: now)
        switch self {
        case .any: return nil
        case .today: return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
        case .yesterday: return DateInterval(start: calendar.date(byAdding: .day, value: -1, to: start)!, end: start)
        case .thisWeek: return calendar.dateInterval(of: .weekOfYear, for: now)
        case .lastWeek: return calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -1, to: now)!)
        case .thisMonth: return calendar.dateInterval(of: .month, for: now)
        case .lastMonth: return calendar.dateInterval(of: .month, for: calendar.date(byAdding: .month, value: -1, to: now)!)
        case .last7Days: return DateInterval(start: calendar.date(byAdding: .day, value: -7, to: now)!, end: now)
        case .last30Days: return DateInterval(start: calendar.date(byAdding: .day, value: -30, to: now)!, end: now)
        }
    }
}

struct LocalSearchRequest: Equatable, Codable, CustomStringConvertible {
    enum Mode: String, Codable { case name, content }
    var query = ""
    var mode: Mode = .name
    var kind: LocalSearchKind = .any
    var scopes: [String] = []
    var date: LocalSearchDate = .any
    var minimumBytes: Int64 = 0
    var maximumBytes: Int64 = 0 // zero = no upper bound

    var arguments: [String: Any] {
        ["query": query, "mode": mode.rawValue, "kind": kind.rawValue,
         "scope": scopes.joined(separator: "|"), "date": date.rawValue,
         "min_bytes": minimumBytes, "max_bytes": maximumBytes]
    }

    var description: String {
        let data = try! JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    init(query: String = "", mode: Mode = .name, kind: LocalSearchKind = .any, scopes: [String] = [],
         date: LocalSearchDate = .any, minimumBytes: Int64 = 0, maximumBytes: Int64 = 0) {
        self.query = query; self.mode = mode; self.kind = kind; self.scopes = scopes
        self.date = date; self.minimumBytes = minimumBytes; self.maximumBytes = maximumBytes
    }

    init?(arguments: [String: Any]) {
        guard let query = arguments["query"] as? String,
              let mode = Mode(rawValue: arguments["mode"] as? String ?? ""),
              let kind = LocalSearchKind(rawValue: arguments["kind"] as? String ?? ""),
              let scope = arguments["scope"] as? String,
              let date = LocalSearchDate(rawValue: arguments["date"] as? String ?? ""),
              let minimum = Self.integer(arguments["min_bytes"]),
              let maximum = Self.integer(arguments["max_bytes"]),
              minimum >= 0, maximum >= 0, maximum == 0 || maximum >= minimum,
              query.count <= 512, scope.count <= 2048 else { return nil }
        self.init(query: query, mode: mode, kind: kind, scopes: scope.split(separator: "|").map(String.init),
                  date: date, minimumBytes: minimum, maximumBytes: maximum)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(Int64.max), double.rounded() == double else { return nil }
        return number.int64Value
    }

    func predicate(now: Date = Date(), calendar: Calendar = .current) -> NSPredicate {
        var terms: [NSPredicate] = []
        // Build predicates with bound values. A spoken query never becomes predicate syntax.
        if !query.isEmpty {
            let field = mode == .content ? "kMDItemTextContent" : "kMDItemFSName"
            // A multiword filename can contain separators or extra words between tokens.
            for token in query.split(whereSeparator: \.isWhitespace) {
                terms.append(NSPredicate(format: "%K CONTAINS[cd] %@", field, String(token)))
            }
        }
        if !kind.contentTypes.isEmpty {
            let types = kind.contentTypes.map {
                NSPredicate(format: "kMDItemContentTypeTree == %@", $0)
            }
            // NSMetadataQuery rejects one-child OR/AND predicates even
            // though NSPredicate.evaluate accepts them (PDF has one UTI).
            terms.append(types.count == 1 ? types[0] : NSCompoundPredicate(orPredicateWithSubpredicates: types))
        }
        if let interval = date.interval(now: now, calendar: calendar) {
            terms.append(NSPredicate(format: "kMDItemFSContentChangeDate >= %@ AND kMDItemFSContentChangeDate < %@",
                                     interval.start as NSDate, interval.end as NSDate))
        }
        if minimumBytes > 0 { terms.append(NSPredicate(format: "kMDItemFSSize >= %@", NSNumber(value: minimumBytes))) }
        if maximumBytes > 0 { terms.append(NSPredicate(format: "kMDItemFSSize <= %@", NSNumber(value: maximumBytes))) }
        if kind != .folder { terms.append(NSPredicate(format: "kMDItemContentType != %@", "public.folder")) }
        if terms.isEmpty { return NSPredicate(value: true) }
        return terms.count == 1 ? terms[0] : NSCompoundPredicate(andPredicateWithSubpredicates: terms)
    }
}

enum FileResultOperation: String, Codable { case open, preview, reveal }

struct FileResultSelection: Equatable {
    let operation: FileResultOperation
    let index: Int // one-based; zero refers to the selected row
}
