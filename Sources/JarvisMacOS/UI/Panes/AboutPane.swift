import SwiftUI

/// About pane — build facts, hotkeys, engine toggle.
struct AboutPane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            JCard {
                JRow(title: "Version", first: true) {
                    kv("1.0 (0)")
                }
                JRow(title: "Build") {
                    kv("arm64")
                }
                JRow(title: "Speech core") {
                    kv("whisper large-v3-turbo")
                }
                JRow(title: "Intent router") {
                    kv("t5-small")
                }
                JRow(title: "Storage") {
                    kv("local only")
                }
            }

            JLabel(text: "Engine")
                .padding(.top, 22)

            JCard {
                JRow(title: "Rust pipeline",
                     sub: "Route command understanding through the Rust core",
                     first: true) {
                    JSwitch(binding: $appState.useRustPipeline)
                }
                .help("Swift → Rust migration: route command understanding through the Rust core. OFF = Swift rules with shadow-parity logging into intent_router.jsonl")
            }
            .padding(.top, 9)

            JLabel(text: "Keys")
                .padding(.top, 22)

            JCard {
                keyRow("⌘⇧D", "Dictation", first: true)
                keyRow("⌘⇧A", "Run command")
                keyRow("⌘O", "Toggle verification")
            }
            .padding(.top, 9)
        }
    }

    /// Mock `.row` with the kbd on the left and its description right-aligned.
    private func keyRow(_ shortcut: String, _ description: String, first: Bool = false) -> some View {
        HStack(spacing: 11) {
            kbd(shortcut)
            Spacer(minLength: 8)
            Text(description)
                .font(JType.rowTitle)
                .foregroundStyle(JColor.ink2)
        }
        .padding(.top, first ? 0 : 11)
        .padding(.bottom, 11)
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(JColor.line)
                    .frame(height: 1)
            }
        }
    }

    private func kv(_ text: String) -> some View {
        Text(text)
            .font(JType.kv)
            .foregroundStyle(JColor.ink2)
    }

    private func kbd(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(JColor.ink)
    }
}
