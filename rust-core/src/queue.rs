//! Port of Swift `CommandPriority.classify` — command queue priority rules.

/// Queue priority. Swift's `.low` is never produced by `classify` (it exists
/// for future buffer-management use), so the exported mirror only carries the
/// two reachable levels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CommandPriority {
    High,
    Normal,
}

/// Classify a raw command string into a priority level.
pub fn classify(text: &str) -> CommandPriority {
    let lower = text.to_lowercase();

    // Time / date / stop / cancel — always high.
    const TIME_TERMS: &[&str] = &[
        "what time",
        "what is the time",
        "tell me the time",
        "current time",
        "what day",
        "what date",
        "what month",
        "what year",
        "stop",
        "cancel",
        "abort",
    ];
    if TIME_TERMS.iter().any(|t| lower.contains(t)) {
        return CommandPriority::High;
    }

    // Media — high; exact token or word-prefixed phrase only.
    const MEDIA_TERMS: &[&str] = &[
        "play",
        "pause",
        "next",
        "previous",
        "prev",
        "skip",
        "resume",
        "next song",
        "next track",
        "previous song",
        "liked songs",
    ];
    if MEDIA_TERMS
        .iter()
        .any(|t| lower == *t || lower.starts_with(&format!("{t} ")))
    {
        return CommandPriority::High;
    }

    // Volume — always high (user expects instant feedback).
    const VOLUME_TERMS: &[&str] = &[
        "mute",
        "unmute",
        "increase volume",
        "decrease volume",
        "increase sound",
        "decrease sound",
        "increase audio",
        "decrease audio",
        "volume up",
        "volume down",
        "sound up",
        "sound down",
        "turn up",
        "turn down",
        "louder",
        "quieter",
        "lower volume",
        "lower sound",
        "set volume",
        "sound off",
        "sound on",
        "raise volume",
        "raise the volume",
        "reduce volume",
        "reduce the volume",
    ];
    if VOLUME_TERMS.iter().any(|t| lower.contains(t)) {
        return CommandPriority::High;
    }

    // Close app — high so it is never delayed behind a queue.
    if lower.starts_with("close ") {
        return CommandPriority::High;
    }

    CommandPriority::Normal
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_and_cancel_are_high() {
        assert_eq!(classify("what time is it"), CommandPriority::High);
        assert_eq!(classify("stop"), CommandPriority::High);
        assert_eq!(classify("cancel that"), CommandPriority::High);
    }

    #[test]
    fn media_token_prefix_is_high() {
        assert_eq!(classify("play"), CommandPriority::High);
        assert_eq!(classify("pause the music"), CommandPriority::High);
        assert_eq!(classify("next song"), CommandPriority::High);
        // "playlist" must NOT match the "play" token rule.
        assert_eq!(classify("playlist workout"), CommandPriority::Normal);
    }

    #[test]
    fn volume_and_close_are_high() {
        assert_eq!(classify("volume up"), CommandPriority::High);
        assert_eq!(classify("make it quieter"), CommandPriority::High);
        assert_eq!(classify("close spotify"), CommandPriority::High);
    }

    #[test]
    fn everything_else_is_normal() {
        assert_eq!(classify("open chrome"), CommandPriority::Normal);
        assert_eq!(classify("what is the weather"), CommandPriority::Normal);
    }
}
