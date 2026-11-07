//! Transcript policies and diagnostics. No microphone, UI, files or logging I/O.
use crate::text_policy::*;
use std::collections::{HashMap, HashSet};
use unicode_normalization::UnicodeNormalization;
fn equal(a: &str, b: &str) -> bool {
    a.nfc().eq(b.nfc())
}
fn words(s: &str) -> Vec<String> {
    s.split(' ')
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}
#[uniffi::export]
pub fn normalize_compact(text: String) -> String {
    replace(r"[^a-z0-9]", &text.to_lowercase(), "")
}
#[uniffi::export]
pub fn hallucinated_singleton(text: String) -> bool {
    [
        "thankyou",
        "thanks",
        "you",
        "thankyouthankyou",
        "okay",
        "ok",
        "thankyouforwatching",
        "thanksforwatching",
        "thankyouverymuch",
        "subtitlesby",
        "blankaudio",
        "youyouyou",
    ]
    .contains(&normalize_compact(text).as_str())
}
#[uniffi::export]
pub fn normalized_tokens(text: String) -> Vec<String> {
    words(&replace(r"[^a-z0-9\s]", &text.to_lowercase(), " "))
}
#[uniffi::export]
pub fn sanitize_spoken(text: String) -> String {
    replace(r"^[\p{Punctuation}\s]+", text.trim_matches(is_space), "")
        .trim_matches(is_space)
        .to_string()
}
#[uniffi::export]
pub fn contains_wake_word(text: String) -> bool {
    has(r"\bjarvis\b", &text.to_lowercase())
}
#[uniffi::export]
pub fn normalize_misheard_targets(command: String) -> String {
    let aliases = [
        (r"(?:chant\s*gpt|changpt|chat\s+gpt)", "ChatGPT"),
        (r"(?:breif|brief|beave)(?:\s+browser)?", "Brave Browser"),
        (r"(?:get her|getha|get|gate) desktop", "GitHub Desktop"),
    ];
    let browser =
        r"(?:brave(?: browser)?|brief|breif|beave|google chrome|chrome|safari|firefox|edge|arc)";
    let mut result = command;
    for (alias, target) in aliases {
        let patterns = [
            format!(
                r"(?i)^(open|close|launch|start|quit)\s+(?:the\s+)?(?:{alias})([.!?]*|\s+(?:in|on|using|with)\s+{browser}[.!?]*)$"
            ),
            format!(
                r"(?i)^((?:open|create|make)\s+.+?\s+(?:in|on|using|with)\s+)(?:{alias})([.!?]*)$"
            ),
        ];
        for (i, p) in patterns.iter().enumerate() {
            if let Some(g) = captures(p, &result) {
                result = format!(
                    "{}{}{}{}",
                    g[0],
                    if i == 0 { " " } else { "" },
                    target,
                    g[1]
                );
            }
        }
    }
    result
}
#[uniffi::export]
pub fn remove_wake_fragment(command: String) -> String {
    let mut tokens = words(&command);
    let Some(last) = tokens.last() else {
        return command;
    };
    if ["ja", "jar", "jarv", "jarvi", "jarvis"].contains(&last.to_lowercase().as_str()) {
        tokens.pop();
    }
    tokens.join(" ").trim_matches(is_space).to_string()
}
#[uniffi::export]
pub fn collapse_repeated_words(text: String) -> String {
    let mut output: Vec<String> = vec![];
    for token in words(&text) {
        if !output
            .last()
            .is_some_and(|last| equal(&last.to_lowercase(), &token.to_lowercase()))
        {
            output.push(token);
        }
    }
    output.join(" ")
}
#[uniffi::export]
pub fn collapse_repeated_phrases(text: String, max_phrase_words: i64, min_repeats: i64) -> String {
    if min_repeats < 1 {
        return text;
    }
    let tokens = words(&text);
    let minimum = min_repeats as usize;
    if tokens.len() / 2 < minimum {
        return text;
    }
    let core: Vec<String> = tokens
        .iter()
        .map(|s| {
            replace(
                r"^[^\p{L}\p{M}\p{N}]+|[^\p{L}\p{M}\p{N}]+$",
                &s.to_lowercase(),
                "",
            )
            .nfc()
            .collect()
        })
        .collect();
    let mut output: Vec<String> = vec![];
    let mut index = 0;
    while index < tokens.len() {
        let mut collapsed = false;
        let maximum = (max_phrase_words.max(0) as usize).min((tokens.len() - index) / minimum);
        if maximum >= 2 {
            for length in (2..=maximum).rev() {
                let matches = |other: usize| -> bool {
                    (0..length).all(|offset| {
                        !core[index + offset].is_empty()
                            && !core[other + offset].is_empty()
                            && core[index + offset] == core[other + offset]
                    })
                };
                let mut repeats = 1;
                while (repeats + 1) * length <= tokens.len() - index
                    && matches(index + repeats * length)
                {
                    repeats += 1;
                }
                if repeats >= minimum {
                    output.extend_from_slice(&tokens[index..index + length]);
                    index += repeats * length;
                    collapsed = true;
                    break;
                }
            }
        }
        if !collapsed {
            output.push(tokens[index].clone());
            index += 1;
        }
    }
    output.join(" ")
}
#[uniffi::export]
pub fn repeated_phrase_loop(text: String) -> bool {
    !equal(&collapse_repeated_phrases(text.clone(), 10, 3), &text)
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct VoiceSegment {
    pub before_normalization: String,
    pub normalized: String,
    pub capped: String,
}
#[uniffi::export]
pub fn prepare_voice_segment(text: String) -> VoiceSegment {
    let cleaned = collapse_repeated_phrases(
        collapse_repeated_words(remove_wake_fragment(sanitize_spoken(text))),
        10,
        3,
    );
    let cleaned = replace(r"\b(please|okay|ok|uh|um|you know|like)\b", &cleaned, " ");
    let cleaned = replace(r"\s+", &cleaned, " ")
        .trim_matches(is_space)
        .to_string();
    let cleaned = replace(r"(?i)\bjarvis\b", &cleaned, " ");
    let before = replace(r"\s+", &cleaned, " ")
        .trim_matches(is_space)
        .to_string();
    let normalized = normalize_misheard_targets(before.clone());
    let tokens = words(&normalized);
    let capped = if tokens.len() > 8 {
        tokens[..8].join(" ")
    } else {
        normalized.clone()
    };
    VoiceSegment {
        before_normalization: before,
        normalized,
        capped,
    }
}
#[derive(Clone, Debug, uniffi::Record)]
pub struct TranscriptBatch {
    pub commands: Vec<String>,
    pub logs: Vec<String>,
}
fn app_target(command: &str) -> Option<(String, String)> {
    let lower = command.to_lowercase();
    for prefix in ["open ", "close ", "launch ", "start ", "run "] {
        if let Some(t) = lower.strip_prefix(prefix) {
            return Some((
                prefix.trim_matches(is_space).to_string(),
                t.trim_matches(is_horizontal_space).to_string(),
            ));
        }
    }
    None
}
#[uniffi::export]
pub fn sanitize_transcript_batch(raw: Vec<String>, max_batch_size: i64) -> TranscriptBatch {
    let mut logs = vec![];
    let mut winner: HashMap<String, String> = HashMap::new();
    for cmd in &raw {
        if let Some((verb, target)) = app_target(cmd) {
            let key: String = target.nfc().collect();
            if let Some(prev) = winner.get(&key) {
                let prev_verb = app_target(prev).map(|x| x.0).unwrap_or_else(|| "?".into());
                logs.push(format!(
                    "[Conflict] resolved: {target} {prev_verb} → {verb} (last wins)"
                ));
            }
            winner.insert(key, cmd.clone());
        }
    }
    let mut emitted = HashSet::new();
    let mut combined = vec![];
    for cmd in &raw {
        if let Some((_, target)) = app_target(cmd) {
            let key: String = target.nfc().collect();
            if winner.get(&key).is_some_and(|w| equal(w, cmd)) && emitted.insert(key) {
                combined.push(cmd.clone());
            }
        } else {
            combined.push(cmd.clone());
        }
    }
    let cap = max_batch_size.max(0) as usize;
    if combined.len() > cap {
        logs.push(format!(
            "[Batch] capped: {} → {cap} commands",
            combined.len()
        ));
        combined = combined.split_off(combined.len() - cap);
    }
    if combined.len() != raw.len() {
        logs.push(format!(
            "[Batch] sanitized: {} → {} commands",
            raw.len(),
            combined.len()
        ));
    }
    TranscriptBatch {
        commands: combined,
        logs,
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn targets_are_slots_not_literal_names() {
        assert_eq!(
            normalize_misheard_targets("open chant gpt in breif".into()),
            "open ChatGPT in Brave Browser"
        );
        assert_eq!(
            normalize_misheard_targets("open Brief project in Finder".into()),
            "open Brief project in Finder"
        );
        assert_eq!(
            normalize_misheard_targets("dictate chant gpt in brief".into()),
            "dictate chant gpt in brief"
        );
    }
    #[test]
    fn repeats_preserve_unicode_and_intentional_twice() {
        assert_eq!(
            collapse_repeated_phrases("go now GO NOW go now".into(), 10, 3),
            "go now"
        );
        assert_eq!(
            collapse_repeated_words("cafe\u{301} café cafe\u{301}".into()),
            "cafe\u{301}"
        );
        assert_eq!(
            collapse_repeated_phrases("very good very good".into(), 10, 3),
            "very good very good"
        );
        assert_eq!(
            collapse_repeated_phrases("a b a b a b".into(), 10, 0),
            "a b a b a b"
        );
    }
    #[test]
    fn batch_keeps_side_effects_and_last_app_target() {
        let b = sanitize_transcript_batch(
            vec!["open Notes", "close Notes", "next", "next"]
                .into_iter()
                .map(str::to_string)
                .collect(),
            3,
        );
        assert_eq!(b.commands, vec!["close Notes", "next", "next"]);
    }
}
