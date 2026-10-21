import SwiftUI
import AppKit

// MARK: - Sidebar

/// Noir sidebar: labeled navigation in two groups, routine count, local
/// status. The top inset leaves room for the real macOS traffic lights
/// (the window uses a hidden title bar).
struct NoirSidebar: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 34)

            HStack(spacing: 10) {
                NoirBrandMark(size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("JARVIS")
                        .font(.system(size: 17, weight: .medium))
                        .tracking(3.2)
                        .foregroundStyle(NoirPalette.text)
                    Text("A little more possible.")
                        .font(.system(size: 9))
                        .tracking(1.7)
                        .textCase(.uppercase)
                        .foregroundStyle(NoirPalette.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .padding(.top, 8)
            .padding(.bottom, 34)

            navGroup(label: "Workspace", items: [.assistant, .voice, .routines, .insights])
            navGroup(label: "Preferences", items: [.system, .connections, .setup], topPadding: 27)

            Spacer(minLength: 16)

            navButton(.about)
                .padding(.horizontal, 12)

            localStatus
        }
        .frame(width: 204)
        .frame(maxHeight: .infinity)
        .background(NoirPalette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(NoirPalette.line).frame(width: 1)
        }
    }

    private func navGroup(label: String, items: [RailSection], topPadding: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(NoirPalette.navLabel)
                .padding(.horizontal, 24)
                .padding(.bottom, 11)

            ForEach(items) { item in
                navButton(item)
            }
        }
        .padding(.top, topPadding)
    }

    private func navButton(_ section: RailSection) -> some View {
        NoirNavButton(
            section: section,
            isActive: appState.activeSection == section,
            count: section == .routines ? appState.automations.count : nil,
            showsDot: section == .setup && !appState.setupCompleted
        ) {
            appState.activeSection = section
        }
    }

    private var localStatus: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(NoirPalette.green)
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text("On your Mac")
                    .font(.system(size: 11))
                    .foregroundStyle(NoirPalette.text)
                Text("Local intelligence")
                    .font(.system(size: 10))
                    .foregroundStyle(NoirPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 18)
        .overlay(alignment: .top) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
        .padding(.top, 15)
    }
}

private struct NoirNavButton: View {
    let section: RailSection
    let isActive: Bool
    let count: Int?
    let showsDot: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(isActive ? NoirPalette.accent : NoirPalette.muted)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(isActive ? Color(hex: 0xE3E0F7) : NoirPalette.muted)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let count {
                    Text("\(count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(NoirPalette.muted)
                }
                if showsDot {
                    Circle()
                        .fill(NoirPalette.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 39)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive
                          ? NoirPalette.accent.opacity(0.09)
                          : (hovering ? Color.white.opacity(0.015) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isActive ? NoirPalette.accent.opacity(0.08) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 12)
        .padding(.vertical, 1.5)
        .help(label)
        .accessibilityLabel(label)
    }

    private var label: String {
        switch section {
        case .assistant:   return "Assistant"
        case .voice:       return "Voice profile"
        case .routines:    return "Routines"
        case .insights:    return "Insights"
        case .system:      return "System"
        case .connections: return "Connections"
        case .setup:       return "Setup"
        case .about:       return "About Jarvis"
        }
    }

    private var icon: String {
        switch section {
        case .assistant:   return "bubble.left"
        case .voice:       return "mic"
        case .routines:    return "bolt"
        case .insights:    return "chart.bar"
        case .system:      return "display"
        case .connections: return "link"
        case .setup:       return "wand.and.stars"
        case .about:       return "info.circle"
        }
    }
}

// MARK: - Toolbar

struct NoirToolbar: View {
    @ObservedObject var appState: AppState
    let onPreferences: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Text("Workspace")
                .font(.system(size: 12))
                .foregroundStyle(NoirPalette.muted)
            Text("/")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x55565E))
            Text(sectionTitle)
                .font(.system(size: 12))
                .foregroundStyle(NoirPalette.secondary)

            Spacer(minLength: 16)

            HStack(spacing: 7) {
                Circle()
                    .fill(engineColor)
                    .frame(width: 5, height: 5)
                Text(engineText)
                    .font(.system(size: 10))
                    .foregroundStyle(NoirPalette.muted)
            }

            NoirIconButton(
                icon: "slider.horizontal.3",
                help: "Assistant preferences"
            ) {
                onPreferences()
            }
        }
        .padding(.horizontal, 26)
        .frame(height: 63)
        .background(NoirPalette.base)
        .overlay(alignment: .bottom) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
    }

    private var sectionTitle: String {
        switch appState.activeSection {
        case .assistant:   return "Assistant"
        case .voice:       return "Voice profile"
        case .routines:    return "Routines"
        case .insights:    return "Insights"
        case .system:      return "System & dictation"
        case .connections: return "Connections"
        case .setup:       return "Setup"
        case .about:       return "About Jarvis"
        }
    }

    private var engineText: String {
        let status = appState.backendStatus.lowercased()
        if status.contains("running") { return "Local engine ready" }
        if status.contains("fail") { return "Backend failed" }
        if status.contains("off") { return "Backend off" }
        if status.contains("starting") { return "Starting engine…" }
        return "Local engine idle"
    }

    private var engineColor: Color {
        let status = appState.backendStatus.lowercased()
        if status.contains("running") { return NoirPalette.green }
        if status.contains("fail") { return NoirPalette.red }
        if status.contains("starting") { return NoirPalette.orange }
        return NoirPalette.muted
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
                        .font(.system(size: 11))
                    Text("Activity")
                        .font(.system(size: 10))
                    Text("\(appState.logs.count)")
                        .font(.system(size: 9, design: .monospaced))
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
                .font(.system(size: 10))
                .foregroundStyle(NoirPalette.muted)

            Spacer(minLength: 8)

            Text("ON-DEVICE · LOCAL INTELLIGENCE")
                .font(.system(size: 9))
                .foregroundStyle(NoirPalette.muted)
        }
        .padding(.horizontal, 24)
        .frame(height: 35)
        .background(NoirPalette.footer)
        .overlay(alignment: .top) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
    }

    private var stateText: String {
        guard appState.isLiveListening else { return "Ready when you are" }
        switch appState.assistantState {
        case .idle:       return "Ready when you are"
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
                    .font(.system(size: 13))
                    .foregroundStyle(NoirPalette.muted)
                Text("Activity")
                    .font(.system(size: 12, weight: .medium))
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
                                .font(.system(size: 11))
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
                .font(.system(size: 10, design: .monospaced))
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
                .font(.system(size: 20))
                .foregroundStyle(NoirPalette.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
