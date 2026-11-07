import Foundation

/// Rust owns shuffle interpretation; Spotify execution remains native.
enum SpotifyShuffleParser {
    static func parse(_ raw: String) -> MediaAction? {
        guard let request = coreParseSpotifyShuffle(raw: raw) else { return nil }
        switch request.target {
        case .current: return .setShuffle(request.enabled)
        case .liked: return .playLikedWithShuffle(request.enabled)
        case .playlist: return .playPlaylistWithShuffle(name: request.name, enabled: request.enabled)
        }
    }
}
