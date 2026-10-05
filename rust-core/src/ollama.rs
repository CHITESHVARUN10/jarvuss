//! Port of Swift `OllamaClient` + `JarvisToolsPrompt` + the Shape A/B parsing
//! from `ActionPlanner.ollamaFallback` / `CommandNormalizer.ollamaFallback`.
//!
//! Memory guards are preserved: the model is unloaded after 60 s idle
//! (`keep_alive`), every request has a 60 s timeout, and a process-wide lock
//! guarantees only one `/api/generate` runs at a time (parallel calls would
//! each load a runner and spike unified memory).

use crate::actions::{
    DisplayAction, MediaAction, PlannedAction, SystemInfoAction, VolumeAction,
};
use crate::alias;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;

pub const MODEL: &str = "qwen2.5:1.5b-instruct";
pub const KEEP_ALIVE_SECONDS: i64 = 60;
const TIMEOUT_SECONDS: u64 = 60;
const ENDPOINT: &str = "http://127.0.0.1:11434/api/generate";

/// Shared tools prompt (`JarvisToolsPrompt.text`). X (what the user said) +
/// this prompt in, Y (the exact JSON our executor runs) out. One prompt,
/// array output only — the command is appended as "\nCommand: <text>\n",
/// continuing the few-shot pattern.
pub const TOOLS_PROMPT: &str = r#"You convert one spoken Mac command into JSON for an executor. Reply with a JSON array only. No prose, no markdown.

Tools (use only these "type" values):
{"type":"open_app","app":"<app name>"}
{"type":"close_app","app":"<app name>"}
{"type":"open_folder","path":"<Downloads|Documents|Desktop|~/path>"}
{"type":"search_web","engine":"Google|YouTube","query":"<search terms>"}
{"type":"media","action":"play|pause|next|prev|liked_songs|play_song:<title>|play_playlist:<name>"}
{"type":"set_volume","level":<0-100>}
{"type":"mute"}
{"type":"set_brightness","level":<0-100>}
{"type":"system_info","kind":"time|date|battery|wifi|bluetooth|volume|brightness"}
{"type":"ai_query","query":"<the user's words>"}

Rules:
- Ignore the wake word "Jarvis" and words like please, can you, the.
- One action per thing asked, in spoken order. Split on "and", "then", "also". Maximum 5.
- App names: the app's usual name, capitalised (Spotify, Finder, Chrome). Fix obvious mishearings. Never invent an app.
- Song and playlist names: as spoken, in Title Case.
- "search YouTube for X" -> search_web engine YouTube. "search Google / the web for X" -> search_web engine Google. Never write URLs.
- Questions, chat, or anything needing a tool not listed (delete, run a command, sudo, install, send a message) -> one ai_query with the raw words.

Command: Jarvis open the terminal
[{"type":"open_app","app":"Terminal"}]
Command: open spotify and play blinding lights
[{"type":"open_app","app":"Spotify"},{"type":"media","action":"play_song:Blinding Lights"}]
Command: search youtube for lofi beats
[{"type":"search_web","engine":"YouTube","query":"lofi beats"}]
Command: close chrome and open finder
[{"type":"close_app","app":"Chrome"},{"type":"open_app","app":"Finder"}]
Command: whats my battery and set brightness to 24
[{"type":"system_info","kind":"battery"},{"type":"set_brightness","level":24}]
Command: next song
[{"type":"media","action":"next"}]
Command: why is the sky blue
[{"type":"ai_query","query":"why is the sky blue"}]
Command: delete everything in downloads
[{"type":"ai_query","query":"delete everything in downloads"}]
"#;

fn generate_lock() -> &'static Mutex<()> {
    static LOCK: std::sync::OnceLock<Mutex<()>> = std::sync::OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

/// Raw Ollama result, including the char counts Swift feeds to StatsRecorder.
#[derive(Debug, Clone, uniffi::Record)]
pub struct OllamaGenerateOutcome {
    pub text: String,
    pub prompt_chars: i64,
    pub response_chars: i64,
    pub error: Option<String>,
}

