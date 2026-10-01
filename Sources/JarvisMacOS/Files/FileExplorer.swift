import Foundation
import AppKit

/// What the user wants to know or do inside a folder.
enum FileQueryOp: String, CaseIterable {
    case count        // "how many files are in downloads"
    case countFolders // "how many folders are in downloads"
    case list         // "list the files in downloads"
    case listFolders  // "what folders are in downloads"
    case largest      // "what is the biggest file in downloads"
    case oldest       // "what is the oldest pdf i have"
    case newest       // "what is the latest ppt"
    case totalSize    // "how much space do my pdfs take"
    case openNewest   // "open the most recent pdf"
    case openOldest   // "open the oldest pdf"

    var wantsOpen: Bool { self == .openNewest || self == .openOldest }
    var wantsNewestFirst: Bool { self == .newest || self == .openNewest }
}

/// Resolves spoken folder names and answers file questions with FileManager —
/// no shell, so nothing a transcript contains can ever reach a command line.
struct FileExplorer {

    /// Spoken extensions → the suffix macOS actually stores. People say "ppt"
    /// and "jpeg"; the model emits both forms, so normalize at the boundary.
    static func canonicalExtension(_ raw: String) -> String {
        let key = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch key {
        case "ppt":     return "pptx"
        case "doc":     return "docx"
        case "xls":     return "xlsx"
        case "jpeg":    return "jpg"
        case "tif":     return "tiff"
        case "yaml":    return "yml"
        case "text":    return "txt"
        case "markdown": return "md"
        default:        return key
        }
    }

    // MARK: - Folder resolution

    /// Spoken names → real locations. Only these roots are ever touched.
    static func resolveFolder(_ spoken: String) -> URL? {
        let key = spoken.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " folder", with: "")
            .replacingOccurrences(of: " my ", with: " ")
            .trimmingCharacters(in: .whitespaces)

        let home = FileManager.default.homeDirectoryForCurrentUser
        let table: [String: URL] = [
            "downloads": home.appendingPathComponent("Downloads"),
            "download": home.appendingPathComponent("Downloads"),
            "documents": home.appendingPathComponent("Documents"),
            "document": home.appendingPathComponent("Documents"),
            "docs": home.appendingPathComponent("Documents"),
            "desktop": home.appendingPathComponent("Desktop"),
            "pictures": home.appendingPathComponent("Pictures"),
            "photos": home.appendingPathComponent("Pictures"),
            "images": home.appendingPathComponent("Pictures"),
            "movies": home.appendingPathComponent("Movies"),
            "videos": home.appendingPathComponent("Movies"),
            "music": home.appendingPathComponent("Music"),
            "home": home,
        ]
        for (name, url) in table where key.contains(name) {
            return url
        }
        return nil
    }

    // MARK: - Enumeration

    struct Entry {
        let name: String
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let modified: Date
    }

    /// Non-recursive listing of one folder — the depth every spoken question
    /// implies ("what's in my downloads").
    static func entries(in folder: URL, ext: String?) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let wanted = ext.map { canonicalExtension($0) }
        guard let listing = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return listing.compactMap { url -> Entry? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isDir = values.isDirectory ?? false
            if let wanted, !wanted.isEmpty {
                guard !isDir else { return nil }
                guard url.pathExtension.lowercased() == wanted else { return nil }
            }
            return Entry(
                name: url.lastPathComponent,
                url: url,
                isDirectory: isDir,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
    }

    // MARK: - Answering

    /// Returns the spoken answer plus, for open-style queries, the URL to open.
    static func answer(op: FileQueryOp, folder: URL, ext: String?) -> (message: String, open: URL?) {
        let normalized = ext.map { canonicalExtension($0) }
        let extLabel = (normalized?.isEmpty ?? true) ? nil : normalized!.uppercased()
        let folderName = folder.lastPathComponent
        let items = entries(in: folder, ext: ext)

        func describe(_ entry: Entry) -> String {
            "\(entry.name) (\(formatSize(entry.size)), \(formatDate(entry.modified)))"
        }

        switch op {
        case .count:
            let files = items.filter { !$0.isDirectory }
            let noun = extLabel.map { "\($0) file" } ?? "file"
            let plural = files.count == 1 ? "" : "s"
            var message = "You have \(files.count) \(noun)\(plural) in \(folderName)."
            if let newest = files.max(by: { $0.modified < $1.modified }) {
                message += " The most recent is \(newest.name)."
            }
            return (message, nil)

        case .countFolders:
            let folders = items.filter(\.isDirectory)
            let plural = folders.count == 1 ? "" : "s"
            var message = "\(folderName) has \(folders.count) folder\(plural)."
            if !folders.isEmpty {
                message += " " + folders.prefix(6).map(\.name).joined(separator: ", ") + "."
            }
            return (message, nil)

        case .list:
            let files = items.filter { !$0.isDirectory }
            guard !files.isEmpty else {
                return ("There are no \(extLabel.map { "\($0) " } ?? "")files in \(folderName).", nil)
            }
            let names = files
                .sorted { $0.modified > $1.modified }
                .prefix(10)
                .map(\.name)
                .joined(separator: ", ")
            let extra = files.count > 10 ? " …and \(files.count - 10) more" : ""
            return ("\(files.count) files in \(folderName): \(names)\(extra).", nil)

        case .listFolders:
            let folders = items.filter(\.isDirectory)
            guard !folders.isEmpty else { return ("\(folderName) has no subfolders.", nil) }
            let names = folders.map(\.name).sorted().prefix(12).joined(separator: ", ")
            return ("\(folders.count) folders in \(folderName): \(names).", nil)

        case .largest:
            guard let biggest = items.filter({ !$0.isDirectory }).max(by: { $0.size < $1.size }) else {
                return ("No files to compare in \(folderName).", nil)
            }
            return ("The largest is \(describe(biggest)).", nil)

        case .oldest:
            guard let oldest = items.filter({ !$0.isDirectory }).min(by: { $0.modified < $1.modified }) else {
                return ("I found no \(extLabel.map { "\($0) " } ?? "")files in \(folderName).", nil)
            }
            return ("The oldest \(extLabel.map { "\($0) " } ?? "")file is \(describe(oldest)).", nil)

        case .newest:
            guard let newest = items.filter({ !$0.isDirectory }).max(by: { $0.modified < $1.modified }) else {
                return ("I found no \(extLabel.map { "\($0) " } ?? "")files in \(folderName).", nil)
            }
            return ("The most recent \(extLabel.map { "\($0) " } ?? "")file is \(describe(newest)).", nil)

        case .totalSize:
            let files = items.filter { !$0.isDirectory }
            let total = files.reduce(Int64(0)) { $0 + $1.size }
            let noun = extLabel.map { "\($0) files" } ?? "files"
            return ("Your \(files.count) \(noun) in \(folderName) take \(formatSize(total)).", nil)

        case .openNewest, .openOldest:
            let files = items.filter { !$0.isDirectory }
            let picked = op == .openNewest
                ? files.max(by: { $0.modified < $1.modified })
                : files.min(by: { $0.modified < $1.modified })
            guard let target = picked else {
                return ("I found no \(extLabel.map { "\($0) " } ?? "")files in \(folderName) to open.", nil)
            }
            return ("Opening \(target.name).", target.url)
        }
    }

    // MARK: - Formatting

    static func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}
