import SwiftUI
import AppKit

/// Native Spotify, local Ollama, and PostgreSQL connection status.
/// data-driven so future connections slot in as one row + one detail view.
struct ConnectionsPane: View {
    @ObservedObject var appState: AppState
    @State private var expanded: ConnectionKind? = nil

    var body: some View {
        paneBody
            .padding(.horizontal, 22)
            .task {
                await appState.refreshSpotifyStatus()
                await appState.refreshPostgresStatus()
                await refreshOllama()
            }
    }

    private var paneBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            JCard(flush: true) {
                connectionRow(kind: .spotify, first: true)
                connectionRow(kind: .ollama, first: false)
                connectionRow(kind: .postgres, first: false)
            }

            if let expanded {
                detailCard(for: expanded)
                    .padding(.top, 9)
            }

            JLabel(text: "Add")
                .padding(.top, 22)

            Button {
                // No-op by design: new integrations appear here once their
                // backend endpoint exists — this button reserves the affordance.
            } label: {
                Label("Add connection", systemImage: "plus")
            }
            .jButton(block: true)
            .disabled(true)
            .padding(.top, 9)
            .help("More integrations (HomeKit, calendar, …) will appear here")
        }
    }

    // MARK: - Rows

    private func connectionRow(kind: ConnectionKind, first: Bool) -> some View {
        JActionRow(
            title: kind.title,
            sub: subtitle(for: kind),
            icon: kind.icon,
            first: first,
            showChevron: false,
            accessory: AnyView(chip(for: kind))
        ) {
            withAnimation(.easeOut(duration: 0.2)) {
                expanded = (expanded == kind) ? nil : kind
            }
            if kind == .ollama { Task { await refreshOllama() } }
            if kind == .postgres { Task { await appState.refreshPostgresStatus() } }
        }
    }

    private func subtitle(for kind: ConnectionKind) -> String {
        switch kind {
        case .spotify:  return appState.spotifyStatusText
        case .ollama:   return appState.ollamaStatusText
        case .postgres: return appState.postgresStatusText
        }
    }

    private func chip(for kind: ConnectionKind) -> some View {
        switch kind {
        case .spotify:
            if appState.spotifyLinked { return AnyView(JChip(text: "Live", kind: .ok)) }
            return AnyView(JChip(text: "Install Spotify", kind: .warn))
        case .ollama:
            return AnyView(JChip(
                text: appState.ollamaReachable ? "Ready" : "Offline",
                kind: appState.ollamaReachable ? .ok : .neutral
            ))
        case .postgres:
            if appState.postgresConfigured {
                return AnyView(JChip(
                    text: appState.eventLoggingEnabled ? "On" : "Paused",
                    kind: appState.eventLoggingEnabled ? .ok : .warn
                ))
            }
            return AnyView(JChip(text: "Setup", kind: .neutral))
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private func detailCard(for kind: ConnectionKind) -> some View {
        switch kind {
        case .spotify:  SpotifyDetail(appState: appState)
        case .ollama:   OllamaDetail(appState: appState)
        case .postgres: PostgresDetail(appState: appState)
        }
    }

    private func refreshOllama() async {
        await appState.refreshOllamaStatus()
    }
}

// MARK: - Kind

enum ConnectionKind: String, CaseIterable, Identifiable {
    case spotify, ollama, postgres

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotify:  return "Spotify"
        case .ollama:   return "Ollama"
        case .postgres: return "PostgreSQL"
        }
    }

    var icon: String {
        switch self {
        case .spotify:  return "music.note"
        case .ollama:   return "sparkles"
        case .postgres: return "cylinder"
        }
    }
}

// MARK: - Spotify detail

private struct SpotifyDetail: View {
    @ObservedObject var appState: AppState
    var body: some View {
        JCard {
            JCardHead(icon: "music.note", title: "Spotify")
            Text("Install Spotify and sign in. Playback uses native macOS controls. Song and library lookup uses Spotify’s local interface and requires Accessibility permission. No API keys or browser authorization are needed.")
                .font(JType.rowSub).foregroundStyle(JColor.ink2)
            Button("Open Spotify") { NSWorkspace.shared.open(URL(string: "spotify:")!) }
                .jButton()
        }
    }
}

