import SwiftUI
import AppKit

/// Mock `.logbar`: an "Activity" header bar that expands into the log body.
struct EventLogDrawer: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle()
                .fill(JColor.line)
                .frame(height: 1)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if appState.logs.isEmpty {
                                Text("Nothing yet — Jarvis logs every step here.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(JColor.ink4)
                                    .padding(.vertical, 14)
                            } else {
                                ForEach(Array(appState.logs.enumerated()), id: \.offset) { idx, log in
                                    LogLine(text: log)
                                        .id(idx)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: appState.logs.count) { _ in
                        if let last = appState.logs.indices.last {
                            withAnimation {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
                        }
                    }
                }
                .frame(height: 180)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(JColor.base)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(JColor.line),
            alignment: .top
        )
    }

    /// Header bar — the expand toggle is its own hit area so the copy/clear
    /// icon buttons inside stay independently clickable.
    private var header: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 13))
                        .foregroundStyle(JColor.ink4)

                    Text("Activity")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(JColor.ink3)

                    if !appState.logs.isEmpty {
                        Text("\(appState.logs.count)")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(JColor.ink4)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(JColor.inset)
                            )
                    }

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(JColor.ink4)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse the activity log" : "Expand the activity log")

            Spacer(minLength: 8)

            iconButton("doc.on.doc", help: "Copy the full activity log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appState.eventLogText, forType: .string)
            }

            iconButton("trash", help: "Clear the activity log") {
                appState.clearEventLog()
            }
        }
        .padding(.horizontal, 18)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(JColor.ink4)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct LogLine: View {
    let text: String

    /// Severity only — the default row is neutral.
    private var color: Color {
        let lowered = text.lowercased()
        if lowered.contains("[error]") || lowered.contains("failed") || lowered.contains("rejected") {
            return JColor.danger
        }
        if lowered.contains("blocked") || lowered.contains("warning") {
            return JColor.warn
        }
        return JColor.ink3
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .lineSpacing(4)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
