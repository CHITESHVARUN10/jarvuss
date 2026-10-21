import SwiftUI
import AppKit

// MARK: - Connections

struct NoirConnectionsPage: View {
    @ObservedObject var appState: AppState
    @EnvironmentObject private var toasts: ToastCenter

    @State private var activeConnection: ConnectionKind?

    var body: some View {
        NoirPage(
            eyebrow: "A few good connections",
            title: "Your tools, in conversation.",
            sub: "Bring your music, local intelligence, and activity storage together."
        ) {
            VStack(spacing: 12) {
                connectionCard(.spotify)
                connectionCard(.ollama)
                connectionCard(.postgres)
            }

            NoirSectionHeading(title: "More possibilities")

            NoirCard(padded: true) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("More connections, in time.")
                            .font(.system(size: 12))
                            .foregroundStyle(NoirPalette.text)
                        Text("New integrations will appear here when they’re available.")
                            .font(.system(size: 11))
                            .foregroundStyle(NoirPalette.muted)
                    }
                    Spacer(minLength: 8)
                    Button {
                    } label: {
                        Label("Add connection", systemImage: "plus")
                    }
                    .buttonStyle(NoirButtonStyle(intent: .quiet))
                    .disabled(true)
                }
            }

            Text("Connection forms talk only to the services you configure. Secrets stay in the macOS Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(NoirPalette.muted)
                .padding(.top, 18)
        }
        .task {
            await appState.refreshSpotifyStatus()
            await appState.refreshPostgresStatus()
            await appState.refreshOllamaStatus()
        }
        .sheet(item: $activeConnection) { kind in
            ConnectionSheet(appState: appState, kind: kind)
                .environmentObject(toasts)
        }
    }

    // MARK: Cards

    private func connectionCard(_ kind: ConnectionKind) -> some View {
        Button {
            activeConnection = kind
        } label: {
            HStack(spacing: 16) {
                connectionIcon(kind)

                VStack(alignment: .leading, spacing: 5) {
                    Text(kind.title)
                        .font(.system(size: 13))
                        .foregroundStyle(NoirPalette.text)
                    Text(description(for: kind))
                        .font(.system(size: 11))
                        .foregroundStyle(NoirPalette.muted)
                }

                Spacer(minLength: 8)

                let status = status(for: kind)
                NoirTag(text: status.text, kind: status.kind)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(NoirPalette.muted)
            }
            .padding(21)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(NoirPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(NoirPalette.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ConnectionCardButtonStyle())
    }

    private func connectionIcon(_ kind: ConnectionKind) -> some View {
        let color: Color
        switch kind {
        case .spotify:  color = NoirPalette.green
        case .ollama:   color = NoirPalette.accent
        case .postgres: color = NoirPalette.secondary
        }
        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.016))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(NoirPalette.line, lineWidth: 1)
            Image(systemName: kind.icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
        }
        .frame(width: 42, height: 42)
    }

    private func description(for kind: ConnectionKind) -> String {
        switch kind {
        case .spotify:  return "Your soundtrack, a voice command away."
        case .ollama:   return "Local answers. On your own terms."
        case .postgres: return "A home for your activity and insights."
        }
    }

    private func status(for kind: ConnectionKind) -> (text: String, kind: NoirTag.Kind) {
        switch kind {
        case .spotify:
            if appState.spotifyLinked { return ("Connected", .green) }
            if appState.spotifyStatusText == "Backend unreachable" { return ("Offline", .neutral) }
            return ("Set up", .amber)
        case .ollama:
            return appState.ollamaReachable ? ("Ready", .green) : ("Offline", .amber)
        case .postgres:
            if appState.postgresConfigured {
                return appState.eventLoggingEnabled ? ("Logging on", .green) : ("Paused", .amber)
            }
            return ("Set up", .neutral)
        }
    }
}

private struct ConnectionCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Color.white.opacity(0.015) : .clear)
            )
            .scaleEffect(configuration.isPressed ? 0.998 : 1)
    }
}

// MARK: - Connection sheet

struct ConnectionSheet: View {
    @ObservedObject var appState: AppState
    let kind: ConnectionKind

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var toasts: ToastCenter

    @State private var clientID = ""
    @State private var clientSecret = ""
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
                        .font(.system(size: 15))
                        .foregroundStyle(iconColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(NoirPalette.text)
                    Text(headerSub)
                        .font(.system(size: 11))
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
        .background(NoirPalette.base)
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
            Text("Paste your Spotify Developer keys, Save, then Connect to authorize. The client secret is stored in your macOS Keychain.")
                .font(.system(size: 11))
                .lineSpacing(5)
                .foregroundStyle(NoirPalette.muted)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Client ID", text: $clientID)
                .noirField()
                .noirFieldLabel("Client ID")

            SecureField("Client secret", text: $clientSecret)
                .noirField()
                .noirFieldLabel("Client secret")

            if let notice {
                noticeCard(notice)
            }
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
                factRow("Speech to text", "Whisper large-v3-turbo")
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
                .font(.system(size: 11))
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
                Button(busy ? "Saving…" : "Save keys") { saveSpotify() }
                    .buttonStyle(NoirButtonStyle())
                    .disabled(busy || clientID.isEmpty || clientSecret.isEmpty)
                Button("Connect") { connectSpotify() }
                    .buttonStyle(NoirButtonStyle(intent: .primary))
                    .disabled(busy)

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

    private func saveSpotify() {
        busy = true
        notice = nil
        Task {
            let backendReady = await BackendServiceManager.ensureRunningForFeature()
            guard backendReady else {
                notice = "Backend unavailable or turned off."
                busy = false
                return
            }
            do {
                try await appState.spotifyClient.saveCredentials(
                    clientID: clientID,
                    clientSecret: clientSecret
                )
                clientID = ""
                clientSecret = ""
                await appState.refreshSpotifyStatus()
                notice = "Keys saved. Connect to authorize in your browser."
                toasts.show("Spotify keys saved.")
            } catch {
                notice = error.localizedDescription
            }
            busy = false
        }
    }

    private func connectSpotify() {
        notice = nil
        Task {
            let backendReady = await BackendServiceManager.ensureRunningForFeature()
            guard backendReady else {
                notice = "Backend unavailable or turned off."
                return
            }
            do {
                let url = try await appState.spotifyClient.connectURL()
                NSWorkspace.shared.open(url)
                notice = "Browser opened — approve Spotify access, then refresh."
            } catch {
                notice = error.localizedDescription
            }
        }
    }

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
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(NoirPalette.secondary)
                .lineLimit(1)
        }
    }

    private func noticeCard(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
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