/// One blocking `/api/generate` call (serialized process-wide).
pub fn generate(prompt: &str) -> OllamaGenerateOutcome {
    let failed = |error: String| OllamaGenerateOutcome {
        text: error.clone(),
        prompt_chars: prompt.chars().count() as i64,
        response_chars: 0,
        error: Some(error),
    };

    let client = match reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(TIMEOUT_SECONDS))
        .build()
    {
        Ok(c) => c,
        Err(e) => return failed(format!("Ollama error: {e}. Make sure Ollama is running.")),
    };

    // Single-flight guard: only one inference at a time app-wide.
    let _guard = generate_lock().lock().unwrap_or_else(|e| e.into_inner());

    let response = client
        .post(ENDPOINT)
        .json(&json!({
            "model": MODEL,
            "prompt": prompt,
            "stream": false,
            "keep_alive": KEEP_ALIVE_SECONDS,
        }))
        .send();

    let response = match response {
        Ok(r) => r,
        Err(e) => return failed(format!("Ollama error: {e}. Make sure Ollama is running.")),
    };
    if !response.status().is_success() {
        return failed("Ollama request failed: unexpected HTTP response.".to_string());
    }

    let body: Value = match response.json() {
        Ok(v) => v,
        Err(e) => return failed(format!("Ollama error: {e}. Make sure Ollama is running.")),
    };
    let text = body
        .get("response")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();

    OllamaGenerateOutcome {
        prompt_chars: prompt.chars().count() as i64,
        response_chars: text.chars().count() as i64,
        text,
        error: None,
    }
}

// ── Shape A: planner fallback ───────────────────────────────────────

#[derive(Debug, Clone, uniffi::Record)]
pub struct OllamaPlanResult {
    pub actions: Vec<PlannedAction>,
    /// False when the model output could not be parsed — `actions` then holds
    /// the single `AiQuery(cleaned)` fallback, matching Swift.
    pub parsed: bool,
    pub raw: String,
    pub prompt_chars: i64,
    pub response_chars: i64,
    pub error: Option<String>,
}

/// Planner fallback: tools prompt + "Command: …" → ordered actions.
pub fn plan(cleaned: &str) -> OllamaPlanResult {
    let prompt = format!("{TOOLS_PROMPT}\nCommand: {cleaned}\n");
    let outcome = generate(&prompt);
    let parsed = parse_tool_array(&outcome.text);
    OllamaPlanResult {
        actions: parsed
            .clone()
            .unwrap_or_else(|| vec![PlannedAction::AiQuery { query: cleaned.to_string() }]),
        parsed: parsed.is_some(),
        raw: outcome.text,
        prompt_chars: outcome.prompt_chars,
        response_chars: outcome.response_chars,
        error: outcome.error,
    }
}

/// Numeric JSON value (or numeric string) clamped to a 0-100 percent.
fn clamp_percent(value: &Value) -> Option<i32> {
    let n = if let Some(i) = value.as_i64() {
        i as f64
    } else if let Some(u) = value.as_u64() {
        u as f64
    } else if let Some(f) = value.as_f64() {
        f
    } else if let Some(s) = value.as_str() {
        s.parse::<f64>().ok()?
    } else {
        return None;
    };
    Some(n.round().clamp(0.0, 100.0) as i32)
}

/// Tool-prompt `system_info.kind` → action; unknown kinds return None.
fn system_info_from_kind(kind: &str) -> Option<SystemInfoAction> {
    match kind {
        "time" => Some(SystemInfoAction::CurrentTime),
        "date" => Some(SystemInfoAction::CurrentDate),
        "battery" => Some(SystemInfoAction::BatteryStatus),
        "wifi" => Some(SystemInfoAction::WifiStatus),
        "bluetooth" => Some(SystemInfoAction::BluetoothDevices),
        "volume" => Some(SystemInfoAction::SystemVolume),
        "brightness" => Some(SystemInfoAction::DisplayBrightness),
        "contrast" => Some(SystemInfoAction::DisplayContrast),
        _ => None,
    }
}

