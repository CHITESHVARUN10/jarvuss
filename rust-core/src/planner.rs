//! Port of Swift `ActionPlanner` — rule-based intent parser.
//!
//! Priority router (identical to Swift):
//! SYSTEM -> INFO -> DISPLAY -> VOLUME -> MEDIA -> SEARCH -> CONJUNCTION -> SINGLE.
//!
//! NOTE on the Ollama fallback: the Swift pipeline performs the HTTP call to
//! `127.0.0.1:11434` and JSON-parses the plan. This port returns
//! `AiQuery { query }` for genuinely-unknown input (and `[]` for dropped
//! system-like misfires), so Swift keeps its existing `ollamaFallback` until
//! the `reqwest` async client lands in Phase 1.1.

use crate::actions::{DisplayAction, MediaAction, PlannedAction, SystemInfoAction, VolumeAction};
use crate::alias;
use crate::safety;
use regex::Regex;
use std::sync::OnceLock;

// ── Public entry point ──────────────────────────────────────────────

/// Outcome of the post-model planning flow (fast path → rules → guards).
pub enum PlanStep {
    /// A branch decided the result. Branch names mirror the Swift
    /// `logPlanEvent` vocabulary: "local", "blocked", "install",
    /// "fastpath", "rule", "drop", "ai".
    Actions(&'static str, Vec<PlannedAction>),
    /// Nothing local decides it — the caller runs the Ollama fallback.
    NeedsOllama(String),
}

/// Plan a raw (possibly wake-word-prefixed) command string.
pub fn plan(raw: &str) -> Vec<PlannedAction> {
    let cleaned = strip_wake_word(&strip_trailing_noise(raw));
    let lower = cleaned.to_lowercase();

    if cleaned.trim().is_empty() {
        return vec![];
    }

    // 1b. Local state reads — hardware questions are answered locally, never AI.
    if let Some(local) = answer_local_state_query(&cleaned, &lower) {
        return local;
    }

    // Safety pre-check on the full input.
    match safety::validate_raw(&cleaned) {
        safety::SafetyVerdict::Blocked { reason } => {
            return vec![PlannedAction::AiQuery {
                query: format!("blocked: {reason}"),
            }]
        }
        safety::SafetyVerdict::InstallPreview { command, source } => {
            return vec![PlannedAction::InstallPreview {
                package: command,
                source,
            }]
        }
        safety::SafetyVerdict::Allowed => {}
    }

    match plan_after_safety(&cleaned, &lower) {
        PlanStep::Actions(_, actions) => actions,
        // Phase 1.1 (reqwest) will perform the Ollama call in Rust; until then
        // the caller owns the HTTP fallback, so surface the query as-is.
        PlanStep::NeedsOllama(query) => vec![PlannedAction::AiQuery { query }],
    }
}

/// The post-model flow, shared by [`plan`] and the Swift cut-over API.
/// Mirrors Swift `ActionPlanner.plan` from step 2b onward:
/// fast-path router → strict priority rules → misfire drop → short-AI → Ollama.
pub fn plan_after_safety(cleaned: &str, lower: &str) -> PlanStep {
    // 2b. Fast-path router — simple intents with zero model involvement.
    // (Swift runs the learned intent model before this gate; parity target is
    // `FastPathRouter.route` in ActionPlanner.swift.)
    if let Some(actions) = fast_path_route(cleaned) {
        let branch = if actions.is_empty() { "drop" } else { "fastpath" };
        return PlanStep::Actions(branch, actions);
    }

    if let Some(actions) = rule_based_plan(cleaned, lower) {
        return PlanStep::Actions("rule", actions);
    }

    // Unmatched system-looking commands used to be DROPPED here, which is what
    // produced a silent "Invalid command skipped" for compound speech the rules
    // could not parse. They now escalate to Ollama like any other unknown
    // input; the caller's fallback degrades to a spoken AiQuery answer, so the
    // chain can never terminate in silence (Swift parity).
    let tokens: Vec<&str> = lower.split_whitespace().collect();
    // Short unknown input → direct AI query without an Ollama planning call.
    if tokens.len() < 4 {
        return PlanStep::Actions(
            "ai",
            vec![PlannedAction::AiQuery {
                query: cleaned.to_string(),
            }],
        );
    }
    // Complex/unrecognised → Ollama fallback.
    PlanStep::NeedsOllama(cleaned.to_string())
}

// ── Local state reads ───────────────────────────────────────────────

/// "what is the current brightness/contrast level" — answered from hardware,
/// never sent to AI (port of Swift `answerLocalStateQuery`).
pub fn answer_local_state_query(_cleaned: &str, lower: &str) -> Option<Vec<PlannedAction>> {
    let any = |terms: &[&str]| terms.iter().any(|t| lower.contains(t));
    let is_question = any(&["what", "current", "show", "tell"]);

    if is_question
        && any(&["brightness level", "brightness", "screen brightness"])
        && !any(&["set", "increase", "decrease", "dimmer", "brighter"])
    {
        return Some(vec![PlannedAction::SystemInfo {
            info: SystemInfoAction::DisplayBrightness,
        }]);
    }
    if is_question
        && any(&["contrast level", "contrast"])
        && !any(&["set", "increase", "decrease"])
    {
        return Some(vec![PlannedAction::SystemInfo {
            info: SystemInfoAction::DisplayContrast,
        }]);
    }
    None
}

// ── Fast-path router (no-model gate) ────────────────────────────────

/// Port of Swift `FastPathRouter.route`. `None` == `.needsModel`.
fn fast_path_route(cleaned: &str) -> Option<Vec<PlannedAction>> {
    let lower = cleaned.trim().to_lowercase();
    if lower.is_empty() {
        return Some(vec![]);
    }

    if let Some(shortcut) = single_app_shortcut(&lower) {
        return Some(vec![PlannedAction::OpenApp {
            name: alias::resolve(shortcut),
        }]);
    }

    if !lower.contains(" and ") && !lower.contains(" then ") {
        if let Some(action) = fast_single_app_command(&lower) {
            return Some(vec![action]);
        }
    }

    if let Some(url) = fast_known_website(&lower) {
        return Some(vec![PlannedAction::OpenUrl {
            url: url.to_string(),
        }]);
    }

    if let Some(search) = fast_single_search(&lower) {
        return Some(vec![search]);
    }

    if is_quick_info(&lower) {
        return Some(vec![PlannedAction::AiQuery {
            query: cleaned.to_string(),
        }]);
    }

    if let Some(vol) = fast_single_volume(&lower) {
        return Some(vec![vol]);
    }
    if let Some(media) = fast_single_media(&lower) {
        return Some(vec![media]);
    }
    if let Some(display) = fast_single_display(&lower) {
        return Some(vec![display]);
    }

    if is_ai_question(&lower) {
        return Some(vec![PlannedAction::AiQuery {
            query: cleaned.to_string(),
        }]);
    }

    // Short single-intent utterances (≤3 words) that match no rule and carry
    // no system keyword are noise, not questions — drop locally.
    let words: Vec<&str> = lower.split(' ').collect();
    if words.len() <= 3 && !contains_system_keyword(&words) {
        return Some(vec![]);
    }

    None
}

fn fast_single_app_command(lower: &str) -> Option<PlannedAction> {
    const VERBS: &[(&str, bool)] = &[
        ("open ", false),
        ("launch ", false),
        ("start ", false),
        ("run ", false),
        ("close ", true),
        ("quit ", true),
    ];
    for (prefix, close) in VERBS {
        if let Some(rest) = lower.strip_prefix(prefix) {
            let target = rest.trim();
            if target.is_empty() || target.split(' ').count() > 4 {
                return None;
            }
            if let Some(url) = known_website_url(target) {
                return Some(PlannedAction::OpenUrl {
                    url: url.to_string(),
                });
            }
            let resolved = alias::resolve(target);
            return Some(if *close {
                PlannedAction::CloseApp { name: resolved }
            } else {
                PlannedAction::OpenApp { name: resolved }
            });
        }
    }
    None
}

fn fast_known_website(lower: &str) -> Option<&'static str> {
    const SITES: &[(&str, &str)] = &[
        ("youtube", "https://www.youtube.com"),
        ("google", "https://www.google.com"),
        ("netflix", "https://www.netflix.com"),
        ("github", "https://github.com"),
    ];
    for (name, url) in SITES {
        if lower == *name || lower == format!("open {name}") {
            return Some(url);
        }
    }
    None
}

