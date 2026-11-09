//! Deterministic dictation formatting and polish guard policy.
//!
//! Mirrors the Swift `TranscriptFormatter` rules pass and the
//! `DictationPolisher` sanitizer. The model call, prompt, timeout budget and
//! diagnostics delivery remain in Swift; this module owns only pure text
//! decisions.

use crate::text_policy::*;
use crate::transcript::{collapse_repeated_phrases, repeated_phrase_loop};
use regex::escape;
use unicode_normalization::UnicodeNormalization;

/// Formatting may change punctuation/case, not the dictated words or their
/// order. Length alone cannot detect a similarly sized invented sentence.
#[uniffi::export]
pub fn polish_preserves_content(reference: String, candidate: String, directive: Option<String>) -> bool {
    fn tokens(text: &str) -> Vec<String> {
        let normalized: String = text.to_lowercase().nfc().collect();
        rx(r"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*")
            .find_iter(&normalized).flatten().map(|m| m.as_str().replace('’', "'")).collect()
    }
    let mut expected = reference;
    // Explicit spoken punctuation is the sole word-to-symbol transformation.
    expected = replace(r"(?i)\b(?:question mark|exclamation point|full stop|semicolon|comma|period|colon)\b", &expected, " ");
    let mut actual = candidate;
    if directive.is_some() {
        expected = replace(r"(?i)\b(?:first(?:ly)?|second(?:ly)?|third(?:ly)?|finally|lastly)(?:\s+point(?:\s+is)?)?\b|\bpoint\s+(?:one|two|three|\d+)(?:\s+is)?\b", &expected, " ");
        actual = replace(r"(?m)^\s*\d+\.\s+", &actual, "");
    }
    tokens(&expected) == tokens(&actual)
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct FormattedTranscript {
    pub text: String,
    pub filler_removals: i32,
    pub correction_resolves: i32,
    pub unbounded_corrections: i32,
    pub has_enumeration: bool,
    pub input_words: i32,
    pub output_words: i32,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct SanitizeResult {
    pub text: Option<String>,
    pub reasons: Vec<String>,
}

fn trimmed(text: &str) -> &str {
    text.trim_matches(is_space)
}

fn words(text: &str) -> Vec<String> {
    text.split(' ')
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .collect()
}

fn word_count(text: &str) -> i32 {
    words(text).len() as i32
}

fn cleaned_word(token: &str) -> String {
    token
        .to_lowercase()
        .trim_matches(|c: char| !c.is_alphanumeric())
        .to_string()
}

fn ends_sentence_break(token: &str) -> bool {
    matches!(token.chars().last(), Some('.' | '!' | '?'))
}

fn normalize_whitespace(text: &str) -> String {
    let text = replace(r"[\t\n\r]+", text, " ");
    let text = replace(r"\s+([,.!?;:])", &text, "$1");
    let text = replace(r"\s{2,}", &text, " ");
    trimmed(&text).to_string()
}

fn collapse_duplicate_runs(text: &str) -> (String, i32) {
    let tokens = words(text);
    let mut kept: Vec<String> = Vec::with_capacity(tokens.len());
    let mut removed = 0;
    for token in tokens {
        if let Some(previous) = kept.last() {
            if previous.to_lowercase() == token.to_lowercase() && !ends_sentence_break(previous) {
                removed += 1;
                continue;
            }
        }
        kept.push(token);
    }
    if removed == 0 {
        (text.to_string(), 0)
    } else {
        (kept.join(" "), removed)
    }
}

enum CorrectionPass {
    Resolved(String),
    Left,
}

const RETRACTIONS: &[&[&str]] = &[
    &["no", "wait"],
    &["wait", "no"],
    &["scratch", "that"],
    &["or", "rather"],
    &["actually", "make", "that"],
];

fn retraction_match_at(tokens: &[String], index: usize) -> Option<usize> {
    for marker in RETRACTIONS {
        if index + marker.len() > tokens.len() {
            continue;
        }
        let matched = marker
            .iter()
            .enumerate()
            .all(|(offset, word)| cleaned_word(&tokens[index + offset]) == *word);
        if matched {
            return Some(marker.len());
        }
    }
    None
}

fn apply_one_self_correction(text: &str) -> Option<CorrectionPass> {
    let tokens = words(text);
    for index in 0..tokens.len() {
        let Some(marker_length) = retraction_match_at(&tokens, index) else {
            continue;
        };
        let mut comma_index = None;
        for j in (0..index).rev() {
            if tokens[j].ends_with(',') {
                comma_index = Some(j);
                break;
            }
            if ends_sentence_break(&tokens[j]) {
                break;
            }
        }
        let Some(comma_index) = comma_index else {
            return Some(CorrectionPass::Left);
        };
        if comma_index >= index {
            return Some(CorrectionPass::Left);
        }
        let correction: Vec<String> = tokens[index + marker_length..].to_vec();
        if !correction.iter().any(|token| !cleaned_word(token).is_empty()) {
            return Some(CorrectionPass::Left);
        }
        let mut rebuilt: Vec<String> = tokens[..comma_index].to_vec();
        rebuilt.extend(correction);
        return Some(CorrectionPass::Resolved(normalize_whitespace(
            &rebuilt.join(" "),
        )));
    }
    None
}

fn resolve_self_corrections(text: &str) -> (String, i32, i32) {
    let mut working = text.to_string();
    let mut resolved = 0;
    let mut pending = 0;
    while resolved < 5 {
        match apply_one_self_correction(&working) {
            Some(CorrectionPass::Resolved(rebuilt)) => {
                working = rebuilt;
                resolved += 1;
            }
            Some(CorrectionPass::Left) => {
                pending = 1;
                break;
            }
            None => break,
        }
    }
    (working, resolved, pending)
}

const HARD_FILLERS: &[&str] = &[
    "um", "uh", "uhm", "umm", "uhhh", "erm", "er", "hmm", "hmmm", "mmm", "mm", "mhm", "huh",
];
const SOFT_FILLERS: &[&str] = &[
    "basically", "actually", "literally", "kinda", "sorta", "like",
];
const SOFT_PHRASES: &[&[&str]] = &[
    &["you", "know"],
    &["i", "mean"],
    &["sort", "of"],
    &["kind", "of"],
];

fn remove_comma_delimited(
    kept: &mut [String],
    tokens: &mut [String],
    index: usize,
    span: usize,
    own_trailing_comma: bool,
) -> (i32, bool) {
    let mut stripped_prior_comma = false;
    if own_trailing_comma {
        if let Some(last) = kept.last_mut() {
            if last.ends_with(',') {
                last.pop();
                stripped_prior_comma = true;
            }
        }
    }
    if index + span < tokens.len() && tokens[index + span].starts_with(',') {
        tokens[index + span].remove(0);
    }
    (span as i32, stripped_prior_comma)
}

fn remove_fillers(text: &str) -> (String, i32) {
    let mut tokens = words(text);
    let mut kept: Vec<String> = Vec::with_capacity(tokens.len());
    let mut removed = 0;
    let mut after_sentence_break = true;
    let mut comma_before = false;
    let mut index = 0;
    while index < tokens.len() {
        let raw = tokens[index].clone();
        let cleaned = cleaned_word(&raw);
        if cleaned.is_empty() {
            kept.push(raw);
            index += 1;
            continue;
        }
        if index + 1 < tokens.len() {
            let second = cleaned_word(&tokens[index + 1]);
            let phrase = SOFT_PHRASES
                .iter()
                .any(|candidate| candidate[0] == cleaned && candidate[1] == second);
            if phrase && (after_sentence_break || comma_before || raw.starts_with(',')) {
                let own_trailing_comma = tokens[index + 1].ends_with(',');
                let outcome = remove_comma_delimited(
                    &mut kept,
                    &mut tokens,
                    index,
                    2,
                    own_trailing_comma,
                );
                removed += outcome.0;
                if outcome.1 {
                    comma_before = false;
                }
                index += 2;
                continue;
            }
        }
        let remove = HARD_FILLERS.contains(&cleaned.as_str())
            || (SOFT_FILLERS.contains(&cleaned.as_str())
                && (after_sentence_break || comma_before || raw.starts_with(',')));
        if remove {
            let outcome =
                remove_comma_delimited(&mut kept, &mut tokens, index, 1, raw.ends_with(','));
            removed += outcome.0;
            if outcome.1 {
                comma_before = false;
            }
            index += 1;
            continue;
        }
        kept.push(raw.clone());
        if ends_sentence_break(&raw) {
            after_sentence_break = true;
            comma_before = false;
        } else {
            after_sentence_break = false;
            comma_before = raw.ends_with(',');
        }
        index += 1;
    }
    if removed == 0 {
        (text.to_string(), 0)
    } else {
        (normalize_whitespace(&kept.join(" ")), removed)
    }
}

fn simple_number(word: &str) -> Option<i32> {
    Some(match word {
        "zero" => 0,
        "one" => 1,
        "two" => 2,
        "three" => 3,
        "four" => 4,
        "five" => 5,
        "six" => 6,
        "seven" => 7,
        "eight" => 8,
        "nine" => 9,
        "ten" => 10,
        "eleven" => 11,
        "twelve" => 12,
        "thirteen" => 13,
        "fourteen" => 14,
        "fifteen" => 15,
        "sixteen" => 16,
        "seventeen" => 17,
        "eighteen" => 18,
        "nineteen" => 19,
        _ => return None,
    })
}

fn tens_number(word: &str) -> Option<i32> {
    Some(match word {
        "twenty" => 20,
        "thirty" => 30,
        "forty" => 40,
        "fifty" => 50,
        "sixty" => 60,
        "seventy" => 70,
        "eighty" => 80,
        "ninety" => 90,
        _ => return None,
    })
}

fn match_phone_number(tokens: &[String], index: usize) -> Option<(i32, usize)> {
    let first = cleaned_word(&tokens[index]);
    if let Some(tens) = tens_number(&first) {
        if index + 1 < tokens.len() {
            if let Some(ones) = simple_number(&cleaned_word(&tokens[index + 1])) {
                return Some((tens + ones, 2));
            }
        }
    }
    simple_number(&first)
        .or_else(|| tens_number(&first))
        .map(|value| (value, 1))
}

fn is_number_unit(token: &str, value: i32) -> bool {
    let unit = cleaned_word(token);
    unit == "percent" || ((unit == "am" || unit == "pm") && (1..=12).contains(&value))
}

fn normalize_numbers(text: &str) -> String {
    let tokens = words(text);
    let mut rebuilt: Vec<String> = Vec::with_capacity(tokens.len());
    let mut index = 0;
    while index < tokens.len() {
        if let Some((value, consumed)) = match_phone_number(&tokens, index) {
            let after = index + consumed;
            if after < tokens.len() && is_number_unit(&tokens[after], value) {
                let unit = cleaned_word(&tokens[after]);
                if unit == "percent" {
                    rebuilt.push(format!("{value}%"));
                } else {
                    rebuilt.push(format!("{value}{unit}"));
                }
                index = after + 1;
                continue;
            }
        }
        rebuilt.push(tokens[index].clone());
        index += 1;
    }
    rebuilt.join(" ")
}

const PROPER_NOUNS: &[(&str, &str)] = &[
    ("chrome", "Chrome"),
    ("safari", "Safari"),
    ("firefox", "Firefox"),
    ("spotify", "Spotify"),
    ("whatsapp", "WhatsApp"),
    ("telegram", "Telegram"),
    ("slack", "Slack"),
    ("notes", "Notes"),
    ("xcode", "Xcode"),
    ("photoshop", "Photoshop"),
    ("figma", "Figma"),
    ("notion", "Notion"),
    ("terminal", "Terminal"),
    ("finder", "Finder"),
    ("google", "Google"),
    ("apple", "Apple"),
    ("iphone", "iPhone"),
    ("ipad", "iPad"),
    ("bluetooth", "Bluetooth"),
    ("python", "Python"),
    ("rust", "Rust"),
    ("docker", "Docker"),
    ("linux", "Linux"),
    ("openai", "OpenAI"),
    ("anthropic", "Anthropic"),
    ("claude", "Claude"),
    ("zoom", "Zoom"),
    ("github", "GitHub"),
    ("youtube", "YouTube"),
    ("macos", "macOS"),
    ("wifi", "Wi-Fi"),
    ("swift", "Swift"),
    ("monday", "Monday"),
    ("tuesday", "Tuesday"),
    ("wednesday", "Wednesday"),
    ("thursday", "Thursday"),
    ("friday", "Friday"),
    ("saturday", "Saturday"),
    ("sunday", "Sunday"),
    ("january", "January"),
    ("february", "February"),
    ("march", "March"),
    ("april", "April"),
    ("may", "May"),
    ("june", "June"),
    ("july", "July"),
    ("august", "August"),
    ("september", "September"),
    ("october", "October"),
    ("november", "November"),
    ("december", "December"),
    ("i", "I"),
    ("i'm", "I'm"),
    ("i've", "I've"),
    ("i'll", "I'll"),
    ("i'd", "I'd"),
];

fn capitalize(text: &str) -> String {
    let mut out = text.to_string();
    for (spoken, canonical) in PROPER_NOUNS {
        if spoken.len() <= 1 && *spoken != "i" {
            continue;
        }
        let pattern = format!(r"(?i)\b{}\b", escape(spoken));
        out = replace(&pattern, &out, canonical);
    }
    let mut rebuilt = String::with_capacity(out.len());
    let mut capitalize_next = true;
    for character in out.chars() {
        if capitalize_next && character.is_alphabetic() {
            rebuilt.extend(character.to_uppercase());
            capitalize_next = false;
            continue;
        }
        rebuilt.push(character);
        if character.is_alphanumeric() {
            capitalize_next = false;
        } else if ".!?".contains(character) || character == '\n' {
            capitalize_next = true;
        }
    }
    rebuilt
}

fn ensure_terminal_punctuation(text: &str) -> String {
    let Some(last) = text.chars().last() else {
        return text.to_string();
    };
    if let Some(final_line) = text.split('\n').last() {
        let line = final_line.trim_matches(is_space);
        let numbered = line
            .split_once(". ")
            .is_some_and(|(head, _)| !head.is_empty() && head.chars().all(|c| c.is_ascii_digit()));
        if line.starts_with("- ") || numbered {
            return text.to_string();
        }
    }
    match last {
        '.' | '?' | '!' | '…' => text.to_string(),
        ',' | ';' | ':' => {
            let mut out = text.to_string();
            out.pop();
            out.push('.');
            out
        }
        '"' | '\'' | ')' | '”' | '’' => format!("{text}."),
        _ => format!("{text}."),
    }
}

fn contains_enumeration(text: &str) -> bool {
    let pattern =
        r"(?i)\b(first(?:ly)?|second(?:ly)?|third(?:ly)?|numbered|bullet(?: point)?s?|list|finally|lastly)\b";
    rx(pattern).find_iter(text).count() >= 2
}

#[uniffi::export]
pub fn format_transcript(raw: String) -> FormattedTranscript {
    let input_words = word_count(&raw);
    let mut text = normalize_whitespace(&raw);
    text = collapse_repeated_phrases(text, 10, 3);
    let (next, duplicates) = collapse_duplicate_runs(&text);
    text = next;
    let (next, resolved, pending) = resolve_self_corrections(&text);
    text = next;
    let (next, fillers) = remove_fillers(&text);
    text = next;
    text = normalize_numbers(&text);
    text = capitalize(&text);
    text = ensure_terminal_punctuation(&text);
    let has_enumeration = contains_enumeration(&text);
    let output_words = word_count(&text);
    FormattedTranscript {
        text,
        filler_removals: fillers + duplicates,
        correction_resolves: resolved,
        unbounded_corrections: pending,
        has_enumeration,
        input_words,
        output_words,
    }
}

#[uniffi::export]
pub fn transcript_should_use_llm(
    has_enumeration: bool,
    unbounded_corrections: i32,
    output_words: i32,
    filler_removals: i32,
    correction_resolves: i32,
    has_directive: bool,
) -> bool {
    has_directive
        || has_enumeration
        || unbounded_corrections > 0
        || output_words > 25
        || (filler_removals >= 2 && correction_resolves > 0)
}

#[uniffi::export]
pub fn transcript_list_directive(raw: String) -> Option<String> {
    let lower = raw.to_lowercase();
    if lower.contains("bullet") {
        return Some("bullets".into());
    }
    if lower.contains("numbered list") || lower.contains("number the list") {
        return Some("numbered".into());
    }
    if lower.contains("paragraph") {
        return None;
    }
    let markers = [
        "first", "firstly", "second", "secondly", "third", "thirdly", "finally", "lastly",
    ];
    let distinct = markers
        .iter()
        .filter(|marker| has(&format!(r"\b{}\b", escape(marker)), &lower))
        .count();
    if distinct >= 2 {
        return Some("numbered".into());
    }
    if (lower.contains("point one") && lower.contains("point two"))
        || (lower.contains("point 1") && lower.contains("point 2"))
    {
        return Some("numbered".into());
    }
    None
}

#[uniffi::export]
pub fn recapitalize(text: String) -> String {
    ensure_terminal_punctuation(&capitalize(&text))
}

#[uniffi::export]
pub fn allowed_drift(text: String, unbounded_corrections: i32, directive: Option<String>) -> f64 {
    if unbounded_corrections > 0 || directive.is_some() {
        return 0.35;
    }
    let lower = text.to_lowercase();
    let cues = [
        "comma",
        "period",
        "full stop",
        "question mark",
        "colon",
        "semicolon",
        "exclamation point",
        "no wait",
        "wait no",
        "sorry",
        "scratch that",
        "or rather",
    ];
    if cues.iter().any(|cue| lower.contains(cue)) {
        0.35
    } else {
        0.18
    }
}

fn last_cleaned_block(text: &str) -> Option<String> {
    let pattern = r"(?s)<cleaned>(.*?)</cleaned>";
    let mut latest = None;
    for captures in rx(pattern).captures_iter(text).flatten() {
        if let Some(body) = captures.get(1) {
            latest = Some(body.as_str().to_string());
        }
    }
    latest
}

fn strip_malformed_closer(mut body: String) -> String {
    let patterns = [
        r"(?m)\s*</?\s*cleaned\s*/?>\s*$",
        r"(?m)\s*<\s*/\s*>\s*$",
        r"(?m)\s*/\s*>\s*$",
        r"(?m)\s*<\s*$",
    ];
    for pattern in patterns {
        if rx(pattern).is_match(&body).unwrap_or(false) {
            body = replace(pattern, &body, "");
            break;
        }
    }
    body
}

#[uniffi::export]
pub fn sanitize_polished(raw: String, reference: String, max_drift: f64) -> SanitizeResult {
    let mut text = trimmed(&raw).to_string();
    let mut reasons: Vec<String> = Vec::new();
    if text.is_empty() {
        return SanitizeResult {
            text: None,
            reasons: vec!["empty".into()],
        };
    }
    if let Some(body) = last_cleaned_block(&text) {
        text = trimmed(&body).to_string();
    } else if let Some(open) = text.find("<cleaned>") {
        let body = text[open + "<cleaned>".len()..].to_string();
        text = strip_malformed_closer(trimmed(&body).to_string());
        reasons.push("cleaned-malformed".into());
    }
    text = trimmed(&text).to_string();
    if text.is_empty() {
        return SanitizeResult {
            text: None,
            reasons: vec!["empty".into()],
        };
    }

    let before_turn = text.clone();
    if let Some(found) = rx(r"(?i)^A:\s*").find(&text).ok().flatten() {
        text = text[found.end()..].to_string();
    }
    if let Some(found) = rx(r"(?i)^List:\s*(numbered|bullets)\s*\n")
        .find(&text)
        .ok()
        .flatten()
    {
        text = text[found.end()..].to_string();
    }
    if let Some(found) = rx(r"(?i)\nU:\s").find(&text).ok().flatten() {
        text.truncate(found.start());
    }
    text = trimmed(&text).to_string();
    if text != before_turn {
        reasons.push("turn-stripped".into());
    }
    if text.is_empty() {
        return SanitizeResult {
            text: None,
            reasons: vec!["empty".into()],
        };
    }

    let think = r"(?s)<think>.*?(?:</think>|$)";
    if has(think, &text) {
        text = replace(think, &text, "");
        text = trimmed(&text).to_string();
        if text.is_empty() {
            return SanitizeResult {
                text: None,
                reasons: vec!["think-only".into()],
            };
        }
        reasons.push("think-stripped".into());
    }

    if text.starts_with("```") {
        let open = replace(r"(?m)^```\w*\s*", &text, "");
        let stripped = replace(r"(?m)\s*```\s*$", &open, "");
        text = trimmed(&stripped).to_string();
        if text.is_empty() {
            return SanitizeResult {
                text: None,
                reasons: vec!["fence-only".into()],
            };
        }
        reasons.push("fence-stripped".into());
    }

    if let (Some(first), Some(last)) = (text.chars().next(), text.chars().last()) {
        let quote = "\"'“‘".contains(first);
        if quote && first == last && len(&text) > 4 {
            let inner: String = text.chars().skip(1).take(text.chars().count() - 2).collect();
            if !inner.contains(first) {
                text = trimmed(&inner).to_string();
                reasons.push("quote-unwrap".into());
            }
        }
    }

    let prefixes = [
        "i'm sorry",
        "i am sorry",
        "sorry,",
        "here is",
        "here's",
        "as an ai",
        "sure,",
        "certainly",
        "cleaned text",
        "cleaned:",
        "note:",
        "ollama",
    ];
    let lowered = text.to_lowercase();
    if let Some(prefix) = prefixes.iter().find(|prefix| lowered.starts_with(**prefix)) {
        reasons.push(format!("meta:{prefix}"));
        return SanitizeResult {
            text: None,
            reasons,
        };
    }

    if repeated_phrase_loop(text.clone()) {
        reasons.push("repetition-loop".into());
        return SanitizeResult {
            text: None,
            reasons,
        };
    }

    let reference_length = len(&reference).max(1);
    let actual = len(&text);
    let drift = actual.abs_diff(reference_length) as f64 / reference_length as f64;
    if drift > max_drift {
        reasons.push(format!("length-drift {drift:.2}"));
        return SanitizeResult {
            text: None,
            reasons,
        };
    }

    SanitizeResult {
        text: if text.is_empty() { None } else { Some(text) },
        reasons,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn polish_cannot_rewrite_or_invent_content() {
        let reference = "I hope you can read the last handoff document provided. It gives an overview of the changes and what is fixed or needs work.";
        let rewritten = "I hope you can read the latest handoff document provided. It will give you a full overview of the changes. I'm eager for your feedback and assistance in correcting any issues found.";
        assert!(!polish_preserves_content(reference.into(), rewritten.into(), None));
        assert!(!polish_preserves_content("Do not delete my files".into(), "Do delete my files.".into(), None));
        assert!(!polish_preserves_content("Meet at five".into(), "Meet at nine.".into(), None));
        assert!(!polish_preserves_content("open brave then chrome".into(), "Open Chrome, then Brave.".into(), None));
    }

    #[test]
    fn polish_can_format_words_without_changing_them() {
        assert!(polish_preserves_content("hello john how are you".into(), "Hello John, how are you?".into(), None));
        assert!(polish_preserves_content("hi john comma call me period".into(), "Hi John, call me.".into(), None));
        assert!(polish_preserves_content("things to buy first milk second eggs third bread".into(), "Things to buy:\n1. Milk\n2. Eggs\n3. Bread".into(), Some("numbered".into())));
        assert!(!polish_preserves_content("things to buy first milk second eggs".into(), "Things to buy:\n1. Milk\n2. Eggs\n3. Bread".into(), Some("numbered".into())));
        assert!(polish_preserves_content("cafe\u{301}".into(), "Café.".into(), None));
    }

    fn formatted(raw: &str) -> String {
        format_transcript(raw.to_string()).text
    }

    #[test]
    fn duplicate_words_and_sentence_boundaries() {
        assert_eq!(formatted("the the dog barks"), "The dog barks.");
        assert_eq!(formatted("do it. do it again"), "Do it. Do it again.");
    }

    #[test]
    fn fillers_keep_verbs() {
        assert_eq!(formatted("I like it"), "I like it.");
        assert_eq!(formatted("um so we should uh go then"), "So we should go then.");
        assert_eq!(formatted("so, like, go now"), "So go now.");
        assert_eq!(
            formatted("the plan was, you know, ambitious, basically unworkable"),
            "The plan was ambitious, unworkable."
        );
        assert_eq!(formatted("wait, it is like this"), "Wait, it is like this.");
    }

    #[test]
    fn self_corrections_match_swift() {
        let out = format_transcript("push the release tuesday, no wait wednesday".into());
        assert_eq!(out.text, "Push the release Wednesday.");
        assert_eq!(out.correction_resolves, 1);
        let out = format_transcript("meet tuesday no wait wednesday".into());
        assert_eq!(out.text, "Meet Tuesday no wait Wednesday.");
        assert_eq!(out.unbounded_corrections, 1);
        assert!(transcript_should_use_llm(
            out.has_enumeration,
            out.unbounded_corrections,
            out.output_words,
            out.filler_removals,
            out.correction_resolves,
            false
        ));
        assert_eq!(
            formatted("lovely weather. buy apples, or rather pears"),
            "Lovely weather. Buy pears."
        );
        assert_eq!(
            formatted("meet tuesday, scratch that"),
            "Meet Tuesday, scratch that."
        );
        assert_eq!(
            formatted("use the blue one, i mean, the dark one"),
            "Use the blue one the dark one."
        );
    }

    #[test]
    fn numbers_only_with_units() {
        assert_eq!(formatted("raise the limit twenty five percent"), "Raise the limit 25%.");
        assert_eq!(formatted("call me three pm"), "Call me 3pm.");
        assert_eq!(
            formatted("we printed five thousand pages"),
            "We printed five thousand pages."
        );
    }

    #[test]
    fn capitalization_and_punctuation() {
        assert_eq!(formatted("what am i doing here"), "What am I doing here.");
        assert_eq!(
            formatted("please open chrome and spotify"),
            "Please open Chrome and Spotify."
        );
        assert_eq!(formatted("open the window,"), "Open the window.");
        assert_eq!(
            formatted("um so, basically, we should, you know, move the the standup to ten am"),
            "So we should move the standup to 10am."
        );
    }

    #[test]
    fn readme_cases() {
        assert_eq!(
            formatted("i, actually, like the slower version and the new theme is twenty five percent faster"),
            "I like the slower version and the new theme is 25% faster."
        );
        assert_eq!(
            formatted("also meet thursday no wait friday to review it"),
            "Also meet Thursday no wait Friday to review it."
        );
        assert_eq!(formatted("um open chrome please"), "Open Chrome please.");
        assert_eq!(formatted("the the dog"), "The dog.");
    }

    #[test]
    fn list_directive_rules() {
        assert_eq!(
            transcript_list_directive("things to buy first milk second eggs".into()).as_deref(),
            Some("numbered")
        );
        assert_eq!(
            transcript_list_directive("give this to me as bullet points milk eggs".into()).as_deref(),
            Some("bullets")
        );
        assert_eq!(
            transcript_list_directive("first paragraph one second paragraph two".into()),
            None
        );
        assert_eq!(
            transcript_list_directive("i need milk eggs and bread".into()),
            None
        );
    }

    #[test]
    fn polish_sanitizer_guards() {
        let reference = "We should push the release to Wednesday.";
        let ok = sanitize_polished(reference.into(), reference.into(), 0.35);
        assert_eq!(ok.text.as_deref(), Some(reference));
        let meta = sanitize_polished(
            "Here is the cleaned text: We should push the release to Wednesday.".into(),
            reference.into(),
            0.35,
        );
        assert!(meta.text.is_none());
        assert!(meta.reasons.iter().any(|reason| reason.starts_with("meta:")));
        let drift = sanitize_polished("Push Wednesday.".into(), reference.into(), 0.35);
        assert!(drift.text.is_none());
        assert!(drift
            .reasons
            .iter()
            .any(|reason| reason.starts_with("length-drift")));
        let fence = sanitize_polished(
            "```text\nWe should push the release to Wednesday.\n```".into(),
            reference.into(),
            0.35,
        );
        assert_eq!(fence.text.as_deref(), Some(reference));
        assert!(fence.reasons.contains(&"fence-stripped".to_string()));
    }

    #[test]
    fn think_tags_are_stripped() {
        let open = String::from_utf8(vec![0x3C, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E]).unwrap();
        let close = String::from_utf8(vec![0x3C, 0x2F, 0x74, 0x68, 0x69, 0x6E, 0x6B, 0x3E]).unwrap();
        let reference = "We should push the release to Wednesday.";
        let text = format!("{open}step by step{close}\n{reference}");
        let out = sanitize_polished(text, reference.into(), 0.35);
        assert_eq!(out.text.as_deref(), Some(reference));
        assert!(out.reasons.contains(&"think-stripped".to_string()));
        let only = format!("{open}the user said something{close}");
        let out = sanitize_polished(only, reference.into(), 0.35);
        assert_eq!(out.text, None);
        assert_eq!(out.reasons, vec!["think-only".to_string()]);
    }

    #[test]
    fn drift_allowance() {
        assert_eq!(
            allowed_drift("we met the team and shipped the build".into(), 0, None),
            0.18
        );
        assert_eq!(
            allowed_drift("first milk second eggs".into(), 0, Some("numbered".into())),
            0.35
        );
        assert_eq!(
            allowed_drift("meet tuesday no wait".into(), 1, None),
            0.35
        );
        assert_eq!(
            allowed_drift("hi john comma thanks period".into(), 0, None),
            0.35
        );
    }
}
