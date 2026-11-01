import AppKit

struct ProjectLocation: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var path: String
    var isRoot: Bool
    var bookmark: Data?
    func url() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

@MainActor
final class ProjectLocationStore: ObservableObject {
    static let shared = ProjectLocationStore()
    @Published var locations: [ProjectLocation] {
        didSet { save() }
    }
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private static let key = "jarvis.workspace.projectLocations"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        locations = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ProjectLocation].self, from: $0) } ?? []
    }
    private func save() {
        do { defaults.set(try JSONEncoder().encode(locations), forKey: Self.key); error = nil }
        catch { self.error = "Project locations could not be saved: \(error.localizedDescription)" }
    }
    func choose(isRoot: Bool) {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = true
        picker.prompt = isRoot ? "Add project root" : "Add project alias"
        picker.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self else { return }
                for url in picker.urls where !self.locations.contains(where: { $0.url().standardizedFileURL == url.standardizedFileURL && $0.isRoot == isRoot }) {
                    let bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
                        ?? (try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
                    self.locations.append(ProjectLocation(name: url.lastPathComponent, path: url.path, isRoot: isRoot, bookmark: bookmark))
                }
            }
        }
    }
}

struct ProjectMatch: Identifiable, Equatable {
    var id: String { url.path }
    var url: URL
    var rootName: String
}

enum ProjectResolutionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum ProjectDirectoryResolver {
    static func normalize(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func find(_ query: String, root: String = "", locations: [ProjectLocation], maxEntries: Int = 10_000, maxDepth: Int = 3, preferDirect: Bool = true) throws -> [ProjectMatch] {
        guard !query.contains("/"), !query.contains("\\"), query != ".", query != "..", !query.contains("\0") else {
            throw ProjectResolutionError.message("Use a project name or saved alias, rather than a path.")
        }
        guard (query.isEmpty || !normalize(query).isEmpty), (root.isEmpty || !normalize(root).isEmpty) else {
            throw ProjectResolutionError.message("Use a project or root name containing letters or numbers.")
        }
        let rootKey = normalize(root)
        let roots = locations.filter { $0.isRoot && (rootKey.isEmpty || normalize($0.name) == rootKey) }
        if !rootKey.isEmpty && roots.isEmpty { throw ProjectResolutionError.message("No project root named ‘\(root)’. Add it in System → Project locations.") }
        let key = normalize(query)
        let aliases = locations.filter { !$0.isRoot && normalize($0.name) == key && !key.isEmpty }
        var matches: [ProjectMatch] = []
        func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        for alias in aliases {
            let url = alias.url().standardizedFileURL.resolvingSymlinksInPath()
            if !rootKey.isEmpty && !roots.contains(where: { within(url, root: $0.url().resolvingSymlinksInPath()) }) { continue }
            guard isDirectory(url) else { throw ProjectResolutionError.message("The saved project ‘\(alias.name)’ is unavailable. Connect its drive or choose the folder again.") }
            matches.append(ProjectMatch(url: url, rootName: alias.name))
        }
        if !matches.isEmpty { return unique(matches) }
        guard !roots.isEmpty else { throw ProjectResolutionError.message("Add a project root or project alias in System → Project locations first.") }
        // A root's immediate project folders take precedence over nested
        // dependencies or unrelated directories with the same name.
        if preferDirect && maxDepth > 1 {
            let direct = try find(query, root: root, locations: locations, maxEntries: maxEntries, maxDepth: 1, preferDirect: false)
            if !direct.isEmpty { return direct }
        }
        let excluded: Set<String> = ["node_modules", "vendor", "build", "dist", "target", "pods", "__pycache__", "venv"]
        var visited = Set<String>(), entries = 0, unavailable: [String] = []
        let deadline = Date().addingTimeInterval(3)
        for saved in roots {
            let rootURL = saved.url().standardizedFileURL.resolvingSymlinksInPath()
            let access = rootURL.startAccessingSecurityScopedResource()
            defer { if access { rootURL.stopAccessingSecurityScopedResource() } }
            guard isDirectory(rootURL) else { unavailable.append(saved.name); continue }
            var pending: [(URL, Int)] = [(rootURL, 0)]
            var cursor = 0
            while cursor < pending.count {
                try Task.checkCancellation()
                guard Date() < deadline else { throw ProjectResolutionError.message("Project lookup timed out. Choose a narrower root or add a project alias.") }
                let (parent, depth) = pending[cursor]; cursor += 1
                guard visited.insert(parent.path).inserted else { continue }
                let children: [URL]
                do { children = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) }
                catch { throw ProjectResolutionError.message("Cannot read ‘\(parent.lastPathComponent)’. Check folder access in System → Project locations.") }
                for child in children {
                    entries += 1
                    guard entries <= maxEntries else { throw ProjectResolutionError.message("Project lookup reached its limit. Choose a narrower root or add a project alias.") }
                    let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                    let url = child.standardizedFileURL.resolvingSymlinksInPath()
                    guard within(url, root: rootURL), !excluded.contains(child.lastPathComponent.lowercased()) else { continue }
                    if key.isEmpty || normalize(child.lastPathComponent) == key { matches.append(ProjectMatch(url: url, rootName: saved.name)) }
                    if depth + 1 < maxDepth { pending.append((url, depth + 1)) }
                }
            }
        }
        if !unavailable.isEmpty { throw ProjectResolutionError.message("Project roots unavailable: \(unavailable.joined(separator: ", ")). Connect their drives or remove them in System → Project locations.") }
        return unique(matches).sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }
    private static func within(_ url: URL, root: URL) -> Bool { root.path == "/" || url.path == root.path || url.path.hasPrefix(root.path + "/") }
    private static func unique(_ matches: [ProjectMatch]) -> [ProjectMatch] {
        var seen = Set<String>(); return matches.filter { seen.insert($0.id).inserted }
    }
}
