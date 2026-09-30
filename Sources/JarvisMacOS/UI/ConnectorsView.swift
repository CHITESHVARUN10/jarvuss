import SwiftUI
import AppKit

struct ConnectorsView: View {
    @ObservedObject var appState: AppState
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var isExpanded = false
    @State private var isSaving = false
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text("Spotify")
                        .font(JarvisType.title)
                        .foregroundStyle(JarvisColor.textPrimary)
                    Spacer()
                    Text(appState.spotifyStatusText)
                        .font(JarvisType.dataSmall)
                        .foregroundStyle(JarvisColor.textTertiary)
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(JarvisColor.textTertiary)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text("Paste your Spotify Developer keys, Save, then Connect to authorize. Keys are stored in the backend .env — never logged.")
                    .font(JarvisType.caption)
                    .foregroundStyle(JarvisColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    SecureField("Client ID", text: $clientID)
                        .quietField()

                    SecureField("Client Secret", text: $clientSecret)
                        .quietField()
                }

                if let notice {
                    Text(notice)
                        .font(JarvisType.caption)
                        .foregroundStyle(JarvisColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "Saving…" : "Save Keys")
                    }
                    .disabled(isSaving || clientID.isEmpty || clientSecret.isEmpty)
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.accent, compact: true))

                    Button {
                        Task { await connect() }
                    } label: {
                        Text("Connect")
                    }
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.ok, compact: true))

                    Button {
                        Task { await appState.refreshSpotifyStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(JarvisButtonStyle(color: JarvisColor.textSecondary, compact: true))
                }
            }
        }
        .task { await appState.refreshSpotifyStatus() }
    }

    private var dotColor: Color {
        if appState.spotifyLinked { return JarvisColor.ok }
        if appState.spotifyStatusText == "Backend unreachable" { return JarvisColor.textTertiary }
        return JarvisColor.attention
    }

    private func save() async {
        isSaving = true
        notice = nil
        do {
            try await appState.spotifyClient.saveCredentials(clientID: clientID, clientSecret: clientSecret)
            clientSecret = ""
            await appState.refreshSpotifyStatus()
            notice = "Keys saved. Hit Connect to authorize in your browser."
        } catch {
            notice = error.localizedDescription
        }
        isSaving = false
    }

    private func connect() async {
        notice = nil
        do {
            let url = try await appState.spotifyClient.connectURL()
            NSWorkspace.shared.open(url)
            notice = "Browser opened — approve Spotify access, then hit refresh."
        } catch {
            notice = error.localizedDescription
        }
    }
}