/// Port of `ActionPlanner.parseOllamaActions` — the tools prompt's JSON array.
/// Strict schema: a recognized type with a missing/invalid payload (e.g.
/// `system_info` kind "weather") rejects the whole response so callers
/// degrade to a single ai_query instead of executing a wrong action.
/// Unknown types are skipped; an output with nothing usable returns None.
pub fn parse_tool_array(raw: &str) -> Option<Vec<PlannedAction>> {
    let start = raw.find('[')?;
    let end = raw.rfind(']')?;
    if end < start {
        return None;
    }
    let array: Value = serde_json::from_str(&raw[start..=end]).ok()?;
    let items = array.as_array()?;

    let mut actions: Vec<PlannedAction> = vec![];
    for obj in items {
        let kind = obj.get("type").and_then(Value::as_str)?;
        let string = |key: &str| obj.get(key).and_then(Value::as_str);
        match kind {
            "open_app" => {
                actions.push(PlannedAction::OpenApp {
                    name: string("app")?.to_string(),
                });
            }
            "close_app" => {
                actions.push(PlannedAction::CloseApp {
                    name: string("app")?.to_string(),
                });
            }
            "open_url" => {
                actions.push(PlannedAction::OpenUrl {
                    url: string("url")?.to_string(),
                });
            }
            "search_web" => {
                actions.push(PlannedAction::SearchWeb {
                    engine: string("engine").unwrap_or("Google").to_string(),
                    query: string("query")?.to_string(),
                });
            }
            "open_folder" => {
                actions.push(PlannedAction::OpenFolder {
                    path: string("path")?.to_string(),
                });
            }
            "set_volume" => {
                actions.push(PlannedAction::VolumeControl {
                    action: VolumeAction::SetLevel {
                        level: obj.get("level").and_then(clamp_percent)?,
                    },
                });
            }
            "mute" => {
                actions.push(PlannedAction::VolumeControl {
                    action: VolumeAction::Mute,
                });
            }
            "set_brightness" => {
                actions.push(PlannedAction::DisplayControl {
                    action: DisplayAction::SetBrightness {
                        percent: obj.get("level").and_then(clamp_percent)?,
                    },
                });
            }
            "system_info" => {
                actions.push(PlannedAction::SystemInfo {
                    info: string("kind").and_then(system_info_from_kind)?,
                });
            }
            "media" => {
                actions.push(PlannedAction::MediaControl {
                    action: parse_media_spec(string("action")?)?,
                });
            }
            "ai_query" => {
                actions.push(PlannedAction::AiQuery {
                    query: string("query")?.to_string(),
                });
            }
            _ => {} // unknown type — skip; empty result still yields None
        }
    }
    if actions.is_empty() {
        None
    } else {
        Some(actions)
    }
}

/// "play|pause|next|prev|liked_songs|play_song:X|play_playlist:X".
fn parse_media_spec(raw: &str) -> Option<MediaAction> {
    match raw {
        "play" => Some(MediaAction::Play),
        "pause" => Some(MediaAction::Pause),
        "next" => Some(MediaAction::NextTrack),
        "prev" => Some(MediaAction::PreviousTrack),
        "liked_songs" => Some(MediaAction::PlayLikedSongs),
        _ => {
            if let Some(name) = raw.strip_prefix("play_song:") {
                Some(MediaAction::PlaySong {
                    name: name.to_string(),
                })
            } else if let Some(name) = raw.strip_prefix("play_playlist:") {
                Some(MediaAction::PlayPlaylist {
                    name: name.to_string(),
                })
            } else {
                None
            }
        }
    }
}

// ── Normalizer fallback (shared tools prompt) ───────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NormalizedPriority {
    High,
    Normal,
    Low,
}

