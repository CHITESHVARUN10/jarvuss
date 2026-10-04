//! Audio capture via cpal (macOS CoreAudio only).
//!
//! cpal::Stream is not Send, so it lives in thread_local storage.
//! All FFI calls to start/stop recording come from the main thread.
//! Samples are accumulated in a shared Vec behind Arc<Mutex>.
//! Amplitude is stored as RMS bits in an AtomicU32.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::Stream;
use std::sync::{
    atomic::{AtomicU32, AtomicUsize, Ordering},
    Arc, Mutex, OnceLock,
};

/// Global handle to the ACTIVE recording buffer (Arc is Send+Sync).
/// Registered on capture start, cleared on stop. Lets the chunker thread
/// (which is not the main thread) snapshot windows without touching the
/// thread-local AudioCapture itself.
static ACTIVE_BUFFER: OnceLock<Mutex<Option<Arc<Mutex<Vec<f32>>>>>> = OnceLock::new();

/// Ring cap of the active capture, published on `start`. The pre-roll splice
/// must obey the exact same bound as the cpal callback's overflow guard.
static MAX_SAMPLES: AtomicUsize = AtomicUsize::new(16000 * 300);

fn active_buffer() -> &'static Mutex<Option<Arc<Mutex<Vec<f32>>>>> {
    ACTIVE_BUFFER.get_or_init(|| Mutex::new(None))
}

/// Prepend pre-roll samples (older audio from the Swift mic ring) to the
/// ACTIVE capture buffer, in front of what the stream has already collected.
/// The Swift side drops the portion of the pre-roll the stream already has,
/// so the caller's slice is exactly the missing span: [pre-roll] ++ [captured]
/// is gap-free and duplicate-free by construction.
///
/// Returns the number of pre-roll samples that survived the ring cap.
/// No-op (returns 0) when no recording is active — a late or spurious call
/// must never crash and never resurrect a finished buffer.
pub fn prepend_active(samples: &[f32]) -> usize {
    if samples.is_empty() {
        return 0;
    }
    let guard = match active_buffer().lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            tracing::error!("ACTIVE_BUFFER mutex poisoned on prepend — recovering");
            poisoned.into_inner()
        }
    };
    let Some(buf) = guard.as_ref() else {
        return 0; // no recording active
    };
    let mut data = match buf.lock() {
        Ok(data) => data,
        Err(poisoned) => {
            tracing::error!("audio buffer mutex poisoned on prepend — recovering");
            poisoned.into_inner()
        }
    };

    let max_samples = MAX_SAMPLES.load(Ordering::Relaxed);
    let total = data.len() + samples.len();
    let drop_front = total.saturating_sub(max_samples);
    let kept_preroll = samples.len().saturating_sub(drop_front);
    if kept_preroll == 0 {
        return 0;
    }

    let mut combined = Vec::with_capacity(total.min(max_samples));
    combined.extend_from_slice(&samples[drop_front..]);
    combined.extend_from_slice(&data);
    *data = combined;

    tracing::info!(
        injected = kept_preroll,
        buffer_len = data.len(),
        "Pre-roll prepended"
    );
    kept_preroll
}

/// Register the active buffer so other threads (chunker) can read windows.
pub fn register_buffer(buffer: Arc<Mutex<Vec<f32>>>) {
    match active_buffer().lock() {
        Ok(mut guard) => *guard = Some(buffer),
        Err(poisoned) => {
            tracing::error!("ACTIVE_BUFFER mutex poisoned on register — recovering");
            *poisoned.into_inner() = Some(buffer);
        }
    }
}

/// Clear the active buffer registration.
pub fn unregister_buffer() {
    match active_buffer().lock() {
        Ok(mut guard) => *guard = None,
        Err(poisoned) => {
            tracing::error!("ACTIVE_BUFFER mutex poisoned on unregister — recovering");
            *poisoned.into_inner() = None;
        }
    }
}

