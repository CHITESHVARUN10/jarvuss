import Foundation

enum ParsedCommand: Equatable {
    case openApp(String)
    case closeApp(String)
    case createFile(String)
    case createFolder(String)
    case openFolder(String)
    case aiQuery(String)
    case ragQuery(String)
    case unknown(String)
    /// New: a resolved multi-step plan from ActionPlanner
    case multiAction([PlannedAction])
}

final class CommandParser {
    func parse(_ text: String) -> ParsedCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = trimmed.lowercased()

        if lowercase.hasPrefix("ask document ") || lowercase.hasPrefix("ask documents ") {
            let prefix = lowercase.hasPrefix("ask document ") ? "ask document " : "ask documents "
            let query = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return .ragQuery(String(query))
        }

        if lowercase.hasPrefix("search notes ") || lowercase.hasPrefix("search documents ") || lowercase.hasPrefix("search document ") {
            let prefix = lowercase.hasPrefix("search notes ") ? "search notes " : (lowercase.hasPrefix("search documents ") ? "search documents " : "search document ")
            let query = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return .ragQuery(String(query))
        }

        if lowercase.hasPrefix("launch ") {
            let target = trimmed.dropFirst("launch ".count).trimmingCharacters(in: .whitespaces)
            if target.lowercased().contains("browser") {
                return .openApp("Brave Browser")
            }
            return .openApp(String(target))
        }

        if lowercase.hasPrefix("start ") || lowercase.hasPrefix("run ") {
            let prefix = lowercase.hasPrefix("start ") ? "start " : "run "
            let target = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if target.lowercased().contains("browser") {
                return .openApp("Brave Browser")
            }
            return .openApp(String(target))
        }

        if lowercase.hasPrefix("open ") {
            let target = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if target.lowercased().contains("browser") {
                return .openApp("Brave Browser")
            }
            if lowercase.hasPrefix("open folder ") {
                let folder = trimmed.dropFirst("open folder ".count).trimmingCharacters(in: .whitespaces)
                return .openFolder(folder)
            }
            return .openApp(String(target))
        }

        if lowercase.hasPrefix("close ") {
            let target = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return .closeApp(String(target))
        }

        if lowercase.hasPrefix("create file ") {
            let filename = trimmed.dropFirst("create file ".count).trimmingCharacters(in: .whitespaces)
            return .createFile(String(filename))
        }

        if lowercase.hasPrefix("create folder ") {
            let folderName = trimmed.dropFirst("create folder ".count).trimmingCharacters(in: .whitespaces)
            return .createFolder(String(folderName))
        }

        if lowercase.starts(with: "explain ") || lowercase.starts(with: "what is ") || lowercase.starts(with: "who is ") {
            return .aiQuery(trimmed)
        }

        if lowercase.starts(with: "jarvis ") {
            return parse(String(trimmed.dropFirst("jarvis ".count)))
        }

        return .aiQuery(trimmed)
    }
}