fn fast_single_search(lower: &str) -> Option<PlannedAction> {
    const PATTERNS: &[(&str, &str)] = &[
        (r"search (?:on )?youtube for (.+)", "YouTube"),
        (r"youtube search for (.+)", "YouTube"),
        (r"search google for (.+)", "Google"),
        (r"search (?:on the )?internet for (.+)", "Google"),
        (r"search for (.+)", "Google"),
        (r"search (.+?) on youtube", "YouTube"),
        (r"search (.+?) in youtube", "YouTube"),
        (r"search (.+?) on google", "Google"),
        (r"search (.+?) in google", "Google"),
        (r"search (.+?) in brave", "Google"),
        (r"search (.+?) on brave", "Google"),
    ];
    for (pattern, engine) in PATTERNS {
        let re = search_re(pattern);
        if let Some(caps) = re.captures(lower) {
            let query = caps
                .get(1)
                .map(|m| trim_search_query(m.as_str()))
                .unwrap_or_default();
            if query.is_empty() {
                continue;
            }
            return Some(PlannedAction::SearchWeb {
                engine: engine.to_string(),
                query,
            });
        }
    }
    None
}

fn trim_search_query(raw: &str) -> String {
    raw.trim()
        .trim_matches(|c: char| c == '?' || c == '.' || c == '!')
        .trim()
        .to_string()
}

fn is_quick_info(lower: &str) -> bool {
    const TERMS: &[&str] = &[
        "what time",
        "current time",
        "time right now",
        "what day",
        "what date",
        "today's date",
        "todays date",
        "current date",
        "what month",
        "what year",
        "system volume",
        "current volume",
        "wifi",
        "bluetooth",
        "battery",
    ];
    TERMS.iter().any(|t| lower.contains(t))
}

fn fast_single_volume(lower: &str) -> Option<PlannedAction> {
    if matches!(lower, "mute" | "mute the sound" | "sound off") {
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Mute,
        });
    }
    if matches!(lower, "unmute" | "sound on") {
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Unmute,
        });
    }
    if lower.contains("volume up") || lower.contains("sound up") || lower == "louder" {
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Increase { by: 10 },
        });
    }
    if lower.contains("volume down") || lower.contains("sound down") || lower == "quieter" {
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Decrease { by: 10 },
        });
    }
    None
}

fn fast_single_media(lower: &str) -> Option<PlannedAction> {
    let action = if matches!(lower, "pause" | "stop") {
        MediaAction::Pause
    } else if matches!(lower, "play" | "resume") {
        MediaAction::Play
    } else if matches!(lower, "next" | "next song" | "next track" | "skip") {
        MediaAction::NextTrack
    } else if matches!(lower, "previous" | "previous song" | "prev") {
        MediaAction::PreviousTrack
    } else if lower.contains("liked songs") || (lower.contains("liked") && lower.contains("songs")) {
        MediaAction::PlayLikedSongs
    } else {
        return None;
    };
    Some(PlannedAction::MediaControl { action })
}

fn fast_single_display(lower: &str) -> Option<PlannedAction> {
    if lower.contains("brighter") || lower.contains("brightness up") {
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::IncreaseBrightness { by: 10 },
        });
    }
    if lower.contains("dimmer") || lower.contains("brightness down") {
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::DecreaseBrightness { by: 10 },
        });
    }
    None
}

fn is_ai_question(lower: &str) -> bool {
    ["explain ", "what is ", "who is ", "why ", "how ", "tell me ", "describe "]
        .iter()
        .any(|p| lower.starts_with(p))
}

fn contains_system_keyword(words: &[&str]) -> bool {
    const KEYWORDS: &[&str] = &[
        "open", "close", "launch", "start", "run", "quit", "volume", "mute", "unmute", "play",
        "pause", "next", "previous", "skip", "search", "create", "brightness", "contrast",
    ];
    words.iter().any(|w| KEYWORDS.contains(w))
}

// ── Rule-based planner ──────────────────────────────────────────────