// MARK: - Ollama detail

private struct OllamaDetail: View {
    @ObservedObject var appState: AppState

    private var refreshButton: some View {
        JRefreshButton(help: "Probe the local Ollama server") {
            Task { await appState.refreshOllamaStatus() }
        }
    }

    var body: some View {
        JCard {
            JCardHead(icon: "sparkles", title: "Ollama", accessory: refreshButton)

            JRow(title: "Model", first: true) {
                Text(JarvisModel.name)
                    .font(JType.kv)
                    .foregroundStyle(JColor.ink2)
            }
            JRow(title: "Intent router",
                 sub: "Learns from your commands · served by the backend") {
                Text("t5-small · int8 ONNX")
                    .font(JType.kv)
                    .foregroundStyle(JColor.ink2)
            }
            JRow(title: "Speech to text",
                 sub: "On-device transcription") {
                Text("Whisper large-v3-turbo")
                    .font(JType.kv)
                    .foregroundStyle(JColor.ink2)
            }
            JRow(title: "Endpoint") {
                Text("127.0.0.1:11434")
                    .font(JType.kv)
                    .foregroundStyle(JColor.ink2)
            }
            JRow(title: "Status") {
                JChip(
                    text: appState.ollamaReachable ? "Ready" : "Offline",
                    kind: appState.ollamaReachable ? .ok : .neutral
                )
            }
        }
    }
}

// MARK: - Postgres detail

private struct PostgresDetail: View {
    @ObservedObject var appState: AppState
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var notice: String?

    private var refreshButton: some View {
        JRefreshButton(help: "Refresh Postgres status") {
            Task { await appState.refreshPostgresStatus() }
        }
    }

    var body: some View {
        JCard {
            JCardHead(icon: "cylinder", title: "PostgreSQL", accessory: refreshButton)

            Text("Event logging target. The password is stored in your macOS Keychain.")
                .font(JType.rowSub)
                .foregroundStyle(JColor.ink2)
                .fixedSize(horizontal: false, vertical: true)

            JRow(title: "Event logging",
                 sub: appState.postgresConfigured
                    ? "Write commands + stats to Postgres"
                    : "Configure below to enable",
                 first: true) {
                JSwitch(binding: $appState.eventLoggingEnabled)
                    .disabled(!appState.postgresConfigured)
            }

            TextField("Host", text: $appState.postgresForm.host)
                .jField()
                .padding(.top, 9)

            HStack(spacing: 8) {
                TextField("Port", text: $appState.postgresForm.port)
                    .jField()
                    .frame(width: 90)
                TextField("Database", text: $appState.postgresForm.database)
                    .jField()
            }
            .padding(.top, 8)

            TextField("User", text: $appState.postgresForm.user)
                .jField()
                .padding(.top, 8)

            SecureField("Password (leave blank to keep)", text: $appState.postgresForm.password)
                .jField()
                .padding(.top, 8)

            if let notice {
                Text(notice)
                    .font(JType.rowSub)
                    .foregroundStyle(JColor.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        isSaving = true
                        notice = nil
                        notice = await appState.savePostgresCredentials()
                        isSaving = false
                    }
                } label: {
                    Text(isSaving ? "Saving…" : "Save")
                }
                .disabled(isSaving || appState.postgresForm.host.isEmpty
                    || appState.postgresForm.database.isEmpty
                    || appState.postgresForm.user.isEmpty)
                .jButton(intent: .primary)

                Button {
                    Task {
                        isTesting = true
                        notice = nil
                        notice = await appState.testPostgresConnection()
                        isTesting = false
                    }
                } label: {
                    Text(isTesting ? "Testing…" : "Test")
                }
                .disabled(isTesting)
                .jButton()
            }
            .padding(.top, 9)
        }
    }
}
