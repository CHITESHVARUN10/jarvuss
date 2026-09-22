//! Static configuration for the Jarvis STT core.
//!
//! Deliberately simpler than a layered TOML setup: every tuning knob lives
//! here with proven defaults. Two runtime overrides:
//! - `JARVIS_STT_MODEL_DIR` — model directory
//! - `JARVIS_STT_IDLE_SECONDS` — idle unload timeout
//!
//! Model lifecycle contract (see lib.rs idle_watchdog):
//! mic stop / cancel NEVER unloads — only `idle_unload_seconds` of no
//! dictation activity unloads; the next use reloads transparently.
//!
//! The default model directory points at the already-installed AgentTalk
//! model (`ggml-large-v3-turbo.bin`, ~1.5 GB) so Jarvis reuses it in place
//! instead of downloading a duplicate.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    pub model: ModelSection,
    pub audio: AudioSection,
    pub inference: InferenceSection,
    pub features: FeaturesSection,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelSection {
    pub directory: String,
    pub filename: String,
    pub auto_download: bool,
    pub idle_unload_seconds: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioSection {
    pub sample_rate: u32,
    pub channels: u8,
    pub max_duration_seconds: u64,
    pub chunk_seconds: u32,
    pub chunk_overlap_seconds: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InferenceSection {
    pub n_threads: i32,
    pub language: String,
    pub sampling: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FeaturesSection {
    pub live_preview: bool,
}

impl AppConfig {
    /// Load config: compiled-in defaults, with the model directory
    /// overridable via `JARVIS_STT_MODEL_DIR` and the idle unload timeout
    /// via `JARVIS_STT_IDLE_SECONDS`.
    pub fn load() -> Self {
        let mut cfg = Self::default();
        if let Ok(dir) = std::env::var("JARVIS_STT_MODEL_DIR") {
            if !dir.trim().is_empty() {
                tracing::info!(dir = %dir, "Overriding STT model directory from JARVIS_STT_MODEL_DIR");
                cfg.model.directory = dir;
            }
        }
        if let Ok(secs) = std::env::var("JARVIS_STT_IDLE_SECONDS") {
            if let Ok(parsed) = secs.trim().parse::<u64>() {
                tracing::info!(parsed, "Overriding STT idle unload timeout from JARVIS_STT_IDLE_SECONDS");
                cfg.model.idle_unload_seconds = parsed;
            }
        }
        cfg
    }

    fn default_model_dir() -> String {
        if let Some(dir) = dirs::data_dir() {
            return dir.join("AgentTalk").join("models").to_string_lossy().to_string();
        }
        "~/Library/Application Support/AgentTalk/models".into()
    }

    pub fn default() -> Self {
        Self {
            model: ModelSection {
                directory: Self::default_model_dir(),
                filename: "ggml-large-v3-turbo.bin".into(),
                auto_download: true,
                // 5 min of no dictation activity → unload from RAM.
                // Mic stop / cancel never unloads (see cancel_recording).
                idle_unload_seconds: 300,
            },
            audio: AudioSection {
                sample_rate: 16000,
                channels: 1,
                max_duration_seconds: 300,
                // Command-mode VAD utterances are 2-8 s. 20 s windows meant
                // the first (and usually only) chunk arrived AFTER the user
                // had already stopped talking — i.e. live preview never
                // fired and short finals carried the whole buffer every
                // time. 6 s + 1 s overlap gives a real partial mid-utterance
                // and halves the tail-final tail work.
                chunk_seconds: 6,
                chunk_overlap_seconds: 1,
            },
            inference: InferenceSection {
                n_threads: 4,
                language: "en".into(),
                sampling: "greedy".into(),
            },
            // ON for command mode: forwards the non-final chunk stitch as
            // on_partial_transcript so the main window shows live text.
            // Pill-only consumers already gate on owner == .pill.
            features: FeaturesSection { live_preview: true },
        }
    }
}
