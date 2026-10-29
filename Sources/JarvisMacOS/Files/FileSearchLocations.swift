import AppKit

struct FileSearchLocation: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
}

@MainActor
final class FileSearchLocationStore: ObservableObject {
    static let shared = FileSearchLocationStore()
    @Published var locations: [FileSearchLocation] {
        didSet { if let data = try? JSONEncoder().encode(locations) { defaults.set(data, forKey: Self.key) } }
    }
    private static let key = "jarvis.files.searchLocations"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        locations = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([FileSearchLocation].self, from: $0) } ?? []
    }

    func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseFiles = false; picker.canChooseDirectories = true
        picker.allowsMultipleSelection = true
        picker.prompt = "Add search folder"
        picker.begin { [weak self] result in
            guard result == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in picker.urls where !self.locations.contains(where: { $0.path == url.path }) {
                    self.locations.append(FileSearchLocation(name: url.lastPathComponent, path: url.path))
                }
            }
        }
    }

    func resolve(_ scopes: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                 discovered: [URL]? = nil) throws -> [URL] {
        guard !scopes.isEmpty else { return [] }
        let children = discovered ?? ((try? FileManager.default.contentsOfDirectory(at: home,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            + (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
        return try Self.resolve(scopes, saved: locations, home: home, discovered: children)
    }

    static func resolve(_ scopes: [String], saved: [FileSearchLocation], home: URL, discovered: [URL]) throws -> [URL] {
        let builtins = ["downloads": "Downloads", "download": "Downloads", "documents": "Documents", "docs": "Documents",
                        "desktop": "Desktop", "pictures": "Pictures", "photos": "Pictures", "movies": "Movies", "videos": "Movies", "music": "Music"]
        var resolved: [URL] = []
        for scope in scopes {
            let key = normalize(scope)
            let url: URL
            if key == "home" { url = home }
            else if let component = builtins[key] { url = home.appendingPathComponent(component) }
            else if scope.hasPrefix("/") || scope.hasPrefix("~/") {
                url = URL(fileURLWithPath: (scope as NSString).expandingTildeInPath)
            } else {
                // URL directory hints/trailing slashes can differ for a saved
                // path and the same discovered folder. Compare canonical paths.
                let candidates = saved.map { (normalize($0.name), URL(fileURLWithPath: $0.path)) }
                    + discovered.map { (normalize($0.lastPathComponent), $0) }
                var matches = Set(candidates.filter { $0.0 == key }.map { $0.1.standardizedFileURL.path })
                // Exact names win. Only use a simple singular/plural alias
                // when it resolves to one location (PDF ↔ PDFs).
                if matches.isEmpty {
                    matches = Set(candidates.filter { $0.0 == key + "s" || $0.0 + "s" == key }
                        .map { $0.1.standardizedFileURL.path })
                }
                guard matches.count == 1, let match = matches.first else {
                    throw SearchError.location("Choose ‘\(scope)’ in System → File search, or use its full folder path.\(matches.count > 1 ? " More than one location has that name." : "")")
                }
                url = URL(fileURLWithPath: match, isDirectory: true)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw SearchError.location("The folder ‘\(scope)’ is unavailable. Connect its drive or choose it again in System → File search.")
            }
            if !resolved.contains(url.standardizedFileURL) { resolved.append(url.standardizedFileURL) }
        }
        return resolved
    }

    static func normalize(_ name: String) -> String { name.lowercased().filter { $0.isLetter || $0.isNumber } }
}

enum SearchError: LocalizedError {
    case location(String), unavailable, cancelled
    var errorDescription: String? {
        switch self {
        case .location(let message): return message
        case .unavailable: return "Spotlight could not start this search. Check System Settings → Spotlight and folder access."
        case .cancelled: return "Search cancelled."
        }
    }
}