/// Action list the normalizer produces — mirrors Swift `CommandAction`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CommandAction {
    OpenApp { name: String },
    CloseApp { name: String },
    OpenUrl { url: String },
    SearchWeb { engine: String, query: String },
    OpenFolder { path: String },
    CreateFile { name: String },
    CreateFolder { name: String },
    Media { action: String },
    Volume { action: String },
    Display { action: String },
    SystemInfo { kind: String },
    AiQuery { query: String },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NormalizedCommand {
    pub priority: NormalizedPriority,
    pub actions: Vec<CommandAction>,
    pub is_ai_query: bool,
    pub blocked: bool,
    pub blocked_reason: Option<String>,
    pub raw: String,
    pub prompt_chars: i64,
    pub response_chars: i64,
    pub error: Option<String>,
}

/// Normalizer fallback: same tools prompt as the planner, array output.
pub fn normalize(cleaned: &str) -> NormalizedCommand {
    let prompt = format!("{TOOLS_PROMPT}\nCommand: {cleaned}\n");
    let outcome = generate(&prompt);
    normalize_from_text(
        &outcome.text,
        cleaned,
        outcome.prompt_chars,
        outcome.response_chars,
        outcome.error,
    )
}

/// Pure half of `normalize` — split out so tests never hit Ollama.
fn normalize_from_text(
    raw: &str,
    cleaned: &str,
    prompt_chars: i64,
    response_chars: i64,
    error: Option<String>,
) -> NormalizedCommand {
    if let Some(parsed) = parse_tool_array(raw) {
        let actions: Vec<CommandAction> = parsed.iter().filter_map(command_action_from).collect();
        if !actions.is_empty() {
            let is_ai_query = actions
                .iter()
                .all(|a| matches!(a, CommandAction::AiQuery { .. }));
            return NormalizedCommand {
                priority: NormalizedPriority::Normal,
                actions,
                is_ai_query,
                blocked: false,
                blocked_reason: None,
                raw: cleaned.to_string(),
                prompt_chars,
                response_chars,
                error,
            };
        }
    }

    // Garbage / unreachable model → single AI query on the original text.
    NormalizedCommand {
        priority: NormalizedPriority::Normal,
        actions: vec![CommandAction::AiQuery {
            query: cleaned.to_string(),
        }],
        is_ai_query: true,
        blocked: false,
        blocked_reason: None,
        raw: cleaned.to_string(),
        prompt_chars,
        response_chars,
        error,
    }
}

/// Planner action → normalizer action. Only types the tools prompt can emit
/// round-trip; anything else is dropped.
fn command_action_from(action: &PlannedAction) -> Option<CommandAction> {
    match action {
        PlannedAction::OpenApp { name } => Some(CommandAction::OpenApp {
            name: alias::resolve(name),
        }),
        PlannedAction::CloseApp { name } => Some(CommandAction::CloseApp {
            name: alias::resolve(name),
        }),
        PlannedAction::OpenUrl { url } => Some(CommandAction::OpenUrl { url: url.clone() }),
        PlannedAction::SearchWeb { engine, query } => Some(CommandAction::SearchWeb {
            engine: engine.clone(),
            query: query.clone(),
        }),
        PlannedAction::OpenFolder { path } => Some(CommandAction::OpenFolder { path: path.clone() }),
        PlannedAction::MediaControl { action } => Some(CommandAction::Media {
            action: media_spec(action),
        }),
        PlannedAction::VolumeControl { action } => Some(CommandAction::Volume {
            action: volume_spec(action),
        }),
        PlannedAction::DisplayControl { action } => display_spec(action).map(|spec| {
            CommandAction::Display { action: spec }
        }),
        PlannedAction::SystemInfo { info } => Some(CommandAction::SystemInfo {
            kind: system_info_kind(info).to_string(),
        }),
        PlannedAction::AiQuery { query } => Some(CommandAction::AiQuery {
            query: query.clone(),
        }),
        _ => None,
    }
}

/// "play|pause|next|prev|liked_songs|play_song:X|play_playlist:X" (inverse of
/// `parse_media_spec`).
fn media_spec(action: &MediaAction) -> String {
    match action {
        MediaAction::Play => "play".to_string(),
        MediaAction::Pause => "pause".to_string(),
        MediaAction::NextTrack => "next".to_string(),
        MediaAction::PreviousTrack => "prev".to_string(),
        MediaAction::PlayLikedSongs => "liked_songs".to_string(),
        MediaAction::PlaySong { name } => format!("play_song:{name}"),
        MediaAction::PlayPlaylist { name } => format!("play_playlist:{name}"),
    }
}

