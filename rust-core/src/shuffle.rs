//! Playlist/shuffle interpretation only; playback is delegated to the native adapter.
use crate::text_policy::*;
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum ShuffleTarget {
    Current,
    Liked,
    Playlist,
}
#[derive(Clone, Debug, PartialEq, uniffi::Record)]
pub struct ShuffleRequest {
    pub target: ShuffleTarget,
    pub name: String,
    pub enabled: bool,
}
fn result(target: ShuffleTarget, enabled: bool, name: String) -> Option<ShuffleRequest> {
    Some(ShuffleRequest {
        target,
        enabled,
        name,
    })
}
fn state(enabled: bool) -> Option<ShuffleRequest> {
    result(ShuffleTarget::Current, enabled, String::new())
}
fn strip(pattern: &str, text: &mut String) -> bool {
    if let Ok(Some(m)) = rx(pattern).find(text) {
        let range = m.start()..m.end();
        text.replace_range(range, "");
        true
    } else {
        false
    }
}
#[uniffi::export]
pub fn parse_spotify_shuffle(raw: String) -> Option<ShuffleRequest> {
    parse(&raw)
}
pub fn parse(raw: &str) -> Option<ShuffleRequest> {
    let mut text = replace(r"(?i)\s+(?:on|in) spotify$", &clean_search(raw), "");
    let lower = text.to_lowercase();
    if captures(
        r"^(?:turn|switch|set) (?:the )?shuffle(?: mode)? (on|off)$",
        &lower,
    )
    .is_some()
    {
        return state(lower.ends_with("on"));
    }
    if ["turn on shuffle", "enable shuffle", "put shuffle on"].contains(&lower.as_str()) {
        return state(true);
    }
    if [
        "turn off shuffle",
        "disable shuffle",
        "stop shuffling",
        "don't shuffle",
    ]
    .contains(&lower.as_str())
    {
        return state(false);
    }
    if [
        "shuffle",
        "shuffle on",
        "shuffle it",
        "shuffle the music",
        "shuffle music",
        "shuffle this playlist",
        "shuffle the playlist",
        "shuffle current playlist",
    ]
    .contains(&lower.as_str())
    {
        return state(true);
    }
    if lower == "shuffle off" {
        return state(false);
    }
    if !lower.starts_with("play ") && !lower.starts_with("shuffle ") {
        return None;
    }
    if has(
        r"\b(?:and|then)\s+(?:open|close|find|search|delete|run|set|turn|pause|skip|play|resume|stop)\b",
        &lower,
    ) || has(r"\b(?:and|then)\s+shuffle\s+(?!(?:it|them)\s*$)", &lower)
    {
        return None;
    }
    let mut enabled = true;
    if !lower.starts_with("shuffle ") {
        let off = r"(?i)\s+(?:without shuffle|with shuffle off|in order|sequentially)$";
        let on = r"(?i)[,\s]+(?:(?:and|then)\s+)?(?:shuffle(?:\s+(?:it|them))?|(?:on|with|in) shuffle(?: mode)?(?: on)?|shuffled|in (?:a )?random order)$";
        if strip(off, &mut text) {
            enabled = false;
        } else if strip(on, &mut text) {
        } else if has(r"(?i)^play shuffled\s+", &text) {
            text = replace(r"(?i)^play shuffled\s+", &text, "play ");
        } else {
            return None;
        }
    }
    if !has(r"(?i)\bplaylist\b", &text)
        && has(
            r"(?i)\b(?:(?:liked|light|saved|favorite|favourite)\s+(?:songs|tracks|music)|favorites|favourites)\b",
            &text,
        )
    {
        return result(ShuffleTarget::Liked, enabled, String::new());
    }
    let name = if let Some(g) = captures(r"\bplaylist\s+(?:(?:called|named)\s+)?(.+)$", &text) {
        g[0].clone()
    } else if let Some(g) = captures(r"^(.+?)\s+playlist$", &text) {
        replace(
            r"(?i)^(?:(?:play|shuffle|songs?|tracks?|music|a|some|from|in|my|the)\s+)+",
            &g[0],
            "",
        )
    } else {
        return None;
    };
    let name = name.trim_matches(|c: char| is_space(c) || "\"“”".contains(c));
    if name.is_empty() || len(name) > 200 {
        return None;
    }
    result(ShuffleTarget::Playlist, enabled, name.to_string())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn literal_names_and_compounds() {
        assert_eq!(
            parse("play the Botanical Hours playlist with shuffle on")
                .unwrap()
                .name,
            "Botanical Hours"
        );
        assert!(
            !parse("play playlist called \"Äther 🧑🏽‍💻\" without shuffle")
                .unwrap()
                .enabled
        );
        for text in [
            "play playlist called \"Shuffle On\"",
            "shuffle Gym playlist and open Safari",
            "shuffle Gym playlist and shuffle Focus playlist",
            "explain shuffle algorithms",
        ] {
            assert!(parse(text).is_none(), "{text}");
        }
        assert_eq!(
            parse("turn shuffle off").unwrap().target,
            ShuffleTarget::Current
        );
    }
}