/// Non-destructive snapshot of the last `n` samples of the active buffer.
/// Returns (window, total_len). Empty when no recording is active.
pub fn tail_active(n: usize) -> (Vec<f32>, u64) {
    let guard = match active_buffer().lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            tracing::error!("ACTIVE_BUFFER mutex poisoned on tail — recovering");
            poisoned.into_inner()
        }
    };
    match guard.as_ref() {
        Some(buf) => {
            let data = match buf.lock() {
                Ok(data) => data,
                Err(poisoned) => {
                    tracing::error!("audio buffer mutex poisoned on tail — recovering");
                    poisoned.into_inner()
                }
            };
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
        MAX_SAMPLES.store(max_samples, Ordering::Relaxed);
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
                    // Audio callback: never panic here (would abort the app).
                    let mut buf = match buf_clone.lock() {
                        Ok(buf) => buf,
                        Err(poisoned) => poisoned.into_inner(),
                    };
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
        let mut buf = match self.buffer.lock() {
            Ok(buf) => buf,
            Err(poisoned) => poisoned.into_inner(),
        };
        std::mem::take(&mut *buf)
    }

    /// Non-destructive: returns the last `n` samples (the chunk window).
    /// Used by the chunker to snapshot a window while recording continues.
    pub fn tail_samples(&self, n: usize) -> Vec<f32> {
        let buf = match self.buffer.lock() {
            Ok(buf) => buf,
            Err(poisoned) => poisoned.into_inner(),
        };
        let start = buf.len().saturating_sub(n);
        buf[start..].to_vec()
    }

    /// Non-destructive: returns (last `n` samples, total buffer length).
    pub fn tail_samples_with_len(&self, n: usize) -> (Vec<f32>, u64) {
        let buf = match self.buffer.lock() {
            Ok(buf) => buf,
            Err(poisoned) => poisoned.into_inner(),
        };
        let start = buf.len().saturating_sub(n);
        (buf[start..].to_vec(), buf.len() as u64)
    }

    /// Mean RMS over an arbitrary slice — the silence gate in
    /// `stop_recording` / `chunker_thread` uses this to decide whether a
    /// clip is worth sending to Whisper at all. Display metering
    /// (`current_level`) is unchanged.
    pub fn rms(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum: f32 = samples.iter().map(|s| s * s).sum();
        (sum / samples.len() as f32).sqrt()
    }

    /// Fraction of 20 ms frames whose RMS clears `floor` — distinguishes a
    /// quiet-but-voiced utterance (many frames hot) from a breath/silence
    /// blip with one loud tick (few frames hot).
    pub fn voiced_fraction(samples: &[f32], floor: f32) -> f32 {
        const FRAME: usize = 320; // 20 ms @ 16 kHz
        if samples.len() < FRAME {
            return if Self::rms(samples) >= floor { 1.0 } else { 0.0 };
        }
        let frames = samples.len() / FRAME;
        let mut hot = 0usize;
        for i in 0..frames {
            let s = &samples[i * FRAME..(i + 1) * FRAME];
            if Self::rms(s) >= floor {
                hot += 1;
            }
        }
        hot as f32 / frames as f32
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Serializes tests that mutate the process-wide ACTIVE_BUFFER/MAX_SAMPLES.
    static PREPEND_TEST_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn prepend_orders_preroll_before_captured_audio() {
        let _guard = PREPEND_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let buffer = Arc::new(Mutex::new(vec![1.0, 2.0, 3.0]));
        register_buffer(buffer.clone());

        let injected = prepend_active(&[10.0, 11.0, 12.0]);
        assert_eq!(injected, 3);

        let data = buffer.lock().unwrap();
        // Pre-roll is OLDER audio: strictly before what the stream captured.
        assert_eq!(*data, vec![10.0, 11.0, 12.0, 1.0, 2.0, 3.0]);

        drop(data);
        unregister_buffer();
    }

    #[test]
    fn prepend_is_noop_without_active_recording() {
        let _guard = PREPEND_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        unregister_buffer();
        assert_eq!(prepend_active(&[1.0, 2.0]), 0);
    }

    #[test]
    fn prepend_clips_from_the_front_when_over_capacity() {
        let _guard = PREPEND_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let previous_max = MAX_SAMPLES.load(Ordering::Relaxed);
        MAX_SAMPLES.store(5, Ordering::Relaxed);

        let buffer = Arc::new(Mutex::new(vec![1.0, 2.0, 3.0]));
        register_buffer(buffer.clone());

        // total would be 8 > 5: the OLDEST pre-roll is clipped, never the
        // captured stream (the wake word lives in the pre-roll's tail).
        let injected = prepend_active(&[10.0, 11.0, 12.0, 13.0, 14.0]);
        assert_eq!(injected, 2);

        let data = buffer.lock().unwrap();
        assert_eq!(data.len(), 5);
        assert_eq!(*data, vec![13.0, 14.0, 1.0, 2.0, 3.0]);

        drop(data);
        unregister_buffer();
        MAX_SAMPLES.store(previous_max, Ordering::Relaxed);
    }
}