fn rule_based_plan(cleaned: &str, lower: &str) -> Option<Vec<PlannedAction>> {
    // Compound commands FIRST — a multi-clause utterance must never be parsed
    // as one giant target ("open notes and increase the volume by 20 percent"
    // used to become OpenApp{name: "notes and increase the volume by 20
    // percent"}). Mirrors Swift `ActionPlanner.ruleBasedPlan`.
    let conjuncts = split_by_conjunction(lower);
    if conjuncts.len() > 1 {
        let mut actions: Vec<PlannedAction> = vec![];
        for part in &conjuncts {
            let part = part.trim().to_string();
            if part.is_empty() {
                continue;
            }
            if let Some(vol) = parse_volume_command(&part) {
                actions.push(vol);
                continue;
            }
            if let Some(info) = parse_info_command(&part) {
                actions.push(PlannedAction::SystemInfo { info });
                continue;
            }
            if let Some(media) = parse_media_command(&part) {
                actions.push(media);
                continue;
            }
            if let Some(display) = parse_display_command(&part) {
                actions.push(display);
                continue;
            }
            if let Some(search) = parse_search_query(&part) {
                actions.extend(search);
                continue;
            }
            if let Some(rest) = part.strip_prefix("close ") {
                actions.push(PlannedAction::CloseApp {
                    name: alias::resolve(rest),
                });
                continue;
            }
            actions.extend(parse_single_phrase(&part, cleaned));
        }
        if let Some(control) = preferred_single_control_action(&actions) {
            return Some(vec![control]);
        }
        return if actions.is_empty() {
            None
        } else {
            Some(actions)
        };
    }

    if let Some(system) = parse_system_command(lower) {
        return Some(vec![system]);
    }
    if let Some(info) = parse_info_command(lower) {
        return Some(vec![PlannedAction::SystemInfo { info }]);
    }
    if let Some(display) = parse_display_command(lower) {
        return Some(vec![display]);
    }
    if let Some(volume) = parse_volume_command(lower) {
        return Some(vec![volume]);
    }
    if let Some(media) = parse_media_command(lower) {
        return Some(vec![media]);
    }
    if let Some(search) = parse_search_query(lower) {
        return Some(search);
    }

    let single = parse_single_phrase(lower, cleaned);
    if single.is_empty() {
        None
    } else {
        Some(single)
    }
}

// ── System commands ─────────────────────────────────────────────────

fn single_app_shortcut(lower: &str) -> Option<&'static str> {
    match lower {
        "chrome" => Some("chrome"),
        "spotify" => Some("spotify"),
        "whatsapp" => Some("whatsapp"),
        _ => None,
    }
}

fn known_website_url(target: &str) -> Option<&'static str> {
    match target.trim() {
        "youtube" | "you tube" => Some("https://www.youtube.com"),
        "google" => Some("https://www.google.com"),
        "netflix" => Some("https://www.netflix.com"),
        "github" | "git hub" => Some("https://github.com"),
        "twitter" | "x" | "twitter x" => Some("https://twitter.com"),
        "reddit" => Some("https://www.reddit.com"),
        "instagram" => Some("https://www.instagram.com"),
        "linkedin" => Some("https://www.linkedin.com"),
        "gmail" => Some("https://mail.google.com"),
        "maps" | "google maps" => Some("https://maps.google.com"),
        _ => None,
    }
}

fn parse_system_command(lower: &str) -> Option<PlannedAction> {
    let trimmed = lower.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(app) = single_app_shortcut(trimmed) {
        return Some(PlannedAction::OpenApp {
            name: alias::resolve(app),
        });
    }
    for prefix in ["open ", "launch "] {
        if let Some(target) = trimmed.strip_prefix(prefix) {
            let target = target.trim();
            if !target.is_empty() {
                if let Some(url) = known_website_url(target) {
                    return Some(PlannedAction::OpenUrl {
                        url: url.to_string(),
                    });
                }
                return Some(PlannedAction::OpenApp {
                    name: alias::resolve(target),
                });
            }
        }
    }
    for prefix in ["close ", "quit "] {
        if let Some(target) = trimmed.strip_prefix(prefix) {
            let target = target.trim();
            if !target.is_empty() {
                return Some(PlannedAction::CloseApp {
                    name: alias::resolve(target),
                });
            }
        }
    }
    None
}

// ── Info commands ───────────────────────────────────────────────────

fn parse_info_command(lower: &str) -> Option<SystemInfoAction> {
    let trimmed = lower.trim();
    if trimmed.is_empty() {
        return None;
    }
    if matches!(trimmed, "what time is it" | "current time" | "time now") {
        return Some(SystemInfoAction::CurrentTime);
    }
    if matches!(
        trimmed,
        "what is today's date"
            | "what is todays date"
            | "today's date"
            | "todays date"
            | "current date"
    ) {
        return Some(SystemInfoAction::CurrentDate);
    }
    if trimmed.contains("wifi") {
        return Some(SystemInfoAction::WifiStatus);
    }
    if trimmed.contains("bluetooth") {
        return Some(SystemInfoAction::BluetoothDevices);
    }
    if trimmed.contains("battery") {
        return Some(SystemInfoAction::BatteryStatus);
    }
    if matches!(
        trimmed,
        "system volume" | "current volume" | "volume level"
    ) {
        return Some(SystemInfoAction::SystemVolume);
    }
    None
}

// ── Display commands ────────────────────────────────────────────────

