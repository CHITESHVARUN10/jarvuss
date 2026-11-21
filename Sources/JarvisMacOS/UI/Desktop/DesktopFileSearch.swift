import AppKit

@MainActor
extension FileSearchController {
    static var desktopSearchControls: [String: Any] {
        [
            "kinds": LocalSearchKind.allCases.map { ["value": $0.rawValue, "title": $0.label] },
            "dates": LocalSearchDate.allCases.map { ["value": $0.rawValue, "title": $0.label] }
        ]
    }

    var desktopSearchValues: [String: Any] {
        [
            "selectedID": selectedID ?? "", "searching": searching, "status": status,
            "hasContext": hasContext, "draft": desktopDraft,
            "files": results.map {
                ["id": $0.id, "name": $0.name, "folder": $0.url.deletingLastPathComponent().lastPathComponent,
                 "size": $0.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file),
                 "date": $0.modified.formatted(date: .abbreviated, time: .omitted)]
            }
        ]
    }

    var desktopDraft: [String: Any] {
        [
            "query": draft.query, "scope": draft.scopes.joined(separator: "|"),
            "mode": draft.mode.rawValue, "kind": draft.kind.rawValue, "date": draft.date.rawValue,
            "minBytes": draft.minimumBytes, "maxBytes": draft.maximumBytes
        ]
    }

    func handleDesktopSearch(_ action: String, _ args: [String: Any]) async throws -> Any? {
        switch action {
        case "searchState": return desktopSearchValues
        case "closeSearch": close()
        case "cancelSearch": cancel()
        case "selectFile":
            if let id = args["id"] as? String, results.contains(where: { $0.id == id }) { selectedID = id }
        case "search":
            let fields: [String: Any] = [
                "query": args["query"] ?? "", "mode": args["mode"] ?? "", "kind": args["kind"] ?? "",
                "scope": args["scope"] ?? "", "date": args["date"] ?? "",
                "min_bytes": args["minBytes"] ?? 0, "max_bytes": args["maxBytes"] ?? 0
            ]
            guard let request = LocalSearchRequest(arguments: fields) else {
                throw DesktopUIError("Check the search words and filters.")
            }
            await search(request)
        case "fileAction":
            let name = args["operation"] as? String ?? ""
            guard let operation = FileResultOperation(rawValue: name == "finder" ? "reveal" : name),
                  let index = args["index"] as? Int else { throw DesktopUIError("Choose a result first.") }
            let result = act(FileResultSelection(operation: operation, index: index))
            return ["success": result.success, "message": result.message]
        default: throw DesktopUIError("Unknown file search action.")
        }
        return nil
    }
}
