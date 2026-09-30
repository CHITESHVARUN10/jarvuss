import SwiftUI
import AppKit

struct EventLogDrawer: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(JarvisColor.textTertiary)

                    Text("System log")
                        .font(JarvisType.caption)
                        .foregroundStyle(JarvisColor.textSecondary)

                    if !appState.logs.isEmpty {
                        Text("\(appState.logs.count)")
                            .font(JarvisType.dataSmall)
                            .foregroundStyle(JarvisColor.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(JarvisColor.surface)
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.eventLogText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(JarvisColor.textTertiary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.clearEventLog()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(JarvisColor.textTertiary)
                    }
                    .buttonStyle(.plain)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(JarvisColor.textTertiary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(JarvisColor.canvas)

            Divider()
                .overlay(JarvisColor.hairline)

            if isExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(appState.logs.enumerated()), id: \.offset) { idx, log in
                                LogLine(text: log)
                                    .id(idx)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
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
                .background(JarvisColor.canvas)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(JarvisColor.hairline),
            alignment: .top
        )
    }
}

private struct LogLine: View {
    let text: String

    /// Severity only — the default row is neutral.
    private var color: Color {
        let lowered = text.lowercased()
        if lowered.contains("[error]") || lowered.contains("failed") || lowered.contains("rejected") {
            return JarvisColor.danger
        }
        if lowered.contains("blocked") || lowered.contains("warning") {
            return JarvisColor.attention
        }
        return JarvisColor.textTertiary
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
