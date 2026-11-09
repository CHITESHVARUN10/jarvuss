import SwiftUI
import AppKit

/// Compact native navigation rail. Settings groups General, Setup, and About;
/// Appearance occupies the former Connections destination.
struct NoirSidebar: View {
    @ObservedObject var appState: AppState
    @State private var shortcutsOpen = false
    var body: some View {
        VStack(spacing: 8) {
            ForEach([RailSection.assistant, .voice, .routines, .insights, .appearance], id: \.self) { item in navButton(item) }
            Rectangle().fill(NoirPalette.line).frame(width: 25, height: 1).padding(.vertical, 6)
            navButton(.system)
            Spacer(minLength: 10)
            Button { shortcutsOpen.toggle() } label: {
                Image(systemName: "keyboard").obsidianFont(size: 15).foregroundStyle(NoirPalette.muted).frame(width: 36, height: 34)
            }
            .buttonStyle(.plain).help("Keyboard shortcuts").accessibilityLabel("Keyboard shortcuts")
            .popover(isPresented: $shortcutsOpen) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Keyboard shortcuts").obsidianFont(size: 13, weight: .medium)
                    Text("⌘⇧A    Record a command\n⌘⇧D    Dictate at the cursor\n⌘⇧R    Restore display visibility\nEscape  Dismiss a recording")
                        .obsidianFont(size: 12).lineSpacing(8)
                }.padding(22).foregroundStyle(NoirPalette.text).background(GlassPanelBackground()).preferredColorScheme(.dark)
            }
        }
        .padding(.horizontal, 7).padding(.top, 14).padding(.bottom, 13)
        .frame(width: 54).frame(maxHeight: .infinity)
        .background(NoirPalette.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(NoirPalette.line).frame(width: 1) }
    }
    private func navButton(_ section: RailSection) -> some View {
        let selected = appState.activeSection == section || (section == .system && [.setup, .about].contains(appState.activeSection))
        return Button { appState.activeSection = section } label: {
            Image(systemName: section.icon).obsidianFont(size: 16, weight: .regular)
                .foregroundStyle(selected ? NoirPalette.accent : NoirPalette.muted)
                .frame(width: 38, height: 36)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? NoirPalette.accentSoft : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? NoirPalette.accentEdge : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(section.title).accessibilityLabel(section.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NoirToolbar: View {
    @ObservedObject var appState: AppState
    var body: some View {
        HStack(spacing: 12) {
            // Space is reserved for the real macOS window controls.
            Color.clear.frame(width: 63)
            Text("Jarvis").obsidianFont(size: 12, weight: .semibold).foregroundStyle(NoirPalette.text)
            Text(appState.activeSection.title).obsidianFont(size: 10).foregroundStyle(NoirPalette.muted)
            Spacer(minLength: 10)
            Circle().fill(appState.isLiveListening ? NoirPalette.accent : NoirPalette.green).frame(width: 4, height: 4)
            Text(appState.isLiveListening ? "Microphone live" : "On device").obsidianFont(size: 9).foregroundStyle(NoirPalette.secondary)
            NoirIconButton(icon: "paintpalette", help: "Appearance") { appState.activeSection = .appearance }
        }.padding(.horizontal, 16).frame(height: 49)
            .background(LinearGradient(colors: [Color(hex: 0x1A1A1D), Color(hex: 0x141416)], startPoint: .top, endPoint: .bottom))
            .overlay(alignment: .bottom) { Rectangle().fill(NoirPalette.line).frame(height: 1) }
    }
}

// MARK: - Footer

struct NoirFooter: View {
    @ObservedObject var appState: AppState
    @Binding var activityOpen: Bool

    var body: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { activityOpen.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "list.bullet.rectangle")
                        .obsidianFont(size: 11)
                    Text("Activity")
                        .obsidianFont(size: 10)
                    Text("\(appState.logs.count)")
                        .obsidianFont(size: 9, design: .monospaced)
                        .foregroundStyle(NoirPalette.muted)
                }
                .foregroundStyle(NoirPalette.secondary)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(activityOpen ? "Close the activity log" : "Open the activity log")

            Spacer(minLength: 8)

            Circle()
                .fill(NoirPalette.green)
                .frame(width: 4, height: 4)
            Text(stateText)
                .obsidianFont(size: 10)
                .foregroundStyle(NoirPalette.muted)

            Spacer(minLength: 8)

            Text("LOCAL PROCESSING")
                .obsidianFont(size: 9)
                .foregroundStyle(NoirPalette.muted)
        }
        .padding(.horizontal, 16)
        .frame(height: 29)
        .background(NoirPalette.footer)
        .overlay(alignment: .top) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
    }

    private var stateText: String {
        guard appState.isLiveListening else { return "Standby · microphone off" }
        switch appState.assistantState {
        case .idle:       return "Standby · microphone off"
        case .listening:  return "Listening"
        case .recording:  return "Recording"
        case .processing: return "Thinking…"
        case .executing:  return "Working"
        }
    }
}

// MARK: - Activity drawer

struct NoirActivityDrawer: View {
    @ObservedObject var appState: AppState
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .obsidianFont(size: 13)
                    .foregroundStyle(NoirPalette.muted)
                Text("Activity")
                    .obsidianFont(size: 12, weight: .medium)
                    .foregroundStyle(NoirPalette.text)
                NoirTag(text: "Session events")

                Spacer(minLength: 8)

                NoirIconButton(icon: "doc.on.doc", help: "Copy activity") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.eventLogText, forType: .string)
                }
                NoirIconButton(icon: "trash", help: "Clear activity") {
                    appState.clearEventLog()
                }
                NoirIconButton(icon: "xmark", help: "Close activity") {
                    withAnimation(.easeOut(duration: 0.2)) { isOpen = false }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if appState.logs.isEmpty {
                            Text("No activity yet. Try a command to see its steps here.")
                                .obsidianFont(size: 11)
                                .foregroundStyle(NoirPalette.muted)
                                .padding(.vertical, 16)
                        } else {
                            ForEach(Array(appState.logs.enumerated()), id: \.offset) { index, line in
                                logLine(line)
                                    .id(index)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
                .onChange(of: appState.logs.count) { _, _ in
                    if let last = appState.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .frame(height: 210)
        }
        .frame(height: 270)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(NoirPalette.logBg.opacity(0.86))
            }
        )
        .overlay(alignment: .top) {
            Rectangle().fill(NoirPalette.lineStrong).frame(height: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: -6)
    }

    private func logLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color(for: text))
                .frame(width: 4, height: 4)
                .padding(.top, 6)
            Text(text)
                .obsidianFont(size: 10, design: .monospaced)
                .lineSpacing(3)
                .foregroundStyle(NoirPalette.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.015)).frame(height: 1)
        }
    }

    private func color(for text: String) -> Color {
        let lowered = text.lowercased()
        if lowered.contains("[error]") || lowered.contains("failed") || lowered.contains("rejected") {
            return NoirPalette.red
        }
        if lowered.contains("blocked") || lowered.contains("warning") {
            return NoirPalette.orange
        }
        return NoirPalette.green.opacity(0.55)
    }
}

// MARK: - Placeholder (replaced as pages land)

struct NoirPlaceholderPage: View {
    let title: String
    var body: some View {
        VStack {
            Spacer()
            Text(title)
                .obsidianFont(size: 20)
                .foregroundStyle(NoirPalette.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
