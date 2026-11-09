import SwiftUI
import AppKit

struct ConnectorsView: View {
    @ObservedObject var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spotify · Native macOS controls")
            Text(appState.spotifyStatusText)
            Button("Open Spotify") { NSWorkspace.shared.open(URL(string: "spotify:")!) }
        }
        .task { await appState.refreshSpotifyStatus() }
    }
}
