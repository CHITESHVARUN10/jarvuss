import SwiftUI
import QuickLookUI

struct FileSearchResultsView: View {
    @ObservedObject var model: FileSearchController
    @ObservedObject private var locations = FileSearchLocationStore.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(NoirPalette.accent)
                    TextField("File name or words inside a document", text: $model.draft.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .onSubmit { search() }
                        .accessibilityLabel("File search words")
                    if model.searching {
                        ProgressView().controlSize(.small)
                        Button("Cancel", action: model.cancel).buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    } else {
                        Button("Search", action: search).buttonStyle(NoirButtonStyle(intent: .primary, small: true))
                    }
                }
                HStack(spacing: 12) {
                    Picker("Search", selection: $model.draft.mode) {
                        Text("Name").tag(LocalSearchRequest.Mode.name)
                        Text("Contents").tag(LocalSearchRequest.Mode.content)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
                        .accessibilityLabel("Match file names or document contents")
                    Picker("Type", selection: $model.draft.kind) {
                        ForEach(LocalSearchKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }.labelsHidden().frame(width: 132).accessibilityLabel("File type")
                    Picker("Modified", selection: $model.draft.date) {
                        ForEach(LocalSearchDate.allCases, id: \.self) { date in
                            Text(date.label).tag(date)
                        }
                    }.labelsHidden().frame(width: 116).accessibilityLabel("Modification date")
                    scopeMenu
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                if model.draft.minimumBytes > 0 || model.draft.maximumBytes > 0 {
                    HStack(spacing: 8) {
                        Text(sizeFilterText).font(.system(size: 11)).foregroundStyle(NoirPalette.secondary)
                        Button("Clear size filter") {
                            model.draft.minimumBytes = 0; model.draft.maximumBytes = 0
                        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NoirPalette.accent)
                    }
                }
            }
            .padding(18)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(NoirPalette.line).frame(height: 1)

            if model.searching {
                emptyState(icon: "magnifyingglass", title: "Searching your Mac", detail: "Looking through Spotlight-indexed files in the requested locations.")
            } else if model.results.isEmpty {
                emptyState(icon: "doc.text.magnifyingglass", title: "No files to show", detail: "Try fewer search words, another folder, or a wider date range.")
            } else {
                List(selection: $model.selectedID) {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, index: index)
                            .tag(item.id)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { act(.open, index: index + 1) })
                            .contextMenu {
                                Button("Open") { act(.open, index: index + 1) }
                                Button("Quick Look") { act(.preview, index: index + 1) }
                                Button("Show in Finder") { act(.reveal, index: index + 1) }
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onKeyPress(.space) { act(.preview); return .handled }
                .onKeyPress(.return) { act(.open); return .handled }
            }

            Rectangle().fill(NoirPalette.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(model.status)
                        .font(.system(size: 11)).foregroundStyle(NoirPalette.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Show in Finder") { act(.reveal) }
                        .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    Button("Preview") { act(.preview) }
                        .buttonStyle(NoirButtonStyle(intent: .quiet, small: true))
                    Button("Open") { act(.open) }
                        .buttonStyle(NoirButtonStyle(intent: .primary, small: true))
                }.disabled(model.searching || model.selectedID == nil)
                Text("Only indexed, accessible content is searchable. Private Mail/Notes stores and excluded folders may not appear. Space previews the selected result; Return opens it.")
                    .font(.system(size: 10)).foregroundStyle(NoirPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .foregroundStyle(NoirPalette.text)
        .background(NoirPalette.base)
        .onExitCommand { model.close() }
        .sheet(item: $model.preview) { target in
            VStack(spacing: 0) {
                HStack {
                    Text(target.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button("Done") { model.preview = nil }.keyboardShortcut(.cancelAction)
                }.padding(14)
                FileQuickLookView(url: target.url)
            }
            .frame(minWidth: 600, minHeight: 440)
        }
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
            Label(model.draft.scopes.isEmpty ? "This Mac" : "\(model.draft.scopes.count) location\(model.draft.scopes.count == 1 ? "" : "s")", systemImage: "folder")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Search folders")
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
                .foregroundStyle(NoirPalette.muted).frame(width: 24, alignment: .trailing)
            Image(systemName: item.isDirectory ? "folder" : "doc.text")
                .font(.system(size: 22, weight: .light)).foregroundStyle(NoirPalette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(item.url.deletingLastPathComponent().path)
                    .font(.system(size: 10.5)).foregroundStyle(NoirPalette.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(item.isDirectory ? "Folder" : FileExplorer.formatSize(item.size))
                Text(item.modified == .distantPast ? "" : item.modified.formatted(date: .abbreviated, time: .omitted))
            }.font(.system(size: 10.5)).foregroundStyle(NoirPalette.secondary)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Result \(index + 1), \(item.name), \(item.url.deletingLastPathComponent().path)")
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(NoirPalette.muted)
            Text(title).font(.system(size: 16, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(NoirPalette.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

private struct FileQuickLookView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
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