fn parse_display_command(lower: &str) -> Option<PlannedAction> {
    // Brightness set.
    for pattern in [
        "set brightness to ",
        "brightness to ",
        "set the brightness to ",
        "set screen brightness to ",
        "screen brightness to ",
    ] {
        if let Some(_rest) = lower.strip_prefix(pattern) {
            if let Some(pct) = extract_volume_amount(lower) {
                return Some(PlannedAction::DisplayControl {
                    action: DisplayAction::SetBrightness { percent: pct },
                });
            }
        }
    }
    if lower.starts_with("set brightness ") || lower.starts_with("brightness ") {
        if let Some(pct) = extract_volume_amount(lower) {
            if (0..=100).contains(&pct) {
                return Some(PlannedAction::DisplayControl {
                    action: DisplayAction::SetBrightness { percent: pct },
                });
            }
        }
    }
    // Brightness increase.
    const BRIGHT_UP: &[&str] = &[
        "increase brightness",
        "increase the brightness",
        "brightness up",
        "brighter",
        "make it brighter",
        "make the screen brighter",
        "turn up brightness",
        "turn up the brightness",
        "raise brightness",
        "raise the brightness",
        "dim up",
        "screen brighter",
    ];
    if BRIGHT_UP.iter().any(|p| lower.contains(p)) {
        let amount = extract_volume_amount(lower).unwrap_or(10);
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::IncreaseBrightness { by: amount },
        });
    }
    // Brightness decrease.
    const BRIGHT_DOWN: &[&str] = &[
        "decrease brightness",
        "decrease the brightness",
        "brightness down",
        "dimmer",
        "dim the screen",
        "make it dimmer",
        "make the screen dimmer",
        "turn down brightness",
        "turn down the brightness",
        "lower brightness",
        "lower the brightness",
        "reduce brightness",
        "reduce the brightness",
        "darker",
        "screen darker",
    ];
    if BRIGHT_DOWN.iter().any(|p| lower.contains(p)) {
        let amount = extract_volume_amount(lower).unwrap_or(10);
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::DecreaseBrightness { by: amount },
        });
    }
    // Contrast set.
    for pattern in [
        "set contrast to ",
        "contrast to ",
        "set the contrast to ",
    ] {
        if lower.starts_with(pattern) {
            if let Some(pct) = extract_volume_amount(lower) {
                return Some(PlannedAction::DisplayControl {
                    action: DisplayAction::SetContrast { percent: pct },
                });
            }
        }
    }
    const CONTRAST_UP: &[&str] = &["increase contrast", "contrast up", "more contrast"];
    if CONTRAST_UP.iter().any(|p| lower.contains(p)) {
        let amount = extract_volume_amount(lower).unwrap_or(10);
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::IncreaseContrast { by: amount },
        });
    }
    const CONTRAST_DOWN: &[&str] = &[
        "decrease contrast",
        "contrast down",
        "less contrast",
        "reduce contrast",
    ];
    if CONTRAST_DOWN.iter().any(|p| lower.contains(p)) {
        let amount = extract_volume_amount(lower).unwrap_or(10);
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::DecreaseContrast { by: amount },
        });
    }
    // List resolutions.
    const LIST_RES: &[&str] = &[
        "list resolutions",
        "list the resolutions",
        "show resolutions",
        "show the resolutions",
        "available resolutions",
        "what resolutions",
        "list display modes",
        "show display modes",
    ];
    if LIST_RES.iter().any(|p| lower.contains(p)) {
        return Some(PlannedAction::DisplayControl {
            action: DisplayAction::ListResolutions,
        });
    }
    // Set resolution by shorthand / explicit WxH.
    const RES_TRIGGERS: &[&str] = &[
        "resolution to ",
        "switch to ",
        "change to ",
        "set display to ",
        "change resolution to ",
        "switch resolution to ",
    ];
    for trigger in RES_TRIGGERS {
        if lower.contains(trigger) {
            let after = lower.split(trigger).nth(1).unwrap_or("");
            if let Some((w, h)) = resolve_shorthand(after) {
                return Some(PlannedAction::DisplayControl {
                    action: DisplayAction::SetResolution {
                        width: w,
                        height: h,
                        refresh_rate: None,
                    },
                });
            }
            if let Some((w, h, hz)) = parse_explicit_resolution(lower) {
                return Some(PlannedAction::DisplayControl {
                    action: DisplayAction::SetResolution {
                        width: w,
                        height: h,
                        refresh_rate: hz,
                    },
                });
            }
        }
    }
    if lower.contains("resolution") {
        if let Some((w, h, hz)) = parse_explicit_resolution(lower) {
            return Some(PlannedAction::DisplayControl {
                action: DisplayAction::SetResolution {
                    width: w,
                    height: h,
                    refresh_rate: hz,
                },
            });
        }
    }
    None
}

fn resolve_shorthand(after: &str) -> Option<(i32, i32)> {
    match after.trim().to_lowercase().as_str() {
        "4k" | "uhd" | "2160p" => Some((3840, 2160)),
        "1440p" | "qhd" | "2k" => Some((2560, 1440)),
        "1080p" | "fhd" | "full hd" => Some((1920, 1080)),
        "720p" | "hd" => Some((1280, 720)),
        "1080" => Some((1920, 1080)),
        "1440" => Some((2560, 1440)),
        "2160" => Some((3840, 2160)),
        _ => None,
    }
}

fn explicit_res_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(\d{3,4})\s*(?:x|by)\s*(\d{3,4})(?:\s*(?:@|at)\s*(\d+)\s*(?:hz|hertz))?")
            .expect("resolution regex")
    })
}

fn parse_explicit_resolution(lower: &str) -> Option<(i32, i32, Option<f64>)> {
    let caps = explicit_res_re().captures(lower)?;
    let w: i32 = caps.get(1)?.as_str().parse().ok()?;
    let h: i32 = caps.get(2)?.as_str().parse().ok()?;
    let hz: Option<f64> = caps.get(3).and_then(|m| m.as_str().parse().ok());
    Some((w, h, hz))
}

// ── Volume commands ─────────────────────────────────────────────────

fn word_number_value(word: &str) -> Option<i32> {
    match word {
        "zero" => Some(0),
        "one" => Some(1),
        "two" => Some(2),
        "three" => Some(3),
        "four" => Some(4),
        "five" => Some(5),
        "six" => Some(6),
        "seven" => Some(7),
        "eight" => Some(8),
        "nine" => Some(9),
        "ten" => Some(10),
        "eleven" => Some(11),
        "twelve" => Some(12),
        "thirteen" => Some(13),
        "fourteen" => Some(14),
        "fifteen" => Some(15),
        "sixteen" => Some(16),
        "seventeen" => Some(17),
        "eighteen" => Some(18),
        "nineteen" => Some(19),
        "twenty" => Some(20),
        "thirty" => Some(30),
        "forty" => Some(40),
        "fifty" => Some(50),
        "sixty" => Some(60),
        "seventy" => Some(70),
        "eighty" => Some(80),
        "ninety" => Some(90),
        "hundred" => Some(100),
        _ => None,
    }
}

