import SwiftUI
import AppKit

// MARK: - Connection sheet

struct ConnectionSheet: View {
    @ObservedObject var appState: AppState
    let kind: ConnectionKind

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toasts: ToastCenter

    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.016))
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(NoirPalette.line, lineWidth: 1)
                    Image(systemName: kind.icon)
                        .obsidianFont(size: 15)
                        .foregroundStyle(iconColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .obsidianFont(size: 15, weight: .medium)
                        .foregroundStyle(NoirPalette.text)
                    Text(headerSub)
                        .obsidianFont(size: 11)
                        .foregroundStyle(NoirPalette.muted)
                }

                Spacer()
                NoirIconButton(icon: "xmark", help: "Close") { dismiss() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) {
                Rectangle().fill(NoirPalette.line).frame(height: 1)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    switch kind {
                    case .spotify: spotifyBody
                    case .ollama: ollamaBody
                    case .postgres: postgresBody
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 470)

            footer
        }
        .frame(width: 540)
        .background(GlassPanelBackground())
        .preferredColorScheme(.dark)
    }

    private var iconColor: Color {
        switch kind {
        case .spotify:  return NoirPalette.green
        case .ollama:   return NoirPalette.accent
        case .postgres: return NoirPalette.secondary
        }
    }

    private var headerSub: String {
        switch kind {
        case .spotify:  return "Music, at your request."
        case .ollama:   return "Local intelligence."
        case .postgres: return "Your activity, kept close."
        }
    }

    // MARK: Spotify

    private var spotifyBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install Spotify and sign in there. Playback uses macOS Automation; named-song, playlist and Liked Songs lookup uses Spotify’s local interface and requires Accessibility permission. No API keys or browser authorization are needed.")
                .obsidianFont(size: 11).foregroundStyle(NoirPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(appState.spotifyStatusText).obsidianFont(size: 11)
        }
    }

    // MARK: Ollama

    private var ollamaBody: some View {
        NoirCard {
            VStack(spacing: 0) {
                factRow("Model", "qwen2.5:1.5b-instruct")
                NoirDivider()
                factRow("Intent router", "t5-small · int8 ONNX")
                NoirDivider()
                factRow("Speech to text", "Apple live speech · Whisper shortcuts")
                NoirDivider()
                factRow("Endpoint", "127.0.0.1:11434")
                NoirDivider()
                NoirSettingRow(title: "Status") {
                    NoirTag(
                        text: appState.ollamaReachable ? "Ready" : "Offline",
                        kind: appState.ollamaReachable ? .green : .neutral
                    )
                }
            }
        }
    }

    // MARK: Postgres

    private var postgresBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Store command activity and usage statistics. Passwords live in the macOS Keychain.")
                .obsidianFont(size: 11)
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)

            NoirCard {
                NoirSettingRow(
                    title: "Event logging",
                    sub: "Write command activity to your database."
                ) {
                    NoirSwitch(
                        isOn: $appState.eventLoggingEnabled,
                        disabled: !appState.postgresConfigured
                    )
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                TextField("Host", text: $appState.postgresForm.host)
                    .noirField()
                    .noirFieldLabel("Host")

                HStack(spacing: 12) {
                    TextField("Port", text: $appState.postgresForm.port)
                        .noirField()
                        .noirFieldLabel("Port")
                        .frame(width: 100)
                    TextField("Database", text: $appState.postgresForm.database)
                        .noirField()
                        .noirFieldLabel("Database")
                }

                TextField("User", text: $appState.postgresForm.user)
                    .noirField()
                    .noirFieldLabel("User")

                SecureField("Leave blank to keep existing", text: $appState.postgresForm.password)
                    .noirField()
                    .noirFieldLabel("Password")
            }

            if let notice {
                noticeCard(notice)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            switch kind {
            case .spotify:
                Button("Close") { dismiss() }
                    .buttonStyle(NoirButtonStyle(intent: .quiet))
                Button("Open Spotify") { NSWorkspace.shared.open(URL(string: "spotify:")!) }
                    .buttonStyle(NoirButtonStyle(intent: .primary))

            case .ollama:
                Button {
                    Task {
                        await appState.refreshOllamaStatus()
                        toasts.show("Ollama status refreshed.")
                    }
                } label: {
                    Label("Refresh status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(NoirButtonStyle(intent: .quiet))
                Button("Done") { dismiss() }
                    .buttonStyle(NoirButtonStyle(intent: .primary))

            case .postgres:
                Button("Close") { dismiss() }
                    .buttonStyle(NoirButtonStyle(intent: .quiet))
                Button(busy ? "Testing…" : "Test connection") { testPostgres() }
                    .buttonStyle(NoirButtonStyle())
                    .disabled(busy)
                Button(busy ? "Saving…" : "Save") { savePostgres() }
                    .buttonStyle(NoirButtonStyle(intent: .primary))
                    .disabled(busy || appState.postgresForm.host.isEmpty
                              || appState.postgresForm.database.isEmpty
                              || appState.postgresForm.user.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(NoirPalette.line).frame(height: 1)
        }
    }

    // MARK: Actions

    private func savePostgres() {
        busy = true
        notice = nil
        Task {
            notice = await appState.savePostgresCredentials()
            busy = false
            toasts.show(notice ?? "Database settings saved.")
        }
    }

    private func testPostgres() {
        busy = true
        notice = nil
        Task {
            notice = await appState.testPostgresConnection()
            busy = false
        }
    }

    // MARK: Pieces

    private func factRow(_ label: String, _ value: String) -> some View {
        NoirSettingRow(title: label) {
            Text(value)
                .obsidianFont(size: 11, design: .monospaced)
                .foregroundStyle(NoirPalette.secondary)
                .lineLimit(1)
        }
    }

    private func noticeCard(_ text: String) -> some View {
        Text(text)
            .obsidianFont(size: 11)
            .lineSpacing(4)
            .foregroundStyle(NoirPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(NoirPalette.accentSoft)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(NoirPalette.accent.opacity(0.15), lineWidth: 1)
            )
    }
}
