//! Port of Swift `CommandValidator` — clean + validate raw command strings.

use regex::Regex;
use std::sync::OnceLock;

const TRAILING_STRIP_WORDS: &[&str] = &["and", "then", "please", "okay", "ok", "now", "jarvis"];
const MINIMUM_LENGTH: usize = 3;

/// Trailing politeness / sign-off phrases, stripped before the word-level pass.
const TRAILING_PHRASES: &[&str] = &[
    "thank you very much",
    "thank you so much",
    "thanks a lot",
    "thank you",
    "thanks",
    "that's all",
    "thats all",
    "that will be all",
    "that's it",
    "if you can",
    "if you could",
    "for me please",
    "please do",
    "for me",
];

/// Action verbs — used to tell a genuine multi-intent compound command from a
/// single-verb run-on that should still be rejected.
const ACTION_VERBS: &[&str] = &[
    "open", "close", "launch", "quit", "play", "pause", "resume", "stop", "next", "previous",
    "prev", "skip", "search", "google", "find", "list", "count", "show", "tell", "create",
    "make", "run", "start", "increase", "decrease", "set", "turn", "mute", "unmute", "check",
    "calculate", "summarise", "summarize", "rename", "move", "delete", "sort",
];

fn jarvis_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\bjarvis\b").expect("jarvis regex"))
}

fn squash_ws_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").expect("ws regex"))
}

/// Strip trailing politeness phrases (longest match first, repeats until stable).
pub fn strip_trailing_phrases(input: &str) -> String {
    let mut current = input.trim().to_string();
    loop {
        let lower = current.to_lowercase();
        let mut stripped: Option<String> = None;
        'outer: for phrase in TRAILING_PHRASES {
            for sep in [" ", ", ", ". ", "! "] {
                let base = format!("{sep}{phrase}");
                for suffix in [format!("{base}."), base.clone()] {
                    if lower.ends_with(&suffix) {
                        stripped = Some(
                            current[..current.len() - suffix.len()]
                                .trim_matches(|c: char| {
                                    c.is_whitespace() || matches!(c, ',' | '.' | '!' | '?' | ';')
                                })
                                .to_string(),
                        );
                        break 'outer;
                    }
                }
            }
        }
        match stripped {
            Some(next) => current = next,
            None => return current,
        }
    }
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
    cleaned = strip_trailing_fillers(&strip_trailing_phrases(&cleaned));
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
    let tokens: Vec<String> = lower
        .split_whitespace()
        .map(|t| {
            t.trim_matches(|c: char| !c.is_alphanumeric())
                .to_string()
        })
        .filter(|t| !t.is_empty())
        .collect();
    let verb_count = tokens
        .iter()
        .filter(|t| ACTION_VERBS.contains(&t.as_str()))
        .collect::<std::collections::HashSet<_>>()
        .len();
    let is_compound = verb_count >= 2;

    // Length alone is only suspicious for single-action input — compound
    // commands ("open X and play Y, then search Z") are legitimately long.
    let word_cap = if is_compound { 40 } else { 15 };
    if word_count > word_cap {
        return None;
    }
    // Single-action system commands stay tightly capped.
    let system_prefixes = [
        "open ", "close ", "play ", "search ", "launch ", "run ", "create ", "start ",
        "next ", "previous ", "increase ", "decrease ", "mute", "unmute", "pause",
    ];
    if system_prefixes.iter().any(|p| lower.starts_with(p)) && !is_compound && word_count > 10 {
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

    #[test]
    fn accepts_long_compound_commands() {
        // Multi-intent speech is legitimately long — 2+ action verbs pass.
        let compound = "open spotify, open whatsapp and also open youtube and in spotify play a song";
        assert_eq!(validate(compound), Some(compound.to_string()));

        let polite = "Open Chrome and in Chrome open YouTube and in that search for iPhone. Thank you.";
        assert!(validate(polite).is_some());
        assert!(!validate(polite).unwrap().to_lowercase().contains("thank"));
    }

    #[test]
    fn still_rejects_single_verb_run_on() {
        assert_eq!(
            validate("open the thing i was telling you about yesterday afternoon mate"),
            None
        );
    }

    #[test]
    fn strips_trailing_politeness() {
        assert_eq!(
            validate("open chrome thank you"),
            Some("open chrome".to_string())
        );
    }
}