/// Extract a percentage/amount from spoken text ("by 10%", "by ten", "100").
pub fn extract_volume_amount(lower: &str) -> Option<i32> {
    const WORDS: &[&str] = &[
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty",
        "sixty", "seventy", "eighty", "ninety", "hundred",
    ];
    for word in WORDS {
        for pattern in [
            format!("by {word} percent"),
            format!("by {word}"),
            format!(" {word} percent"),
            format!(" {word}"),
        ] {
            if lower.contains(&pattern) {
                return word_number_value(word).map(|v| v.clamp(0, 100));
            }
        }
    }
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"(?:by\s+)?(\d+)\s*%?").expect("amount regex"));
    let caps = re.captures(lower)?;
    let value: i32 = caps.get(1)?.as_str().parse().ok()?;
    Some(value.clamp(0, 100))
}

fn parse_volume_command(lower: &str) -> Option<PlannedAction> {
    const MUTE: &[&str] = &[
        "mute",
        "mute the sound",
        "mute audio",
        "mute sound",
        "sound off",
        "turn off sound",
        "silence",
        "go silent",
        "shut up",
        "be quiet",
    ];
    if MUTE.contains(&lower) {
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Mute,
        });
    }
    const UNMUTE: &[&str] = &[
        "unmute",
        "sound on",
        "turn on sound",
        "unmute the sound",
        "unmute audio",
        "unmute sound",
    ];
    if UNMUTE.contains(&lower) {
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Unmute,
        });
    }
    if lower.contains("set volume to ") || lower.contains("volume to ") {
        if let Some(pct) = extract_volume_amount(lower) {
            return Some(PlannedAction::VolumeControl {
                action: VolumeAction::SetLevel { level: pct },
            });
        }
    }
    const UP: &[&str] = &[
        "increase volume",
        "increase the volume",
        "increase sound",
        "increase the sound",
        "increase audio",
        "increase the audio",
        "volume up",
        "sound up",
        "audio up",
        "turn up the volume",
        "turn up the sound",
        "turn up",
        "raise volume",
        "raise the volume",
        "louder",
        "make it louder",
        "volume louder",
        "bump up the volume",
        "bump the volume",
    ];
    if UP.iter().any(|p| lower.contains(p)) {
        let amount = extract_volume_amount(lower).unwrap_or(10);
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Increase { by: amount },
        });
    }
    const DOWN: &[&str] = &[
        "decrease volume",
        "decrease the volume",
        "decrease sound",
        "decrease the sound",
        "decrease audio",
        "decrease the audio",
        "volume down",
        "sound down",
        "audio down",
        "turn down the volume",
        "turn down the sound",
        "turn down",
        "lower volume",
        "lower the volume",
        "lower sound",
        "quieter",
        "make it quieter",
        "reduce volume",
        "reduce the volume",
    ];
    if DOWN.iter().any(|p| lower.contains(p)) {
        let amount = extract_volume_amount(lower).unwrap_or(10);
        return Some(PlannedAction::VolumeControl {
            action: VolumeAction::Decrease { by: amount },
        });
    }
    None
}

// ── Media commands ──────────────────────────────────────────────────

fn token_set(text: &str) -> std::collections::HashSet<String> {
    text.to_lowercase()
        .split(|c: char| c == ' ' || c == '\t' || c == '\n')
        .map(|t| t.trim_matches(|c: char| !c.is_alphanumeric()).to_string())
        .filter(|t| !t.is_empty())
        .collect()
}

fn contains_any_word(text: &str, words: &[&str]) -> bool {
    let set = token_set(text);
    words.iter().any(|w| set.contains(*w))
}

fn parse_media_command(lower: &str) -> Option<PlannedAction> {
    let compact = lower.trim();
    if compact.is_empty() {
        return None;
    }
    if contains_any_word(compact, &["open", "close", "launch", "quit"]) {
        return None;
    }
    let explicit = contains_any_word(
        compact,
        &[
            "play", "song", "songs", "music", "track", "liked", "playlist", "next",
            "previous", "prev", "pause", "resume", "skip", "back",
        ],
    );
    if !explicit {
        return None;
    }
    if contains_any_word(compact, &["next", "skip"]) {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::NextTrack,
        });
    }
    if contains_any_word(compact, &["previous", "prev", "back"]) {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::PreviousTrack,
        });
    }
    if contains_any_word(compact, &["pause", "stop"]) {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::Pause,
        });
    }

    let normalized = normalize_media_intent(compact);
    if contains_any_word(&normalized, &["next", "skip"]) {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::NextTrack,
        });
    }
    if contains_any_word(&normalized, &["previous", "prev", "back"]) {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::PreviousTrack,
        });
    }
    if contains_any_word(&normalized, &["liked", "favorites", "favourites", "saved"])
        || is_liked_songs_query(compact)
    {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::PlayLikedSongs,
        });
    }
    if normalized.is_empty() || normalized == "resume" || normalized == "playback" {
        return Some(PlannedAction::MediaControl {
            action: MediaAction::Play,
        });
    }
    if ["youtube", "netflix", "on youtube", "spotify web"]
        .iter()
        .any(|k| compact.contains(k))
    {
        return None;
    }
    if is_playlist_query(compact) || contains_any_word(compact, &["playlist"]) {
        let name = extract_playlist_name(&normalized);
        return Some(PlannedAction::MediaControl {
            action: MediaAction::PlayPlaylist { name },
        });
    }
    let song = extract_song_name(&normalized);
    Some(PlannedAction::MediaControl {
        action: MediaAction::PlaySong { name: song },
    })
}

fn normalize_media_intent(text: &str) -> String {
    const REMOVABLE: &[&str] = &["play", "music", "song", "songs", "track", "tracks", "from"];
    let tokens: Vec<String> = text
        .split(|c: char| c == ' ' || c == '\t' || c == '\n')
        .map(|t| t.to_string())
        .filter(|t| {
            let n = t
                .trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase();
            !REMOVABLE.contains(&n.as_str())
        })
        .collect();
    static RE: OnceLock<Regex> = OnceLock::new();
    let re = RE.get_or_init(|| Regex::new(r"\s+").expect("ws regex"));
    re.replace_all(&tokens.join(" "), " ").trim().to_string()
}

fn preferred_single_control_action(actions: &[PlannedAction]) -> Option<PlannedAction> {
    // Only collapse when the utterance is media control and NOTHING else —
    // otherwise "open spotify, open whatsapp and play a song" would be reduced
    // to just `play`, silently dropping the app opens.
    let all_media = actions
        .iter()
        .all(|a| matches!(a, PlannedAction::MediaControl { .. }));
    if !all_media || actions.len() < 2 {
        return None;
    }
    use MediaAction as M;
    let media: Vec<&M> = actions
        .iter()
        .filter_map(|a| match a {
            PlannedAction::MediaControl { action } => Some(action),
            _ => None,
        })
        .collect();
    for control in [M::NextTrack, M::PreviousTrack, M::Pause, M::Play] {
        if media.contains(&&control) {
            return Some(PlannedAction::MediaControl { action: control });
        }
    }
    None
}

