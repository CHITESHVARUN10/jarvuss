import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers

struct FileSearchResultsView: View {
    @ObservedObject var model: FileSearchController
    @ObservedObject private var locations = FileSearchLocationStore.shared
    @FocusState private var queryFocused: Bool

    private var selected: FileSearchResult? { model.results.first { $0.id == model.selectedID } }
    private var canAct: Bool { !model.searching && selected != nil }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Rectangle().fill(NoirPalette.line).frame(height: 1)
            columnHead
            if model.searching {
                emptyState(icon: "magnifyingglass", title: "Finding your files", detail: "Searching the selected locations…")
            } else if model.results.isEmpty {
                emptyState(icon: "doc.text.magnifyingglass", title: "No files found", detail: model.status.isEmpty
                    ? "Try another name, folder, or date range." : model.status)
            } else {
                List(selection: $model.selectedID) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, index: index)
                            .tag(item.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowSeparator(.hidden)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { act(.open, index: index + 1) })
                            .contextMenu {
                                Button("Open") { act(.open, index: index + 1) }
                                Button("Quick Look") { act(.preview, index: index + 1) }
                                Button("Show in Finder") { act(.reveal, index: index + 1) }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .tint(NoirPalette.accent)
                .onKeyPress(.space) { act(.preview); return .handled }
                .onKeyPress(.return) { act(.open); return .handled }
            }
            footer
        }
        .foregroundStyle(NoirPalette.text)
        .background(NoirPalette.base)
        .onExitCommand { model.close() }
        .onKeyPress(keys: ["f"], phases: .down) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            queryFocused = true
            return .handled
        }
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("File search").font(.system(size: 14, weight: .medium))
                Spacer()
                Text(model.searching ? "Searching…" : "\(model.results.count) \(model.results.count == 1 ? "result" : "results")")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(NoirPalette.muted)
            }
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(NoirPalette.accent)
                TextField(model.draft.mode == .name ? "Search file names…" : "Search words inside documents…", text: $model.draft.query)
                    .font(.system(size: 14)).textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit { search() }
                    .accessibilityLabel("File search words")
                if !model.draft.query.isEmpty {
                    Button { model.draft.query = ""; queryFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(NoirPalette.muted)
                    }.buttonStyle(.plain).accessibilityLabel("Clear search words")
                }
                if model.searching { ProgressView().controlSize(.small) }
                Button(model.searching ? "Cancel" : "Search") {
                    if model.searching { model.cancel() } else { search() }
                }.buttonStyle(NoirButtonStyle(intent: model.searching ? .quiet : .primary, small: true))
            }
            .padding(.leading, 14).padding(.trailing, 7).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(NoirPalette.fieldBg))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(queryFocused ? NoirPalette.accentEdge : NoirPalette.lineStrong, lineWidth: 1))

            HStack(spacing: 10) {
                Picker("Match", selection: $model.draft.mode) {
                    Text("Name").tag(LocalSearchRequest.Mode.name)
                    Text("Contents").tag(LocalSearchRequest.Mode.content)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 134)
                    .accessibilityLabel("Match file names or document contents")
                Picker("File type", selection: $model.draft.kind) {
                    ForEach(LocalSearchKind.allCases, id: \.self) { kind in Text(kind.label).tag(kind) }
                }.labelsHidden().frame(width: 139).accessibilityLabel("File type")
                Picker("Modified", selection: $model.draft.date) {
                    ForEach(LocalSearchDate.allCases, id: \.self) { date in Text(date.label).tag(date) }
                }.labelsHidden().frame(width: 130).accessibilityLabel("Modification date")
                scopeMenu
                Spacer(minLength: 0)
            }.controlSize(.small)
            if model.draft.minimumBytes > 0 || model.draft.maximumBytes > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                    Text(sizeFilterText).font(.system(size: 11))
                    Button("Clear") { model.draft.minimumBytes = 0; model.draft.maximumBytes = 0 }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(NoirPalette.accent)
                        .accessibilityLabel("Clear size filter")
                }.foregroundStyle(NoirPalette.secondary)
            }
        }.padding(20).fixedSize(horizontal: false, vertical: true)
    }

    private var columnHead: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: 24, alignment: .trailing)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 38)
            Text("Modified").frame(width: 105, alignment: .trailing)
            Text("Size").frame(width: 68, alignment: .trailing)
        }
        .font(.system(size: 10, weight: .medium)).foregroundStyle(NoirPalette.muted)
        .padding(.horizontal, 24).padding(.vertical, 11)
        .background(NoirPalette.footer)
        .overlay(alignment: .bottom) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected?.name ?? "Select a file")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(selected == nil ? "Choose a result to preview or open" : "Selected file")
                        .font(.system(size: 10)).foregroundStyle(NoirPalette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 7) {
                    Button { act(.reveal) } label: { Label("Finder", systemImage: "arrow.up.forward.square") }
                        .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                        .accessibilityLabel("Show selected file in Finder")
                    Button { act(.preview) } label: { Label("Preview", systemImage: "eye") }
                        .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    Button { act(.open) } label: { Label("Open", systemImage: "arrow.up.forward") }
                        .buttonStyle(NoirButtonStyle(intent: .primary, small: true))
                }.disabled(!canAct)
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(model.status).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text("Space  Preview    ↩  Open").fixedSize().foregroundStyle(NoirPalette.muted)
            }.font(.system(size: 10)).foregroundStyle(NoirPalette.secondary)
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .background(NoirPalette.footer)
        .overlay(alignment: .top) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
    }

    private var scopeMenu: some View {
        Menu {
            Button("All indexed locations") { model.draft.scopes = [] }
            Divider()
            ForEach(Array(Set(["downloads", "documents", "desktop"] + locations.locations.map(\.name).filter { !$0.isEmpty })).sorted(), id: \.self) { name in
                Toggle(name.capitalized, isOn: Binding(get: { model.draft.scopes.contains(name) }, set: { included in
                    if included { model.draft.scopes.append(name) } else { model.draft.scopes.removeAll { $0 == name } }
                }))
            }
        } label: {
            Label(model.draft.scopes.isEmpty ? "This Mac" : model.draft.scopes.count == 1 ? model.draft.scopes[0].capitalized : "\(model.draft.scopes.count) folders", systemImage: "folder")
                .font(.system(size: 11)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).frame(minWidth: 70, maxWidth: 150)
        .accessibilityLabel("Search folders")
        .help(model.draft.scopes.isEmpty ? "All indexed local locations" : model.draft.scopes.joined(separator: ", "))
    }

    private var sizeFilterText: String {
        var parts: [String] = []
        if model.draft.minimumBytes > 0 { parts.append("At least " + FileExplorer.formatSize(model.draft.minimumBytes)) }
        if model.draft.maximumBytes > 0 { parts.append("At most " + FileExplorer.formatSize(model.draft.maximumBytes)) }
        return parts.joined(separator: " · ")
    }

    private func search() { let request = model.draft; Task { await model.search(request) } }
    private func act(_ operation: FileResultOperation, index: Int = 0) { model.act(FileResultSelection(operation: operation, index: index)) }

    private func resultRow(_ item: FileSearchResult, index: Int) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(model.selectedID == item.id ? NoirPalette.accent : NoirPalette.muted)
                .frame(width: 24, alignment: .trailing)
            Image(nsImage: NSWorkspace.shared.icon(for: item.isDirectory ? .folder : UTType(filenameExtension: item.url.pathExtension) ?? .data))
                .resizable().scaledToFit().frame(width: 28, height: 32).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(NoirPalette.text).lineLimit(1)
                    .help(item.name)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 10.5)).foregroundStyle(NoirPalette.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(item.modified == .distantPast ? "—" : item.modified.formatted(date: .abbreviated, time: .omitted))
                .frame(width: 105, alignment: .trailing)
            Text(item.isDirectory ? "Folder" : FileExplorer.formatSize(item.size))
                .frame(width: 68, alignment: .trailing)
        }
        .font(.system(size: 10.5)).foregroundStyle(NoirPalette.secondary)
        .padding(.horizontal, 12).padding(.vertical, 12)
        .foregroundStyle(NoirPalette.text)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Result \(index + 1), \(item.name), \(item.url.deletingLastPathComponent().path)")
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 27, weight: .light)).foregroundStyle(NoirPalette.muted)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(NoirPalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 390)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(28)
    }
}

