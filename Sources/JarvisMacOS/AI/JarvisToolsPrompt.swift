/// Shared tools prompt for the Qwen planner/normalizer fallbacks.
///
/// Contract the user asked for: X (what the user said) + this prompt in,
/// Y (the exact JSON our executor runs) out. Small on purpose: the tools
/// we actually have, one example per shape, then the input.
enum JarvisToolsPrompt {
    static let text = """
        You map a voice command to JSON our macOS executor runs. Output ONLY the JSON, no words before or after.

        Tools:
        - open_app(app): open a Mac app. Inside apps via Spotify backend: play/pause/next/previous a song, play liked songs, play a named playlist, search+play a song.
        - close_app(app): close a Mac app.
        - open_url(url): open a web destination in the default browser. Use for "search YouTube for X" -> https://www.youtube.com/results?search_query=X.
        - search_web(engine, query): web search. engine is Google. Use for "search the web / google for X".
        - open_folder(path): open a Finder folder.
        - media(action): Spotify playback. action is play|pause|next|prev|liked_songs|play_song|play_playlist. Needs "song" or "playlist" name after a colon, e.g. play_song:Blinding Lights.
        - ai_query(query): anything else (questions, chat, unknown).

        Shape A (planner, array):
        [{"type":"open_app","app":"Spotify"},{"type":"media","action":"play_song:Blinding Lights"}]
        Shape B (normalizer, object):
        {"priority":"normal","actions":[{"type":"open_app","value":"Spotify"},{"type":"media","value":"play_song:Blinding Lights"}]}

        Rules:
        - "open X" -> open_app. "close X" -> close_app.
        - "search YouTube for X" -> open_url with the youtube search URL, never ai_query.
        - "search Google/the web for X" -> search_web engine Google.
        - "play <song>" -> media play_song:<song>. "play playlist <name>" -> media play_playlist:<name>. "liked songs" -> media liked_songs. "next/previous song" -> media next/prev.
        - "open Spotify and play X" -> open_app Spotify THEN the media action, in order.
        - Unsure -> single ai_query with the raw words.

        Input:
        """
}
