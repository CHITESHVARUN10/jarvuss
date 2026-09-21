/// whisper-rs context and state management.
///
/// Wraps `WhisperContext` from whisper-rs, providing a higher-level
/// API for model lifecycle and inference.
///
/// Supports both whole-buffer transcription (`transcribe`) and live
/// incremental transcription (`transcribe_chunk`) with a persistent
/// `WhisperState` that carries context across chunks.
///
/// Optimized for short dictation: English only, greedy sampling,
/// no timestamps, no translation, no language detection.
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

pub struct InferenceEngine {
    model_path: PathBuf,
    context: Option<Arc<Mutex<whisper_rs::WhisperContext>>>,
    state: InferenceState,
    n_threads: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InferenceState {
    NotLoaded,
    Loading,
    Warming,
    Ready,
    Running,
    Error,
}

impl InferenceEngine {
    pub fn new(model_path: PathBuf, n_threads: i32) -> Self {
        Self { model_path, context: None, state: InferenceState::NotLoaded, n_threads }
    }

    pub fn load(&mut self) -> anyhow::Result<()> {
        if self.context.is_some() {
            tracing::info!("Model already loaded");
            return Ok(());
        }

        self.state = InferenceState::Loading;
        tracing::info!(model = %self.model_path.display(), "Loading whisper model");

        let start = std::time::Instant::now();

        if !self.model_path.exists() {
            anyhow::bail!("Model file not found: {}", self.model_path.display());
        }

        // macOS-only build: Metal is the single GPU path.
        let use_gpu = cfg!(feature = "metal");
        let ctx = whisper_rs::WhisperContext::new_with_params(
            &self.model_path.to_string_lossy(),
            whisper_rs::WhisperContextParameters { use_gpu, ..Default::default() },
        )?;

        let elapsed = start.elapsed();
        tracing::info!(duration_ms = elapsed.as_millis(), "Model loaded");

        self.context = Some(Arc::new(Mutex::new(ctx)));

        // Warm up
        self.state = InferenceState::Warming;
        self.warmup()?;

        self.state = InferenceState::Ready;
        Ok(())
    }

    fn warmup(&mut self) -> anyhow::Result<()> {
        let silence = vec![0.0f32; 16000];
        if let Ok(text) = self.transcribe_core(&silence) {
            tracing::info!(output = %text.trim(), "Warmup complete");
        }
        Ok(())
    }

    /// Whole-buffer transcription (fallback / warmup / short recordings).
    pub fn transcribe(&mut self, samples: &[f32]) -> anyhow::Result<String> {
        if self.context.is_none() {
            anyhow::bail!("Model not loaded");
        }

        self.state = InferenceState::Running;
        let start = std::time::Instant::now();
        let duration = samples.len() as f32 / 16000.0;

        tracing::info!(samples = samples.len(), duration_secs = %duration, "Starting inference");

        let result = self.transcribe_core(samples);

        let elapsed = start.elapsed();

        match &result {
            Ok(text) => {
                let rtf = elapsed.as_secs_f64() / duration as f64;
                tracing::info!(elapsed_ms = elapsed.as_millis(), rtf = %rtf, chars = text.len(), "Inference complete");
                self.state = InferenceState::Ready;
            }
            Err(e) => {
                self.state = InferenceState::Error;
                tracing::error!(?e, "Inference failed");
            }
        }

        result
    }

    /// Live chunk transcription.
    ///
    /// Each chunk gets a FRESH decode state — whisper decodes the chunk
    /// independently (no cross-chunk context, no persistent-state quirks).
    /// Overlapping audio is deduped textually by the worker (`dedupe_merge`).
    ///
    /// Returns `Some(text)` with the full chunk text, or `None` if empty.
    pub fn transcribe_chunk(&mut self, samples: &[f32]) -> anyhow::Result<Option<String>> {
        let ctx =
            self.context.as_ref().ok_or_else(|| anyhow::anyhow!("Context not loaded"))?.clone();

        let mut params =
            whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(self.n_threads);
        params.set_language(Some("en"));
        params.set_no_timestamps(true);

        self.state = InferenceState::Running;
        let start = std::time::Instant::now();

        let ctx_guard = ctx.lock().unwrap();
        let mut state = ctx_guard.create_state()?;
        state.full(params, samples)?;

        let total = state.full_n_segments()?;
        let mut text = String::new();
        let mut count = 0;
        for i in 0..total {
            if let Ok(seg_text) = state.full_get_segment_text(i) {
                text.push_str(&seg_text);
                count += 1;
            }
        }
        drop(state);
        drop(ctx_guard);

        let elapsed = start.elapsed();
        tracing::info!(
            elapsed_ms = elapsed.as_millis(),
            segments = count,
            chars = text.len(),
            "Chunk transcribed"
        );

        self.state = InferenceState::Ready;

        let trimmed = text.trim().to_string();
        if trimmed.is_empty() {
            Ok(None)
        } else {
            Ok(Some(trimmed))
        }
    }

    /// Drop the persistent decode state — start a fresh session.
    pub fn reset_decode_state(&mut self) {
        // No-op: chunks use fresh states; kept for API compatibility.
    }

    fn transcribe_core(&self, samples: &[f32]) -> anyhow::Result<String> {
        let ctx = self.context.as_ref().ok_or_else(|| anyhow::anyhow!("Context not loaded"))?;
        let ctx = ctx.lock().unwrap();

        let mut params =
            whisper_rs::FullParams::new(whisper_rs::SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(self.n_threads);
        params.set_language(Some("en"));

        let mut state = ctx.create_state()?;

        state.full(params, samples)?;

        let segment_count = state.full_n_segments()?;
        let mut transcript = String::new();

        for i in 0..segment_count {
            if let Ok(seg_text) = state.full_get_segment_text(i) {
                transcript.push_str(&seg_text);
            }
        }

        Ok(transcript.trim().to_string())
    }

    pub fn is_loaded(&self) -> bool {
        matches!(self.state, InferenceState::Ready | InferenceState::Running)
    }

    pub fn state(&self) -> InferenceState {
        self.state
    }

    pub fn unload(&mut self) {
        tracing::info!("Unloading model");
        self.context = None;
        self.state = InferenceState::NotLoaded;
    }
}
