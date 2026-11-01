import AppKit
import SwiftUI

@MainActor
final class ProjectWorkspaceController {
    static let shared = ProjectWorkspaceController()
    private let store: ProjectLocationStore
    private let choose: ([ProjectMatch]) async -> ProjectMatch?
    private let open: (WorkspaceCommand, URL?) async throws -> String
    private let now: () -> Date
    private var recent: (url: URL, date: Date, locations: [ProjectLocation])?
    init(store: ProjectLocationStore? = nil,
         choose: @escaping ([ProjectMatch]) async -> ProjectMatch? = { await ProjectChoicePanel.shared.choose($0) },
         open: @escaping (WorkspaceCommand, URL?) async throws -> String = { try await NativeWorkspaceController().perform($0, folder: $1) },
         now: @escaping () -> Date = Date.init) {
        self.store = store ?? .shared; self.choose = choose; self.open = open; self.now = now
    }
    func execute(_ command: WorkspaceCommand) async -> ControllerResult {
        do {
            try Task.checkCancellation()
            guard command.operation == .openProject else {
                return ControllerResult(message: try await open(command, nil), success: true)
            }
            guard [.finder, .vscode, .terminal].contains(command.app) else {
                return ControllerResult(message: "Projects can open in Finder, VS Code, or Terminal.", success: false)
            }
            let locations = store.locations
            let target: URL
            if command.project == "@recent" {
                guard command.root.isEmpty else { throw ProjectResolutionError.message("Name the project when specifying a project root.") }
                guard let recent, now().timeIntervalSince(recent.date) < 600, recent.locations == locations else {
                    self.recent = nil
                    return ControllerResult(message: "Open a named project first. Project references expire after 10 minutes or when saved locations change.", success: false)
                }
                target = recent.url
            } else {
                let task = Task.detached(priority: .userInitiated) {
                    try ProjectDirectoryResolver.find(command.project, root: command.root, locations: locations)
                }
                let matches = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                guard !matches.isEmpty else { return ControllerResult(message: "No project named ‘\(command.project)’ in your configured roots. Add a project alias or choose a narrower root in System → Project locations.", success: false) }
                if matches.count == 1, !command.project.isEmpty { target = matches[0].url }
                else {
                    guard let selection = await choose(matches), matches.contains(selection) else {
                        return ControllerResult(message: "Project selection cancelled.", success: false)
                    }
                    target = selection.url
                }
            }
            try Task.checkCancellation()
            guard store.locations == locations else { throw ProjectResolutionError.message("Project locations changed during lookup. Try again.") }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &directory), directory.boolValue else {
                self.recent = nil
                throw ProjectResolutionError.message("The project folder is unavailable. Connect its drive or choose it again.")
            }
            let message = try await open(command, target)
            try Task.checkCancellation()
            recent = (target, now(), locations)
            return ControllerResult(message: message, success: true)
        } catch is CancellationError { return ControllerResult(message: "Workspace command cancelled.", success: false) }
        catch { return ControllerResult(message: error.localizedDescription, success: false) }
    }
}

@MainActor
private final class ProjectChoicePanel: NSObject, NSWindowDelegate {
    static let shared = ProjectChoicePanel()
    private var panel: NSPanel?
    private var continuation: CheckedContinuation<ProjectMatch?, Never>?
    func choose(_ choices: [ProjectMatch]) async -> ProjectMatch? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                finish(nil)
                self.continuation = continuation
                let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                panel.title = "Jarvis · Choose project"; panel.isReleasedWhenClosed = false; panel.delegate = self
                panel.contentView = NSHostingView(rootView: ProjectChoiceView(choices: choices) { [weak self] in self?.finish($0) })
                panel.center(); self.panel = panel
                NSApp.activate(ignoringOtherApps: true); panel.makeKeyAndOrderFront(nil)
            }
        } onCancel: { Task { @MainActor in self.finish(nil) } }
    }
    func windowWillClose(_ notification: Notification) { finish(nil) }
    private func finish(_ match: ProjectMatch?) {
        let current = continuation; continuation = nil
        panel?.orderOut(nil); panel = nil; current?.resume(returning: match)
    }
}

private struct ProjectChoiceView: View {
    let choices: [ProjectMatch]
    let choose: (ProjectMatch?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose a project").font(.headline)
            Text("Several folders match. Select the one you want to open.").foregroundStyle(.secondary)
            List(choices) { choice in
                Button { choose(choice) } label: {
                    VStack(alignment: .leading) {
                        Text("\(choice.url.lastPathComponent) · \(choice.rootName)")
                        Text(choice.url.path).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            Button("Cancel", role: .cancel) { choose(nil) }.keyboardShortcut(.cancelAction)
        }.padding(20).preferredColorScheme(.dark)
    }
}

struct NoirProjectPreferences: View {
    @ObservedObject private var store = ProjectLocationStore.shared
    var body: some View {
        NoirSectionHeading(title: "Project locations")
        NoirCard(padded: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add the folder containing your projects, such as your development drive. Say ‘open my portfolio project in VS Code’ or ‘open it in Terminal’.")
                    .font(.system(size: 12)).foregroundStyle(NoirPalette.secondary)
                Text("Roots search up to three folder levels. Add an alias for a specific project outside that range. Project names and paths stay on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(NoirPalette.muted)
                ForEach($store.locations) { $location in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(location.isRoot ? "Root name" : "Project alias", text: $location.name).textFieldStyle(.plain)
                            Text("\(location.isRoot ? "Root" : "Alias") · \(location.path)").font(.caption).foregroundStyle(NoirPalette.muted).lineLimit(1).truncationMode(.middle)
                        }
                        Button { store.locations.removeAll { $0.id == location.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(location.name)")
                    }
                }
                HStack {
                    Button("Add project root…") { store.choose(isRoot: true) }
                    Button("Add project alias…") { store.choose(isRoot: false) }
                }.buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                if let error = store.error { Text(error).foregroundStyle(.red) }
            }
        }
    }
}
