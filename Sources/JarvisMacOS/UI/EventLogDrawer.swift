import SwiftUI
import AppKit

struct EventLogDrawer: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Drag handle / toggle bar
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.40))

                    Text("SYSTEM LOGS")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(0.40))

                    if !appState.logs.isEmpty {
                        Text("\(appState.logs.count)")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 1.0))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.55, green: 0.55, blue: 1.0).opacity(0.15))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    // Copy button
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(appState.eventLogText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.30))
                    }
                    .buttonStyle(.plain)

                    // Clear button
                    Button {
                        appState.clearEventLog()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.45).opacity(0.6))
                    }
                    .buttonStyle(.plain)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.25))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .background(Color(red: 0.08, green: 0.08, blue: 0.11))

            Divider()
                .background(Color.white.opacity(0.06))

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
                .background(Color(red: 0.055, green: 0.055, blue: 0.08))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.white.opacity(0.06)),
            alignment: .top
        )
    }
}

private struct LogLine: View {
    let text: String

    private var color: Color {
        let lowered = text.lowercased()
        if lowered.contains("[error]") || lowered.contains("failed") || lowered.contains("rejected") {
            return Color(red: 1.0, green: 0.40, blue: 0.55)
        }
        if lowered.contains("[voice]") || lowered.contains("speech") {
            return Color(red: 0.55, green: 0.62, blue: 1.0)
        }
        if lowered.contains("[system]") || lowered.contains("microphone") || lowered.contains("postgresql") {
            return Color(red: 0.35, green: 0.85, blue: 0.75)
        }
        if lowered.contains("enrollment") || lowered.contains("phrase") || lowered.contains("sample") {
            return Color(red: 0.80, green: 0.60, blue: 1.0)
        }
        if lowered.contains("blocked") || lowered.contains("warning") {
            return Color(red: 1.0, green: 0.78, blue: 0.2)
        }
        return Color.white.opacity(0.40)
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
