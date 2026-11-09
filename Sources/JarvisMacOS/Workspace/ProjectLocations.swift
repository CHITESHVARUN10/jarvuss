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
        didSet { save(); indexObserver.watch(locations.filter(\.isRoot).map { $0.url().path }) }
    }
    @Published private(set) var error: String?
    private let defaults: UserDefaults
    private let indexObserver = ProjectIndexObserver()
    private static let key = "jarvis.workspace.projectLocations"
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        locations = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([ProjectLocation].self, from: $0) } ?? []
        indexObserver.watch(locations.filter(\.isRoot).map { $0.url().path })
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
    static func find(_ query: String, root: String = "", locations: [ProjectLocation], maxEntries: Int = 10_000, maxDepth: Int = 3, preferDirect: Bool = true, useIndex: Bool = false) throws -> [ProjectMatch] {
        try Task.checkCancellation()
        let inputs = locations.map {
            CoreProjectLocationInput(name: $0.name, path: $0.url().path, isRoot: $0.isRoot)
        }
        // Aliases may be the only saved access grant for a project outside
        // the roots. Keep those bookmark grants active during native lookup.
        let urls = locations.map { $0.url() }
        let accesses = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        defer {
            for (url, access) in accesses where access {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let lookup = useIndex ? coreFindIndexedProjects : coreFindProjects
        let result = lookup(
            query, root, inputs, UInt32(clamping: maxEntries), UInt32(clamping: maxDepth), preferDirect
        )
        try Task.checkCancellation()
        if let message = result.error {
            throw ProjectResolutionError.message(message)
        }
        return result.matches
            .map { ProjectMatch(url: URL(fileURLWithPath: $0.path, isDirectory: true),
                                rootName: $0.rootName) }
            .sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

}
