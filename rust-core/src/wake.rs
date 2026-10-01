//! Port of Swift `WakeWordManager` — prefix wake-word detection/extraction.

/// True when the text (trimmed, case-insensitive) starts with the wake word.
pub fn is_wake_word_detected(text: &str, wake_word: &str) -> bool {
    let word = wake_word.to_lowercase();
    text.to_lowercase()
        .trim()
        .starts_with(&word)
}

/// Strip the leading wake word from the text (if present) and trim.
/// Char-based (not byte-based) so a non-ASCII utterance can't panic the slice.
pub fn extract_command(text: &str, wake_word: &str) -> String {
    let trimmed = text.trim();
    let word = wake_word.to_lowercase();
    if trimmed.to_lowercase().starts_with(&word) {
        let rest: String = trimmed.chars().skip(word.chars().count()).collect();
        rest.trim().to_string()
    } else {
        trimmed.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_prefix_case_insensitively() {
        assert!(is_wake_word_detected("Jarvis open chrome", "jarvis"));
        assert!(is_wake_word_detected("  JARVIS play music", "jarvis"));
        assert!(!is_wake_word_detected("hey jarvis open chrome", "jarvis"));
        assert!(!is_wake_word_detected("open jarvis", "jarvis"));
    }

    #[test]
    fn extracts_command_after_wake_word() {
        assert_eq!(extract_command("Jarvis open chrome", "jarvis"), "open chrome");
        assert_eq!(extract_command("  jarvis   play   music ", "jarvis"), "play   music");
        assert_eq!(extract_command("open chrome", "jarvis"), "open chrome");
    }
}