fn extract_playlist_name(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return raw.to_string();
    }
    const FILLER: &[&str] = &["play", "from", "playlist", "my", "the", "some"];
    const SUFFIX: &[&str] = &["songs", "tracks", "music", "station", "mix"];
    let mut cleaned: Vec<String> = trimmed
        .split_whitespace()
        .map(|t| t.to_string())
        .filter(|t| {
            let n = t
                .trim_matches(|c: char| !c.is_alphanumeric())
                .to_lowercase();
            !n.is_empty() && !FILLER.contains(&n.as_str())
        })
        .collect();
    while let Some(last) = cleaned.last() {
        let n = last
            .trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase();
        if SUFFIX.contains(&n.as_str()) {
            cleaned.pop();
        } else {
            break;
        }
    }
    const LEAD: &[&str] = &["play", "music", "song", "songs", "track", "tracks", "some"];
    while cleaned.len() > 1 {
        let first = cleaned.first().cloned().unwrap_or_default();
        let n = first
            .trim_matches(|c: char| !c.is_alphanumeric())
            .to_lowercase();
        if LEAD.contains(&n.as_str()) {
            cleaned.remove(0);
        } else {
            break;
        }
    }
    let out = cleaned.join(" ").trim().to_string();
    if out.is_empty() {
        trimmed.to_string()
    } else {
        out
    }
}

fn extract_song_name(raw: &str) -> String {
    let mut name = raw.trim().to_string();
    let lower = name.to_lowercase();
    for filler in [
        "play song ",
        "play track ",
        "play ",
        "song ",
        "track ",
        "the song ",
        "the track ",
        "music ",
    ] {
        if lower.starts_with(filler) {
            name = name[filler.len()..].trim().to_string();
            break;
        }
    }
    for suffix in [" song", " track", " music", " playlist"] {
        if name.to_lowercase().ends_with(suffix) {
            name = name[..name.len() - suffix.len()].trim().to_string();
            break;
        }
    }
    if name.is_empty() {
        raw.to_string()
    } else {
        name
    }
}

fn is_playlist_query(text: &str) -> bool {
    let lower = text.to_lowercase();
    [
        "playlist",
        "my playlist",
        "from playlist",
        "playlist called",
        "playlist named",
    ]
    .iter()
    .any(|k| lower.contains(k))
}

fn is_liked_songs_query(text: &str) -> bool {
    let lower = text.to_lowercase();
    [
        "liked songs",
        "my liked songs",
        "liked",
        "my liked",
        "saved songs",
        "my saved songs",
        "favorites",
        "my favorites",
    ]
    .iter()
    .any(|k| lower == *k || lower.starts_with(&format!("{k} ")) || lower.ends_with(&format!(" {k}")))
}

// ── Search commands ─────────────────────────────────────────────────

fn search_re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("search regex")
}

fn parse_search_query(lower: &str) -> Option<Vec<PlannedAction>> {
    if lower == "search youtube" || lower == "open youtube search" {
        return Some(vec![PlannedAction::OpenUrl {
            url: "https://www.youtube.com".to_string(),
        }]);
    }
    // (pattern, engine) — YouTube-specific first. Order and coverage mirror
    // Swift's parseSearchQuery table.
    let patterns: &[(&str, &str)] = &[
        (r"search (?:on )?youtube for (.+)", "YouTube"),
        (r"youtube search for (.+)", "YouTube"),
        (r"search google for (.+)", "Google"),
        (r"google (.+)", "Google"),
        (r"search (?:on )?the web for (.+)", "Google"),
        (r"search (?:on )?(?:the )?web for (.+)", "Google"),
        (r"search (?:on the )?internet for (.+)", "Google"),
        (r"search for (.+)", "Google"),
        (r"search (.+?) on youtube", "YouTube"),
        (r"search (.+?) in youtube", "YouTube"),
        (r"search (.+?) on google", "Google"),
        (r"search (.+?) in google", "Google"),
        (r"search (.+?) on the web", "Google"),
        (r"search (.+?) on the internet", "Google"),
        (r"search (.+?) in brave", "Google"),
        (r"search (.+?) on brave", "Google"),
    ];
    for (pattern, engine) in patterns {
        let re = search_re(pattern);
        if let Some(caps) = re.captures(lower) {
            let query = caps
                .get(1)
                .map(|m| trim_search_query(m.as_str()))
                .unwrap_or_default();
            if query.is_empty() {
                continue;
            }
            // SINGLE action: the executor already opens the URL from searchWeb —
            // returning both searchWeb AND openURL opened the browser twice.
            return Some(vec![PlannedAction::SearchWeb {
                engine: engine.to_string(),
                query,
            }]);
        }
    }
    None
}

// ── Conjunction splitter ────────────────────────────────────────────

fn split_by_conjunction(lower: &str) -> Vec<String> {
    let norm = lower
        .replace(", and ", " && ")
        .replace(" and then ", " && ")
        .replace(", then ", " && ")
        .replace(" then ", " && ")
        .replace(" and ", " && ");
    let mut parts: Vec<String> = norm
        .split(" && ")
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect();
    if parts.len() <= 1 {
        return parts;
    }
    const VERBS: &[&str] = &[
        "open ", "close ", "launch ", "play ", "search ", "create ", "run ", "start ",
    ];
    let first_verb = VERBS.iter().find(|v| parts[0].starts_with(**v)).copied();
    if let Some(verb) = first_verb {
        parts = parts
            .iter()
            .map(|p| {
                if VERBS.iter().any(|v| p.starts_with(v)) {
                    p.clone()
                } else {
                    format!("{verb}{p}")
                }
            })
            .collect();
    }
    // STRICT validation: every part needs an action verb or exact media token.
    const EXACT: &[&str] = &[
        "play", "pause", "next", "previous", "prev", "skip", "resume", "mute", "unmute",
    ];
    parts
        .into_iter()
        .filter(|p| VERBS.iter().any(|v| p.starts_with(v)) || EXACT.contains(&p.as_str()))
        .collect()
}

