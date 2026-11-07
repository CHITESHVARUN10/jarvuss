//! Shared pure-text primitives. Patterns are trusted application constants.
use fancy_regex::Regex;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex, OnceLock},
};
use unicode_segmentation::UnicodeSegmentation;

pub fn rx(pattern: &str) -> Arc<Regex> {
    static CACHE: OnceLock<Mutex<HashMap<String, Arc<Regex>>>> = OnceLock::new();
    let mut cache = CACHE
        .get_or_init(Default::default)
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    cache
        .entry(pattern.to_string())
        .or_insert_with(|| Arc::new(Regex::new(pattern).expect("invalid application regex")))
        .clone()
}
pub fn has(pattern: &str, text: &str) -> bool {
    rx(pattern).is_match(text).unwrap_or(false)
}
pub fn captures(pattern: &str, text: &str) -> Option<Vec<String>> {
    let regex = rx(&format!("(?i){}", capture_pattern(pattern)));
    let c = regex.captures(text).ok()??;
    Some(
        (1..c.len())
            .map(|i| c.get(i).map_or("", |m| m.as_str()).to_string())
            .collect(),
    )
}
pub fn replace(pattern: &str, text: &str, replacement: &str) -> String {
    // Preserve the original input on a regex engine resource-limit error.
    rx(pattern)
        .try_replacen(text, 0, replacement)
        .map(|s| s.into_owned())
        .unwrap_or_else(|_| text.to_string())
}
pub fn remove(pattern: &str, text: &mut String) -> Option<Vec<String>> {
    let regex = rx(&format!("(?i){}", capture_pattern(pattern)));
    let c = regex.captures(text).ok()??;
    let full = c.get(0)?;
    let range = full.start()..full.end();
    let groups = (1..c.len())
        .map(|i| c.get(i).map_or("", |m| m.as_str()).to_string())
        .collect();
    text.replace_range(range, " ");
    Some(groups)
}
pub fn len(text: &str) -> usize {
    text.graphemes(true).count()
}
// Foundation CharacterSet.whitespaces includes U+200B; Rust's Unicode
// White_Space predicate does not. Keep the existing Swift trimming contract.
pub fn is_space(c: char) -> bool {
    c.is_whitespace() || c == '\u{200b}'
}
pub fn is_horizontal_space(c: char) -> bool {
    is_space(c)
        && !matches!(
            c,
            '\n' | '\r' | '\u{000b}' | '\u{000c}' | '\u{0085}' | '\u{2028}' | '\u{2029}'
        )
}
// NSRegularExpression capture APIs allow $ before one final line separator.
// Swift String's range/replacement APIs use strict end bounds instead; do not
// change those helpers. Only trusted application patterns pass through here.
fn capture_pattern(pattern: &str) -> String {
    let mut out = String::new();
    let mut escaped = false;
    let mut depth = 0usize;
    for c in pattern.chars() {
        if escaped {
            out.push(c);
            escaped = false;
            continue;
        }
        if c == '\\' {
            out.push(c);
            escaped = true;
            continue;
        }
        if c == '[' {
            depth += 1;
        } else if c == ']' {
            depth = depth.saturating_sub(1);
        }
        if c == '$' && depth == 0 {
            out.push_str(r"(?=\z|(?:\r\n|[\n\r\x{000b}\x{000c}\x{0085}\x{2028}\x{2029}])\z)");
        } else {
            out.push(c);
        }
    }
    out
}
pub fn clean_search(text: &str) -> String {
    let t = replace(
        r"(?i)^(?:(?:(?:hey|ok|okay)\s+)?jarvis[, ]+|please\s+|(?:can|could|would) you\s+)+",
        text.trim_matches(is_space),
        "",
    );
    let t = t.trim_matches(|c| " .!?".contains(c));
    replace(r"(?i)[, ]+(?:please|thank you|thanks)$", t, "")
        .trim_matches(is_space)
        .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn foundation_whitespace_and_capture_end_bounds() {
        assert!(is_space('\u{200b}'));
        assert!(is_horizontal_space('\u{200b}'));
        for suffix in [
            "\n", "\r", "\r\n", "\u{000b}", "\u{000c}", "\u{0085}", "\u{2028}", "\u{2029}",
        ] {
            assert!(captures(r"^(x)$", &format!("x{suffix}")).is_some());
            assert!(!has(r"x$", &format!("x{suffix}")));
            assert!(!is_horizontal_space(suffix.chars().next().unwrap()));
        }
        assert!(captures(r"^(cost\$)$", "cost$").is_some());
    }
}