/// "set:<0-100>|mute|unmute" (Swift `toPlannedVolume` reads this spec).
fn volume_spec(action: &VolumeAction) -> String {
    match action {
        VolumeAction::SetLevel { level } => format!("set:{level}"),
        VolumeAction::Mute => "mute".to_string(),
        VolumeAction::Unmute => "unmute".to_string(),
        VolumeAction::Increase { by } => format!("increase:{by}"),
        VolumeAction::Decrease { by } => format!("decrease:{by}"),
    }
}

/// Only set-brightness round-trips (the tools prompt can't emit the rest);
/// Swift `toPlannedDisplay` reads "brightness:<0-100>".
fn display_spec(action: &DisplayAction) -> Option<String> {
    match action {
        DisplayAction::SetBrightness { percent } => Some(format!("brightness:{percent}")),
        _ => None,
    }
}

fn system_info_kind(info: &SystemInfoAction) -> &'static str {
    match info {
        SystemInfoAction::CurrentTime => "time",
        SystemInfoAction::CurrentDate => "date",
        SystemInfoAction::BatteryStatus => "battery",
        SystemInfoAction::WifiStatus => "wifi",
        SystemInfoAction::BluetoothDevices => "bluetooth",
        SystemInfoAction::SystemVolume => "volume",
        SystemInfoAction::DisplayBrightness => "brightness",
        SystemInfoAction::DisplayContrast => "contrast",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tools_array_multi_step_with_preamble() {
        let raw = r#"Sure! [{"type":"open_app","app":"Spotify"},{"type":"media","action":"play_song:Blinding Lights"}]"#;
        let actions = parse_tool_array(raw).expect("parsed");
        assert_eq!(
            actions,
            vec![
                PlannedAction::OpenApp {
                    name: "Spotify".to_string()
                },
                PlannedAction::MediaControl {
                    action: MediaAction::PlaySong {
                        name: "Blinding Lights".to_string()
                    }
                }
            ]
        );
    }

    #[test]
    fn tools_array_media_specs() {
        assert_eq!(parse_media_spec("next"), Some(MediaAction::NextTrack));
        assert_eq!(
            parse_media_spec("play_playlist:Gym"),
            Some(MediaAction::PlayPlaylist {
                name: "Gym".to_string()
            })
        );
        assert_eq!(parse_media_spec("bogus"), None);
    }

    #[test]
    fn tools_array_empty_or_garbage_is_none() {
        assert!(parse_tool_array("no json here").is_none());
        assert!(parse_tool_array("[]").is_none());
        assert!(parse_tool_array(r#"[{"type":"unknown"}]"#).is_none());
    }

    #[test]
    fn tools_array_new_action_types() {
        // The new prompt's vocabulary: search engine, set_volume (clamped),
        // mute, set_brightness, system_info — plus open_folder.
        let raw = r#"[
            {"type":"search_web","engine":"YouTube","query":"lofi beats"},
            {"type":"set_volume","level":150},
            {"type":"mute"},
            {"type":"set_brightness","level":"24"},
            {"type":"system_info","kind":"battery"},
            {"type":"open_folder","path":"Downloads"}
        ]"#;
        let actions = parse_tool_array(raw).expect("parsed");
        assert_eq!(
            actions,
            vec![
                PlannedAction::SearchWeb {
                    engine: "YouTube".to_string(),
                    query: "lofi beats".to_string(),
                },
                PlannedAction::VolumeControl {
                    action: VolumeAction::SetLevel { level: 100 },
                },
                PlannedAction::VolumeControl {
                    action: VolumeAction::Mute,
                },
                PlannedAction::DisplayControl {
                    action: DisplayAction::SetBrightness { percent: 24 },
                },
                PlannedAction::SystemInfo {
                    info: SystemInfoAction::BatteryStatus,
                },
                PlannedAction::OpenFolder {
                    path: "Downloads".to_string(),
                },
            ]
        );
    }

    #[test]
    fn tools_array_unknown_kinds_are_dropped() {
        let raw = r#"[{"type":"system_info","kind":"weather"},{"type":"set_volume","level":"hot"}]"#;
        assert!(parse_tool_array(raw).is_none());
    }

    #[test]
    fn tools_array_bad_payload_rejects_all() {
        // A recognized type with an invalid payload invalidates the whole
        // response — "date" must not execute when the model hallucinated
        // `system_info.kind = "weather tomorrow"` for a weather question.
        let raw = r#"[{"type":"system_info","kind":"date"},{"type":"system_info","kind":"weather tomorrow"}]"#;
        assert!(parse_tool_array(raw).is_none());
        let raw = r#"[{"type":"open_app","app":"Chrome"},{"type":"set_volume","level":"hot"}]"#;
        assert!(parse_tool_array(raw).is_none());
        let raw = r#"[{"type":"media","action":"bogus"}]"#;
        assert!(parse_tool_array(raw).is_none());
    }

    #[test]
    fn normalize_array_actions() {
        let raw = r#"[{"type":"open_app","app":"photos"},{"type":"search_web","engine":"YouTube","query":"lofi"},{"type":"set_volume","level":30},{"type":"system_info","kind":"time"}]"#;
        let nc = normalize_from_text(raw, "open photos and search youtube for lofi", 100, 80, None);
        assert!(!nc.is_ai_query);
        assert_eq!(nc.priority, NormalizedPriority::Normal);
        assert_eq!(
            nc.actions,
            vec![
                CommandAction::OpenApp {
                    name: alias::resolve("photos")
                },
                CommandAction::SearchWeb {
                    engine: "YouTube".to_string(),
                    query: "lofi".to_string(),
                },
                CommandAction::Volume {
                    action: "set:30".to_string(),
                },
                CommandAction::SystemInfo {
                    kind: "time".to_string(),
                },
            ]
        );
    }

    #[test]
    fn normalize_all_ai_marks_query() {
        let raw = r#"[{"type":"ai_query","query":"what is rust"}]"#;
        let nc = normalize_from_text(raw, "what is rust", 0, 0, None);
        assert!(nc.is_ai_query);
        assert_eq!(
            nc.actions,
            vec![CommandAction::AiQuery {
                query: "what is rust".to_string()
            }]
        );
    }

    #[test]
    fn normalize_garbage_degrades_to_ai_query() {
        for raw in ["nothing", "[]", r#"{"actions":[]}"#] {
            let nc = normalize_from_text(raw, "delete everything in downloads", 0, 0, None);
            assert!(nc.is_ai_query, "raw={raw:?}");
            assert_eq!(
                nc.actions,
                vec![CommandAction::AiQuery {
                    query: "delete everything in downloads".to_string()
                }]
            );
        }
    }

    /// Live smoke test — needs `ollama serve` and the qwen2.5:1.5b-instruct
    /// model. Run with: `cargo test ollama_live -- --ignored --nocapture`
    ///
    /// Contract under test: a live call never errors at the transport level,
    /// and always yields actions — either the parsed plan, or the single
    /// `aiQuery` fallback (which is what Swift does for unparseable output).
    #[test]
    #[ignore]
    fn ollama_live_planner_and_normalizer() {
        let planned = plan("open spotify and play blinding lights");
        assert!(planned.error.is_none(), "ollama error: {:?}", planned.error);
        assert!(!planned.actions.is_empty());
        println!(
            "[live] planner parsed={} prompt_chars={} response_chars={} raw={:?}",
            planned.parsed, planned.prompt_chars, planned.response_chars, planned.raw
        );

        let normalized = normalize("open youtube in chrome");
        assert!(normalized.error.is_none(), "ollama error: {:?}", normalized.error);
        assert!(!normalized.actions.is_empty());
        println!(
            "[live] normalizer actions={:?} raw={:?}",
            normalized.actions, normalized.raw
        );
    }
}