// ── Single-phrase parser ────────────────────────────────────────────

fn parse_single_phrase(lower: &str, original_raw: &str) -> Vec<PlannedAction> {
    // Browser URL shortcuts.
    if lower.starts_with("open youtube") || lower == "youtube" {
        return vec![PlannedAction::OpenUrl {
            url: "https://www.youtube.com".to_string(),
        }];
    }
    if lower.starts_with("open google") && !lower.contains("search") {
        return vec![PlannedAction::OpenUrl {
            url: "https://www.google.com".to_string(),
        }];
    }
    if lower.starts_with("open netflix") || lower == "netflix" {
        return vec![PlannedAction::OpenUrl {
            url: "https://www.netflix.com".to_string(),
        }];
    }
    if lower.starts_with("open github") && !lower.contains("desktop") {
        return vec![PlannedAction::OpenUrl {
            url: "https://github.com".to_string(),
        }];
    }
    if lower.starts_with("open spotify") || lower == "spotify" {
        return vec![PlannedAction::OpenApp {
            name: "Spotify".to_string(),
        }];
    }
    if lower.starts_with("open whatsapp") || lower == "whatsapp" {
        return vec![PlannedAction::OpenApp {
            name: "WhatsApp".to_string(),
        }];
    }
    // "open X in chrome/brave/firefox/safari".
    if let Some((site, browser)) = parse_open_in_browser(lower) {
        return vec![
            PlannedAction::OpenApp {
                name: alias::resolve(&browser),
            },
            PlannedAction::OpenUrl { url: site },
        ];
    }
    // Open folder + latest file.
    if lower.contains("open latest file") || lower.contains("open newest file") {
        let folder = extract_folder_name(lower).unwrap_or_else(|| "Downloads".to_string());
        return vec![
            PlannedAction::OpenFolder {
                path: folder.clone(),
            },
            PlannedAction::OpenLatestFile { folder },
        ];
    }
    // Open folder.
    if let Some(folder) = lower.strip_prefix("open folder ") {
        return vec![PlannedAction::OpenFolder {
            path: folder.to_string(),
        }];
    }
    const KNOWN_FOLDERS: &[&str] = &[
        "downloads",
        "documents",
        "desktop",
        "pictures",
        "movies",
        "music",
    ];
    for kf in KNOWN_FOLDERS {
        if lower == format!("open {kf}") || lower == *kf {
            return vec![PlannedAction::OpenFolder {
                path: kf.to_string(),
            }];
        }
    }
    // App open/close.
    for prefix in ["launch ", "start ", "run ", "open "] {
        if let Some(target) = lower.strip_prefix(prefix) {
            return vec![PlannedAction::OpenApp {
                name: alias::resolve(target),
            }];
        }
    }
    if let Some(target) = lower.strip_prefix("close ") {
        return vec![PlannedAction::CloseApp {
            name: alias::resolve(target),
        }];
    }
    // Create file / folder.
    if let Some(name) = lower.strip_prefix("create file ") {
        return vec![PlannedAction::CreateFile {
            name: name.to_string(),
        }];
    }
    if let Some(name) = lower.strip_prefix("create folder ") {
        return vec![PlannedAction::CreateFolder {
            name: name.to_string(),
        }];
    }
    // Never send system-like commands to AI.
    const BLOCK_PREFIXES: &[&str] = &[
        "volume",
        "mute",
        "unmute",
        "play",
        "pause",
        "next",
        "previous",
        "skip",
        "open folder",
        "open downloads",
        "open documents",
        "open desktop",
        "open ",
        "close ",
        "launch ",
        "start ",
        "run ",
        "search ",
        "create ",
    ];
    if BLOCK_PREFIXES.iter().any(|p| lower.starts_with(p)) {
        return vec![];
    }
    // Noun-only conjunction leftovers are dropped.
    let has_conjunction = lower.contains(" and ") || lower.contains(" then ");
    let has_ai_prefix = ["explain ", "what is ", "who is ", "why ", "how ", "tell me ", "describe "]
        .iter()
        .any(|p| lower.starts_with(p));
    if has_conjunction && !has_ai_prefix {
        return vec![];
    }
    // Genuine AI question (or unmatched → AI query, Swift calls Ollama).
    vec![PlannedAction::AiQuery {
        query: original_raw.to_string(),
    }]
}

fn open_in_browser_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"open (.+) in (chrome|brave|firefox|safari|browser)").expect("browser regex")
    })
}

fn parse_open_in_browser(lower: &str) -> Option<(String, String)> {
    let caps = open_in_browser_re().captures(lower)?;
    let site = caps.get(1)?.as_str().trim().to_string();
    let browser = caps.get(2)?.as_str().to_string();
    Some((site_to_url(&site), browser))
}

fn site_to_url(site: &str) -> String {
    match site {
        "youtube" => "https://www.youtube.com".to_string(),
        "google" => "https://www.google.com".to_string(),
        "spotify" => "https://open.spotify.com".to_string(),
        "whatsapp" => "https://web.whatsapp.com".to_string(),
        "github" => "https://github.com".to_string(),
        "netflix" => "https://www.netflix.com".to_string(),
        s if s.starts_with("http") => s.to_string(),
        s => format!("https://{s}"),
    }
}

fn extract_folder_name(lower: &str) -> Option<String> {
    const KNOWN: &[&str] = &[
        "downloads",
        "documents",
        "desktop",
        "pictures",
        "movies",
        "music",
    ];
    KNOWN
        .iter()
        .find(|k| lower.contains(**k))
        .map(|k| k.to_string())
}

// ── Wake-word / noise strippers ─────────────────────────────────────

fn prefix_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"(?i)^(hey\s+jarvis|ok\s+jarvis|okay\s+jarvis|jarvis)\s+").expect("prefix regex")
    })
}

fn jarvis_any_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\bjarvis\b").expect("jarvis regex"))
}

fn squash_ws_static_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s{2,}").expect("ws regex"))
}

fn strip_wake_word(text: &str) -> String {
    let mut result = text.trim().to_string();
    if let Some(m) = prefix_re().find(&result.clone()) {
        result = result[m.end()..].trim().to_string();
    }
    result = jarvis_any_re()
        .replace_all(&result, "")
        .into_owned();
    squash_ws_static_re()
        .replace_all(&result, " ")
        .trim()
        .to_string()
}

