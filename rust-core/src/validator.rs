//! Port of Swift `CommandValidator` — clean + validate raw command strings.

use regex::Regex;
use std::sync::OnceLock;

const TRAILING_STRIP_WORDS: &[&str] = &["and", "then", "please", "okay", "ok", "now", "jarvis"];
const MINIMUM_LENGTH: usize = 3;

fn jarvis_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\bjarvis\b").expect("jarvis regex"))
}

fn squash_ws_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").expect("ws regex"))
}

pub fn strip_trailing_fillers(input: &str) -> String {
    let mut current = input.trim().to_string();
    loop {
        let lower = current.to_lowercase();
        let mut stripped: Option<String> = None;
        for word in TRAILING_STRIP_WORDS {
            let s1 = format!(" {word}");
            let s2 = format!(", {word}");
            if lower.ends_with(&s1) {
                stripped = Some(current[..current.len() - s1.len()].trim().to_string());
                break;
            } else if lower.ends_with(&s2) {
                stripped = Some(current[..current.len() - s2.len()].trim().to_string());
                break;
            }
        }
        match stripped {
            Some(next) => current = next,
            None => return current,
        }
    }
}

/// Clean and validate a raw command string.
/// Returns the cleaned string, or `None` when it must be rejected.
pub fn validate(raw: &str) -> Option<String> {
    let mut cleaned = squash_ws_re()
        .replace_all(raw.trim(), " ")
        .into_owned();
    if cleaned.is_empty() {
        return None;
    }
    cleaned = strip_trailing_fillers(&cleaned);
    if cleaned.is_empty() || cleaned.len() < MINIMUM_LENGTH {
        return None;
    }
    // Strip residual wake-word tokens rather than rejecting.
    if jarvis_re().is_match(&cleaned) {
        cleaned = squash_ws_re()
            .replace_all(&jarvis_re().replace_all(&cleaned, " "), " ")
            .trim()
            .to_string();
        if cleaned.is_empty() {
            return None;
        }
    }
    // Reject commands ending with a dangling conjunction/article.
    let lower = cleaned.to_lowercase();
    let last = lower.split_whitespace().last().unwrap_or("");
    if matches!(
        last,
        "and" | "then" | "or" | "but" | "with" | "to" | "the" | "a" | "an"
    ) {
        return None;
    }
    // Reject pure punctuation / numbers.
    if cleaned.chars().filter(|c| c.is_alphabetic()).count() < 2 {
        return None;
    }
    let word_count = cleaned.split_whitespace().count();
    // Hard absolute cap: > 15 words is garbled speech.
    if word_count > 15 {
        return None;
    }
    // System commands > 10 words are run-on garbage (AI queries exempt).
    let system_prefixes = [
        "open ", "close ", "play ", "search ", "launch ", "run ", "create ", "start ",
        "next ", "previous ", "increase ", "decrease ", "mute", "unmute", "pause",
    ];
    if system_prefixes.iter().any(|p| lower.starts_with(p)) && word_count > 10 {
        return None;
    }
    Some(cleaned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_normal_command() {
        assert_eq!(validate("open Chrome"), Some("open Chrome".to_string()));
    }

    #[test]
    fn strips_trailing_filler() {
        // Trailing "and" is stripped, leaving a valid command (Swift parity).
        assert_eq!(
            validate("open Chrome and"),
            Some("open Chrome".to_string())
        );
        assert_eq!(
            validate("open Chrome please"),
            Some("open Chrome".to_string())
        );
        // Bare conjunction with nothing left is rejected.
        assert_eq!(validate("and"), None);
    }

    #[test]
    fn strips_wake_word() {
        assert_eq!(
            validate("open Chrome jarvis"),
            Some("open Chrome".to_string())
        );
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(validate(""), None);
        assert_eq!(validate("ab"), None);
        assert_eq!(validate("..."), None);
        assert_eq!(validate(&"word ".repeat(20)), None);
    }
}
