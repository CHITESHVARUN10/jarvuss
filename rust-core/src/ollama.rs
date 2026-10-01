//! Port of Swift `OllamaClient` + `JarvisToolsPrompt` + the Shape A/B parsing
//! from `ActionPlanner.ollamaFallback` / `CommandNormalizer.ollamaFallback`.
//!
//! Memory guards are preserved: the model is unloaded after 60 s idle
//! (`keep_alive`), every request has a 60 s timeout, and a process-wide lock
//! guarantees only one `/api/generate` runs at a time (parallel calls would
//! each load a runner and spike unified memory).

use crate::actions::{MediaAction, PlannedAction};
use crate::alias;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;

pub const MODEL: &str = "qwen2.5-coder:1.5b-base";
pub const KEEP_ALIVE_SECONDS: i64 = 60;
const TIMEOUT_SECONDS: u64 = 60;
const ENDPOINT: &str = "http://127.0.0.1:11434/api/generate";

/// Shared tools prompt (`JarvisToolsPrompt.text`). X (what the user said) +
/// this prompt in, Y (the exact JSON our executor runs) out.
pub const TOOLS_PROMPT: &str = r#"You map a voice command to JSON our macOS executor runs. Output ONLY the JSON, no words before or after.

Tools:
- open_app(app): open a Mac app. Inside apps via Spotify backend: play/pause/next/previous a song, play liked songs, play a named playlist, search+play a song.
- close_app(app): close a Mac app.
- open_url(url): open a web destination in the default browser. Use for "search YouTube for X" -> https://www.youtube.com/results?search_query=X.
- search_web(engine, query): web search. engine is Google. Use for "search the web / google for X".
- open_folder(path): open a Finder folder.
- media(action): Spotify playback. action is play|pause|next|prev|liked_songs|play_song|play_playlist. Needs "song" or "playlist" name after a colon, e.g. play_song:Blinding Lights.
- ai_query(query): anything else (questions, chat, unknown).

Shape A (planner, array):
[{"type":"open_app","app":"Spotify"},{"type":"media","action":"play_song:Blinding Lights"}]
Shape B (normalizer, object):
{"priority":"normal","actions":[{"type":"open_app","value":"Spotify"},{"type":"media","value":"play_song:Blinding Lights"}]}

Rules:
- "open X" -> open_app. "close X" -> close_app.
- "search YouTube for X" -> open_url with the youtube search URL, never ai_query.
- "search Google/the web for X" -> search_web engine Google.
- "play <song>" -> media play_song:<song>. "play playlist <name>" -> media play_playlist:<name>. "liked songs" -> media liked_songs. "next/previous song" -> media next/prev.
- "open Spotify and play X" -> open_app Spotify THEN the media action, in order.
- Unsure -> single ai_query with the raw words.

Input:
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