fn strip_trailing_noise(text: &str) -> String {
    const NOISE: &[&str] = &["jarvis", "okay", "ok", "please", "now", "hey", "right"];
    let mut tokens: Vec<String> = text.split_whitespace().map(|t| t.to_string()).collect();
    loop {
        match tokens.last().map(|t| t.to_lowercase()) {
            Some(last) if NOISE.contains(&last.as_str()) => {
                tokens.pop();
            }
            _ => break,
        }
    }
    tokens.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_wake_word() {
        assert_eq!(strip_wake_word("Jarvis open Chrome"), "open Chrome");
        assert_eq!(strip_wake_word("hey jarvis play music"), "play music");
        assert_eq!(strip_wake_word("JARVIS next song"), "next song");
    }

    #[test]
    fn plans_open_app() {
        let p = plan("Jarvis open Chrome");
        assert_eq!(
            p,
            vec![PlannedAction::OpenApp {
                name: "Google Chrome".to_string()
            }]
        );
    }

    #[test]
    fn plans_close_app() {
        let p = plan("close TextEdit");
        assert!(matches!(p[0], PlannedAction::CloseApp { .. }));
    }

    #[test]
    fn plans_conjunction() {
        // Compound commands are split BEFORE any whole-string rule, so a
        // two-app utterance yields two ordered actions instead of one garbled
        // open ("open Chrome and WhatsApp" used to become one app name).
        let p = plan("open Chrome and WhatsApp");
        assert_eq!(p.len(), 2, "got {p:?}");
        assert!(matches!(p[0], PlannedAction::OpenApp { .. }));
        assert!(matches!(p[1], PlannedAction::OpenApp { .. }));

        // A trailing noun-only clause still propagates the leading verb.
        let q = plan("open Notes and Calendar");
        assert_eq!(q.len(), 2, "got {q:?}");
    }

    #[test]
    fn plans_media() {
        assert!(matches!(
            plan("pause")[0],
            PlannedAction::MediaControl { .. }
        ));
        assert!(matches!(
            plan("next song")[0],
            PlannedAction::MediaControl { .. }
        ));
    }

    #[test]
    fn plans_volume() {
        assert!(matches!(
            plan("increase volume")[0],
            PlannedAction::VolumeControl { .. }
        ));
        assert!(matches!(
            plan("mute")[0],
            PlannedAction::VolumeControl { .. }
        ));
    }

    #[test]
    fn plans_search_never_ai() {
        let p = plan("search youtube for swift package manager");
        assert_eq!(p.len(), 1);
        assert!(matches!(p[0], PlannedAction::SearchWeb { .. }));
        assert!(!p.iter().any(|a| matches!(a, PlannedAction::OpenUrl { .. })));
        assert!(!p.iter().any(|a| matches!(a, PlannedAction::AiQuery { .. })));
    }

    #[test]
    fn fast_path_search_phrasings() {
        for input in [
            "search on youtube for lofi beats",
            "search lofi in youtube",
            "search on the internet for rust books",
            "search lofi on brave",
        ] {
            let p = plan(input);
            assert_eq!(p.len(), 1, "{input}");
            assert!(
                matches!(&p[0], PlannedAction::SearchWeb { .. }),
                "expected SearchWeb for '{input}', got {:?}",
                p[0]
            );
        }
    }

    #[test]
    fn plans_info() {
        // Swift parity: the fast-path quick-info gate intercepts these before
        // the info rules, so they come back as AI queries (answered locally
        // downstream by the app).
        assert!(matches!(
            plan("what time is it")[0],
            PlannedAction::AiQuery { .. }
        ));
        assert!(matches!(
            plan("battery status")[0],
            PlannedAction::AiQuery { .. }
        ));
        // "volume level" is not in the quick-info list → info rule.
        assert!(matches!(
            plan("volume level")[0],
            PlannedAction::SystemInfo { .. }
        ));
    }

    #[test]
    fn local_state_reads() {
        assert!(matches!(
            plan("what is the current brightness level")[0],
            PlannedAction::SystemInfo {
                info: SystemInfoAction::DisplayBrightness
            }
        ));
        assert!(matches!(
            plan("show contrast")[0],
            PlannedAction::SystemInfo {
                info: SystemInfoAction::DisplayContrast
            }
        ));
    }

    #[test]
    fn resolution_shorthand_is_exact_match() {
        assert_eq!(resolve_shorthand("2160p"), Some((3840, 2160)));
        assert_eq!(resolve_shorthand("uhd"), Some((3840, 2160)));
        assert_eq!(resolve_shorthand("720p"), Some((1280, 720)));
        assert_eq!(resolve_shorthand("fhd"), Some((1920, 1080)));
        assert_eq!(resolve_shorthand("1080"), Some((1920, 1080)));
        assert_eq!(resolve_shorthand("something odd"), None);
        assert!(matches!(
            parse_display_command("switch to 2160p"),
            Some(PlannedAction::DisplayControl { .. })
        ));
    }

    #[test]
    fn plans_display() {
        assert!(matches!(
            plan("increase brightness")[0],
            PlannedAction::DisplayControl { .. }
        ));
    }

    #[test]
    fn plans_create() {
        assert!(matches!(
            plan("create folder demo")[0],
            PlannedAction::CreateFolder { .. }
        ));
    }

    #[test]
    fn blocks_sudo() {
        let p = plan("sudo rm -rf /");
        assert!(matches!(p[0], PlannedAction::AiQuery { .. }));
        assert!(p[0].description().contains("blocked:"));
    }

    #[test]
    fn ai_query_passthrough() {
        let p = plan("explain quantum computing in great detail please elaborate thoroughly");
        assert!(matches!(p[0], PlannedAction::AiQuery { .. }));
    }

    #[test]
    fn escalates_unmatched_system_input() {
        // Noun-only conjunction without verbs: ≤3 words and no system keyword
        // → dropped by the fast path (Swift parity).
        assert!(plan("chrome and whatsapp").is_empty());
        // A system keyword that matches no rule is NO LONGER dropped. It
        // escalates to the AI so the chain never terminates in silence.
        let p = plan("fluffy volume clouds and dreams");
        assert!(
            matches!(p.first(), Some(PlannedAction::AiQuery { .. })),
            "expected an AI escalation, got {p:?}"
        );
    }
}