struct FileSearchPreviewView: View {
    let target: FilePreviewTarget
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "eye").foregroundStyle(NoirPalette.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(target.url.deletingLastPathComponent().path).font(.system(size: 10.5))
                        .foregroundStyle(NoirPalette.muted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button("Done", action: onClose).buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    .keyboardShortcut(.cancelAction)
            }.padding(16)
            Rectangle().fill(NoirPalette.line).frame(height: 1)
            FileQuickLookView(url: target.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(NoirPalette.text).background(NoirPalette.base)
        .onExitCommand(perform: onClose)
    }
}

private struct FileQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            let label = NSTextField(wrappingLabelWithString: "Quick Look is unavailable for this file. You can open it from the results window.")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            return label
        }
        view.autostarts = false
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? QLPreviewView)?.previewItem = url as NSURL }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? QLPreviewView)?.close() }
}

extension LocalSearchKind {
    var label: String {
        switch self {
        case .any: return "All files"
        case .pdf: return "PDFs"
        case .presentation: return "Presentations"
        case .document: return "Word documents"
        case .mail: return "Mail files"
        case .note: return "Notes / text"
        default: return rawValue.capitalized + "s"
        }
    }
}

extension LocalSearchDate {
    var label: String {
        switch self {
        case .any: return "Any date"
        case .last7Days: return "Last 7 days"
        case .last30Days: return "Last 30 days"
        default: return rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct NoirFileSearchPreferences: View {
    @ObservedObject private var store = FileSearchLocationStore.shared
    var body: some View {
        NoirSectionHeading(title: "File search")
        NoirCard(padded: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Say ‘find PDFs from last week in Downloads or Documents’, then use ⌘⇧A to say ‘open the second one’ or ‘preview it’.")
                    .font(.system(size: 12)).foregroundStyle(NoirPalette.secondary)
                Text("Add other folders or drives below. Their names become spoken search locations. Searches use Spotlight’s index and respect macOS folder permissions and indexing exclusions.")
                    .font(.system(size: 11)).foregroundStyle(NoirPalette.muted)
                ForEach($store.locations) { $location in
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(NoirPalette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Spoken folder name", text: $location.name)
                                .textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                            Text(location.path).font(.system(size: 10.5)).foregroundStyle(NoirPalette.muted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { store.locations.removeAll { $0.id == location.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(location.name) search location")
                    }
                }
                Button("Add folder or drive…", action: store.chooseFolder)
                    .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
            }
        }
    }
}
