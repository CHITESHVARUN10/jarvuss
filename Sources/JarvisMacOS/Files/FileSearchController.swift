import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewTarget: Identifiable {
    var id: String { url.path }
    let url: URL
}

@MainActor
final class FileSearchController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = FileSearchController()
    @Published var draft = LocalSearchRequest()
    @Published private(set) var results: [FileSearchResult] = []
    @Published private(set) var searching = false
    @Published private(set) var status = ""
    @Published var selectedID: String?
    @Published var preview: FilePreviewTarget?
    @Published private(set) var hasContext = false
    private let engine: FileSearching
    private let locations: FileSearchLocationStore
    private let presentsUI: Bool
    private let openFile: (URL) -> Bool
    private let revealFile: (URL) -> Void
    private let now: () -> Date
    private var contextDate: Date?
    private var generation = UUID()
    private var task: Task<FileSearchSnapshot, Error>?
    private var panel: NSPanel?

    init(engine: FileSearching? = nil, locations: FileSearchLocationStore? = nil,
         presentsUI: Bool = true, openFile: ((URL) -> Bool)? = nil,
         revealFile: ((URL) -> Void)? = nil, now: @escaping () -> Date = Date.init) {
        self.engine = engine ?? SpotlightFileSearch(); self.locations = locations ?? .shared; self.presentsUI = presentsUI; self.now = now
        self.openFile = openFile ?? { NSWorkspace.shared.open($0) }
        self.revealFile = revealFile ?? { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    }

    @discardableResult
    func search(_ request: LocalSearchRequest) async -> ControllerResult {
        task?.cancel()
        let id = UUID(); generation = id
        draft = request; results = []; selectedID = nil; preview = nil
        hasContext = true; contextDate = nil; searching = true
        status = "Searching the Spotlight index…"
        present()
        defer { if generation == id { searching = false; task = nil } }
        do {
            let roots = try locations.resolve(request.scopes)
            let engine = self.engine
            let work = Task { try await engine.search(request, roots: roots) }
            task = work
            let snapshot = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            guard generation == id, !Task.isCancelled else { throw CancellationError() }
            results = snapshot.results
            selectedID = results.first?.id
            contextDate = now()
            let noun = results.count == 1 ? "result" : "results"
            status = snapshot.timedOut ? "Search timed out. Showing \(results.count) results collected so far; try a narrower search."
                : snapshot.limited ? "Showing the first \(results.count) results. Refine your search to see other matches."
                : results.isEmpty ? "No indexed matches. Check the folder, search words, Spotlight exclusions, and macOS folder access."
                : "\(results.count) \(noun). Select a file, or say ‘open the second one’ with ⌘⇧A."
            return ControllerResult(message: status, success: !snapshot.timedOut)
        } catch {
            guard generation == id else { return ControllerResult(message: "Search replaced by a newer request.", success: false) }
            status = error is CancellationError ? "Search cancelled." : error.localizedDescription
            return ControllerResult(message: status, success: false)
        }
    }

    @discardableResult
    func act(_ selection: FileResultSelection) -> ControllerResult {
        guard (0...100).contains(selection.index) else { return fail("Choose a numbered result from this list.") }
        guard hasContext, !searching, let contextDate, now().timeIntervalSince(contextDate) < 600 else {
            return fail("Find a file first. File selections expire after 10 minutes or when the results window is closed.")
        }
        let target: FileSearchResult?
        if selection.index == 0 { target = results.first { $0.id == selectedID } }
        else { target = results.indices.contains(selection.index - 1) ? results[selection.index - 1] : nil }
        guard let target else { return fail("That result is not in this list. Choose one of the numbered files.") }
        guard FileManager.default.fileExists(atPath: target.url.path) else {
            return fail("‘\(target.name)’ is no longer available. Connect its drive or search again.")
        }
        selectedID = target.id
        switch selection.operation {
        case .open:
            // A file result is a document, never a route to running a script or app.
            let executableExtensions: Set<String> = ["app", "command", "sh", "bash", "zsh", "scpt", "workflow", "webloc", "url"]
            let type = try? target.url.resourceValues(forKeys: [.contentTypeKey]).contentType
            guard !executableExtensions.contains(target.url.pathExtension.lowercased()),
                  type?.conforms(to: .executable) != true, type?.conforms(to: .application) != true,
                  type?.conforms(to: .script) != true else {
                return fail("Use Preview or Show in Finder for executable files and shortcuts.")
            }
            guard openFile(target.url) else { return fail("macOS could not open ‘\(target.name)’. Try Preview or Show in Finder.") }
            status = "Opened \(target.name)."
        case .preview:
            preview = FilePreviewTarget(url: target.url)
            present()
            status = "Previewing \(target.name)."
        case .reveal:
            revealFile(target.url)
            status = "Showing \(target.name) in Finder."
        }
        return ControllerResult(message: status, success: true)
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; searching = false
        status = "Search cancelled."
    }

    func close() {
        cancel(); hasContext = false; contextDate = nil; results = []; selectedID = nil; preview = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { close() }

    private func fail(_ message: String) -> ControllerResult {
        status = message
        return ControllerResult(message: message, success: false)
    }

    private func present() {
        guard presentsUI else { return }
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.title = "Jarvis · File search"
            window.contentMinSize = NSSize(width: 660, height: 420)
            window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.delegate = self
            window.contentView = NSHostingView(rootView: FileSearchResultsView(model: self).preferredColorScheme(.dark))
            window.center()
            panel = window
        }
        panel?.orderFrontRegardless()
    }
}
