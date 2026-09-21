//! Session state machine — the single source of truth for the dictation lifecycle.

use crate::{config::AppConfig, model_manager::ModelState};
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionPhase {
    Idle,
    Preparing,
    Ready,
    Recording,
    Processing,
    TranscriptReady,
    Error,
}

impl SessionPhase {
    pub fn can_record(&self) -> bool {
        matches!(self, SessionPhase::Ready)
    }

    pub fn can_stop(&self) -> bool {
        matches!(self, SessionPhase::Recording)
    }

    pub fn can_retry(&self) -> bool {
        matches!(self, SessionPhase::TranscriptReady | SessionPhase::Error)
    }

    pub fn can_dismiss(&self) -> bool {
        matches!(self, SessionPhase::TranscriptReady | SessionPhase::Error)
    }
}

pub struct AppStateMachine {
    pub phase: SessionPhase,
    pub model_state: ModelState,
    pub download_progress: f32,
    pub download_speed: String,
    pub download_remaining: String,
    pub transcript: Option<String>,
    pub audio_level: f32,
    pub recording_duration_ms: u64,
    pub error_message: Option<String>,
    pub config: AppConfig,
    pub audio_samples: Option<Vec<f32>>,
    recording_start: Option<Instant>,
    is_recording: bool,
}

impl AppStateMachine {
    pub fn new(config: AppConfig) -> Self {
        Self {
            phase: SessionPhase::Idle,
            model_state: ModelState::NotInstalled,
            download_progress: 0.0,
            download_speed: String::new(),
            download_remaining: String::new(),
            transcript: None,
            audio_level: 0.0,
            recording_duration_ms: 0,
            error_message: None,
            config,
            audio_samples: None,
            recording_start: None,
            is_recording: false,
        }
    }

    pub fn transition(&mut self, to: SessionPhase) {
        tracing::info!(from = ?self.phase, to = ?to, "State transition");
        self.phase = to;
    }

    pub fn set_model_state(&mut self, state: ModelState) {
        self.model_state = state;
    }

    pub fn set_download_progress(&mut self, progress: f32, speed: String, remaining: String) {
        self.download_progress = progress;
        self.download_speed = speed;
        self.download_remaining = remaining;
    }

    pub fn begin_recording(&mut self) -> anyhow::Result<()> {
        if !self.phase.can_record() {
            anyhow::bail!("Cannot start recording in phase {:?}", self.phase);
        }
        self.is_recording = true;
        self.recording_start = Some(Instant::now());
        self.transcript = None;
        self.error_message = None;
        self.audio_samples = Some(Vec::new());
        self.transition(SessionPhase::Recording);
        Ok(())
    }

    pub fn append_samples(&mut self, samples: &[f32]) {
        if self.is_recording {
            if let Some(ref mut buf) = self.audio_samples {
                buf.extend_from_slice(samples);
            }
        }
    }

    pub fn finish_recording(&mut self) -> anyhow::Result<Vec<f32>> {
        if !self.phase.can_stop() {
            anyhow::bail!("Not currently recording");
        }
        self.is_recording = false;
        let samples = self.audio_samples.take().unwrap_or_default();
        if let Some(ref start) = self.recording_start {
            self.recording_duration_ms = start.elapsed().as_millis() as u64;
        }
        self.recording_start = None;
        self.transition(SessionPhase::Processing);
        Ok(samples)
    }

    pub fn set_transcript(&mut self, text: String) {
        self.transcript = Some(text);
        self.transition(SessionPhase::TranscriptReady);
    }

    pub fn set_error(&mut self, msg: String) {
        self.error_message = Some(msg);
        self.transition(SessionPhase::Error);
    }

    pub fn set_audio_level(&mut self, level: f32) {
        self.audio_level = level;
    }

    pub fn dismiss(&mut self) {
        self.transcript = None;
        self.error_message = None;
        self.transition(SessionPhase::Ready);
    }

    pub fn retry(&mut self) {
        self.transcript = None;
        self.error_message = None;
        self.transition(SessionPhase::Ready);
    }
}
