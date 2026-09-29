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
                        .frame(width: 8, height: 8)
                    Text("Spotify")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.85))
                    Spacer()
                    Text(appState.spotifyStatusText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                        .lineLimit(1)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text("Paste your Spotify Developer keys, Save, then Connect to authorize. Keys are stored in the backend .env — never logged.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    SecureField("Client ID", text: $clientID)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.09)))

                    SecureField("Client Secret", text: $clientSecret)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.09)))
                }

                if let notice {
                    Text(notice)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await save() }
                    } label: {
                        Text(isSaving ? "Saving…" : "Save Keys")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(isSaving || clientID.isEmpty || clientSecret.isEmpty)
                    .buttonStyle(JarvisButtonStyle(color: Color(red: 0.55, green: 0.55, blue: 1.0), compact: true))

                    Button {
                        Task { await connect() }
                    } label: {
                        Text("Connect")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(JarvisButtonStyle(color: Color(red: 0.25, green: 0.90, blue: 0.65), compact: true))

                    Button {
                        Task { await appState.refreshSpotifyStatus() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(JarvisButtonStyle(color: Color.white.opacity(0.5), compact: true))
                }
            }
        }
        .task { await appState.refreshSpotifyStatus() }
    }

    private var dotColor: Color {
        if appState.spotifyLinked { return Color(red: 0.25, green: 0.90, blue: 0.65) }
        if appState.spotifyStatusText == "Backend unreachable" { return Color.white.opacity(0.25) }
        return Color(red: 1.0, green: 0.78, blue: 0.2)
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
