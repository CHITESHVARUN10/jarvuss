//! Audio capture via cpal (macOS CoreAudio only).
//!
//! cpal::Stream is not Send, so it lives in thread_local storage.
//! All FFI calls to start/stop recording come from the main thread.
//! Samples are accumulated in a shared Vec behind Arc<Mutex>.
//! Amplitude is stored as RMS bits in an AtomicU32.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::Stream;
use std::sync::{
    atomic::{AtomicU32, Ordering},
    Arc, Mutex, OnceLock,
};

/// Global handle to the ACTIVE recording buffer (Arc is Send+Sync).
/// Registered on capture start, cleared on stop. Lets the chunker thread
/// (which is not the main thread) snapshot windows without touching the
/// thread-local AudioCapture itself.
static ACTIVE_BUFFER: OnceLock<Mutex<Option<Arc<Mutex<Vec<f32>>>>>> = OnceLock::new();

fn active_buffer() -> &'static Mutex<Option<Arc<Mutex<Vec<f32>>>>> {
    ACTIVE_BUFFER.get_or_init(|| Mutex::new(None))
}

/// Register the active buffer so other threads (chunker) can read windows.
pub fn register_buffer(buffer: Arc<Mutex<Vec<f32>>>) {
    *active_buffer().lock().unwrap() = Some(buffer);
}

/// Clear the active buffer registration.
pub fn unregister_buffer() {
    *active_buffer().lock().unwrap() = None;
}

/// Non-destructive snapshot of the last `n` samples of the active buffer.
/// Returns (window, total_len). Empty when no recording is active.
pub fn tail_active(n: usize) -> (Vec<f32>, u64) {
    let guard = active_buffer().lock().unwrap();
    match guard.as_ref() {
        Some(buf) => {
            let data = buf.lock().unwrap();
            let start = data.len().saturating_sub(n);
            (data[start..].to_vec(), data.len() as u64)
        }
        None => (Vec::new(), 0),
    }
}

pub struct AudioCapture {
    stream: Stream,
    buffer: Arc<Mutex<Vec<f32>>>,
    level: Arc<AtomicU32>,
}

impl AudioCapture {
    /// `max_seconds` — the recording ring-buffer cap (from config).
    pub fn start(max_seconds: u64) -> anyhow::Result<Self> {
        let host = cpal::default_host();
        let device =
            host.default_input_device().ok_or_else(|| anyhow::anyhow!("No input device found"))?;

        let device_name = device.name()?;
        tracing::info!(device = %device_name, "Opening audio input");

        let config: cpal::StreamConfig = cpal::StreamConfig {
            channels: 1,
            sample_rate: cpal::SampleRate(16000),
            buffer_size: cpal::BufferSize::Default,
        };

        let max_samples = 16000 * max_seconds as usize;
        let buffer = Arc::new(Mutex::new(Vec::with_capacity(max_samples)));
        let level = Arc::new(AtomicU32::new(0));

        let buf_clone = buffer.clone();
        let lvl_clone = level.clone();

        let err_fn = |err| {
            tracing::error!(?err, "Audio stream error");
        };

        let stream = device.build_input_stream(
            &config,
            {
                let buf_clone = buf_clone.clone();
                let lvl_clone = lvl_clone.clone();
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    let mut buf = buf_clone.lock().unwrap();
                    if buf.len() + data.len() > max_samples {
                        let excess = (buf.len() + data.len()) - max_samples;
                        if excess < buf.len() {
                            buf.drain(..excess);
                        }
                    }
                    buf.extend_from_slice(data);

                    let sum: f32 = data.iter().map(|s| s * s).sum();
                    let rms = (sum / data.len() as f32).sqrt();
                    lvl_clone.store(rms.to_bits(), Ordering::Relaxed);
                }
            },
            err_fn,
            None,
        )?;


        stream.play()?;
        tracing::info!(max_seconds, "Audio capture started");

        // Make the buffer visible to other threads (chunker).
        register_buffer(buffer.clone());

        Ok(Self { stream, buffer, level })
    }

    pub fn drain_samples(&self) -> Vec<f32> {
        let mut buf = self.buffer.lock().unwrap();
        std::mem::take(&mut *buf)
    }

    /// Non-destructive: returns the last `n` samples (the chunk window).
    /// Used by the chunker to snapshot a window while recording continues.
    pub fn tail_samples(&self, n: usize) -> Vec<f32> {
        let buf = self.buffer.lock().unwrap();
        let start = buf.len().saturating_sub(n);
        buf[start..].to_vec()
    }

    /// Non-destructive: returns (last `n` samples, total buffer length).
    pub fn tail_samples_with_len(&self, n: usize) -> (Vec<f32>, u64) {
        let buf = self.buffer.lock().unwrap();
        let start = buf.len().saturating_sub(n);
        (buf[start..].to_vec(), buf.len() as u64)
    }

    pub fn current_level(&self) -> f32 {
        let bits = self.level.load(Ordering::Relaxed);
        let rms = f32::from_bits(bits);
        (rms / 0.12).min(1.0)
    }

    pub fn stop(self) -> Vec<f32> {
        unregister_buffer();
        let samples = self.drain_samples();
        drop(self.stream);
        tracing::info!(samples = samples.len(), "Audio capture stopped");
        samples
    }
}