/// Planner fallback: "Respond with Shape A" → ordered actions.
pub fn plan(cleaned: &str) -> OllamaPlanResult {
    let prompt = format!("{TOOLS_PROMPT}Respond with Shape A.\n\nUser: {cleaned}");
    let outcome = generate(&prompt);
    let parsed = parse_shape_a(&outcome.text);
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

/// Port of `ActionPlanner.parseOllamaActions`.
pub fn parse_shape_a(raw: &str) -> Option<Vec<PlannedAction>> {
    let start = raw.find('[')?;
    let end = raw.rfind(']')?;
    if end < start {
        return None;
    }
    let array: Value = serde_json::from_str(&raw[start..=end]).ok()?;
    let items = array.as_array()?;

    let mut actions: Vec<PlannedAction> = vec![];
    for obj in items {
        let Some(kind) = obj.get("type").and_then(Value::as_str) else {
            continue;
        };
        let string = |key: &str| obj.get(key).and_then(Value::as_str);
        match kind {
            "open_app" => {
                if let Some(app) = string("app") {
                    actions.push(PlannedAction::OpenApp {
                        name: app.to_string(),
                    });
                }
            }
            "close_app" => {
                if let Some(app) = string("app") {
                    actions.push(PlannedAction::CloseApp {
                        name: app.to_string(),
                    });
                }
            }
            "open_url" => {
                if let Some(url) = string("url") {
                    actions.push(PlannedAction::OpenUrl {
                        url: url.to_string(),
                    });
                }
            }
            "search_web" => {
                let engine = string("engine").unwrap_or("Google");
                if let Some(query) = string("query") {
                    actions.push(PlannedAction::SearchWeb {
                        engine: engine.to_string(),
                        query: query.to_string(),
                    });
                }
            }
            "open_folder" => {
                if let Some(path) = string("path") {
                    actions.push(PlannedAction::OpenFolder {
                        path: path.to_string(),
                    });
                }
            }
            "media" => {
                if let Some(action) = string("action") {
                    if let Some(media) = parse_media_spec(action) {
                        actions.push(PlannedAction::MediaControl { action: media });
                    }
                }
            }
            "ai_query" => {
                if let Some(query) = string("query") {
                    actions.push(PlannedAction::AiQuery {
                        query: query.to_string(),
                    });
                }
            }
            _ => {}
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

// ── Shape B: normalizer fallback ────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum NormalizedPriority {
    High,
    Normal,
    Low,
}

/// Marker-shaped action list from the normalizer's Shape B.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CommandAction {
    OpenApp { name: String },
    CloseApp { name: String },
    OpenUrl { url: String },
    SearchWeb { query: String },
    OpenFolder { path: String },
    CreateFile { name: String },
    CreateFolder { name: String },
    Media { action: String },
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

/// Normalizer fallback: "Respond with Shape B" → structured command.
pub fn normalize(cleaned: &str) -> NormalizedCommand {
    let prompt = format!("{TOOLS_PROMPT}Respond with Shape B.\n\nUser: {cleaned}");
    let outcome = generate(&prompt);

    if let Some(parsed) = parse_shape_b(&outcome.text, cleaned) {
        return NormalizedCommand {
            prompt_chars: outcome.prompt_chars,
            response_chars: outcome.response_chars,
            error: outcome.error,
            ..parsed
        };
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
        prompt_chars: outcome.prompt_chars,
        response_chars: outcome.response_chars,
        error: outcome.error,
    }
}

/// Port of `CommandNormalizer.parseOllamaJSON`.
pub fn parse_shape_b(raw: &str, original: &str) -> Option<NormalizedCommand> {
    let start = raw.find('{')?;
    let end = raw.rfind('}')?;
    if end < start {
        return None;
    }
    let object: Value = serde_json::from_str(&raw[start..=end]).ok()?;
    let items = object.get("actions")?.as_array()?;

    let priority = match object.get("priority").and_then(Value::as_str) {
        Some("high") => NormalizedPriority::High,
        Some("low") => NormalizedPriority::Low,
        _ => NormalizedPriority::Normal,
    };

    let mut actions: Vec<CommandAction> = vec![];
    for item in items {
        let (Some(kind), Some(value)) = (
            item.get("type").and_then(Value::as_str),
            item.get("value").and_then(Value::as_str),
        ) else {
            continue;
        };
        match kind {
            "open_app" => actions.push(CommandAction::OpenApp {
                name: alias::resolve(value),
            }),
            "close_app" => actions.push(CommandAction::CloseApp {
                name: alias::resolve(value),
            }),
            "open_url" => actions.push(CommandAction::OpenUrl {
                url: value.to_string(),
            }),
            "search_web" => actions.push(CommandAction::SearchWeb {
                query: value.to_string(),
            }),
            "open_folder" => actions.push(CommandAction::OpenFolder {
                path: value.to_string(),
            }),
            "create_file" => actions.push(CommandAction::CreateFile {
                name: value.to_string(),
            }),
            "create_folder" => actions.push(CommandAction::CreateFolder {
                name: value.to_string(),
            }),
            "media" => actions.push(CommandAction::Media {
                action: value.to_string(),
            }),
            "ai_query" => actions.push(CommandAction::AiQuery {
                query: value.to_string(),
            }),
            _ => {}
        }
    }

    if actions.is_empty() {
        return None;
    }
    let is_ai_query = actions
        .iter()
        .all(|a| matches!(a, CommandAction::AiQuery { .. }));
    Some(NormalizedCommand {
        priority,
        actions,
        is_ai_query,
        blocked: false,
        blocked_reason: None,
        raw: original.to_string(),
        prompt_chars: 0,
        response_chars: 0,
        error: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shape_a_multi_step_with_preamble() {
        let raw = r#"Sure! [{"type":"open_app","app":"Spotify"},{"type":"media","action":"play_song:Blinding Lights"}]"#;
        let actions = parse_shape_a(raw).expect("parsed");
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
    fn shape_a_media_specs() {
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
    fn shape_a_empty_or_garbage_is_none() {
        assert!(parse_shape_a("no json here").is_none());
        assert!(parse_shape_a("[]").is_none());
        assert!(parse_shape_a(r#"[{"type":"unknown"}]"#).is_none());
    }

    #[test]
    fn shape_b_priority_and_actions() {
        let raw = r#"{"priority":"high","actions":[{"type":"open_app","value":"Photos"},{"type":"open_url","value":"https://x.dev"}]}"#;
        let nc = parse_shape_b(raw, "open photos and x").expect("parsed");
        assert_eq!(nc.priority, NormalizedPriority::High);
        assert!(!nc.is_ai_query);
        assert_eq!(
            nc.actions,
            vec![
                CommandAction::OpenApp {
                    name: "Photos".to_string()
                },
                CommandAction::OpenUrl {
                    url: "https://x.dev".to_string()
                }
            ]
        );
    }

    #[test]
    fn shape_b_all_ai_marks_query() {
        let raw = r#"{"actions":[{"type":"ai_query","value":"what is rust"}]}"#;
        let nc = parse_shape_b(raw, "what is rust").expect("parsed");
        assert!(nc.is_ai_query);
        assert_eq!(nc.priority, NormalizedPriority::Normal);
    }

    #[test]
    fn shape_b_garbage_is_none() {
        assert!(parse_shape_b("nothing", "x").is_none());
        assert!(parse_shape_b(r#"{"actions":[]}"#, "x").is_none());
    }

    /// Live smoke test — needs `ollama serve` and the qwen2.5-coder model.
    /// Run with: `cargo test ollama_live -- --ignored --nocapture`
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
