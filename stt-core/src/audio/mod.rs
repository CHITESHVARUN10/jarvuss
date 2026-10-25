//! Audio capture via cpal (macOS CoreAudio only).
//!
//! A dedicated native thread owns the !Send stream and its lifecycle.
//! Swift FFI calls enqueue requests without blocking the UI.
//! Samples are accumulated in a shared Vec behind Arc<Mutex>.
//! Amplitude is stored as RMS bits in an AtomicU32.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Sample, Stream};
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
    failure: Arc<Mutex<Option<String>>>,
    max_samples: usize,
    last_buffer: Arc<Mutex<std::time::Instant>>,
}

impl AudioCapture {
    /// `max_seconds` — the recording ring-buffer cap (from config).
    pub fn start(max_seconds: u64) -> anyhow::Result<Self> {
        let host = cpal::default_host();
        let device =
            host.default_input_device().ok_or_else(|| anyhow::anyhow!("No input device found"))?;

        let device_name = device.name()?;
        tracing::info!(device = %device_name, "Opening audio input");

        // Open the native device format. Requesting 16 kHz on the device itself
        // can be unsupported or reconfigure the Swift/VAD stream (or another app).
        let supported = device.default_input_config()?;
        let sample_format = supported.sample_format();
        let config: cpal::StreamConfig = supported.into();
        anyhow::ensure!(config.channels > 0 && config.sample_rate.0 > 0, "Microphone has no usable input format");
        let max_samples = 16000 * crate::config::clamp_recording_seconds(max_seconds) as usize;
        MAX_SAMPLES.store(max_samples, Ordering::Relaxed);
        let buffer = Arc::new(Mutex::new(Vec::with_capacity(max_samples.min(16000 * 30))));
        let level = Arc::new(AtomicU32::new(0));
        let failure = Arc::new(Mutex::new(None));
        let last_buffer = Arc::new(Mutex::new(std::time::Instant::now()));
        macro_rules! build {
            ($ty:ty) => { build_stream::<$ty>(&device, &config, buffer.clone(), level.clone(), failure.clone(), last_buffer.clone(), max_samples)? };
        }
        let stream = match sample_format {
            cpal::SampleFormat::F32 => build!(f32),
            cpal::SampleFormat::F64 => build!(f64),
            cpal::SampleFormat::I8 => build!(i8),
            cpal::SampleFormat::I16 => build!(i16),
            cpal::SampleFormat::I32 => build!(i32),
            cpal::SampleFormat::I64 => build!(i64),
            cpal::SampleFormat::U8 => build!(u8),
            cpal::SampleFormat::U16 => build!(u16),
            cpal::SampleFormat::U32 => build!(u32),
            cpal::SampleFormat::U64 => build!(u64),
            other => anyhow::bail!("Unsupported microphone sample format: {other:?}"),
        };
        stream.play()?;
        register_buffer(buffer.clone());
        tracing::info!(max_seconds, rate = config.sample_rate.0, channels = config.channels, "Audio capture started");
        Ok(Self { stream, buffer, level, failure, max_samples, last_buffer })
    }

    pub fn sample_count(&self) -> usize {
        self.buffer.lock().unwrap_or_else(|p| p.into_inner()).len()
    }
    pub fn at_limit(&self) -> bool { self.sample_count() >= self.max_samples }
    pub fn failure(&self) -> Option<String> {
        let error = self.failure.lock().unwrap_or_else(|p| p.into_inner()).clone();
        if error.is_none() && self.last_buffer.lock().unwrap_or_else(|p| p.into_inner()).elapsed().as_secs() > 3 {
            return Some("Microphone input did not deliver audio. Check the input device and Retry.".into());
        }
        error
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
        // Quiesce callbacks before draining; otherwise the last buffer can
        // arrive after the drain and disappear from the final transcript.
        let Self { stream, buffer, .. } = self;
        drop(stream);
        unregister_buffer();
        let samples = std::mem::take(&mut *buffer.lock().unwrap_or_else(|p| p.into_inner()));
        tracing::info!(samples = samples.len(), "Audio capture stopped");
        samples
    }
}

/// Stateful interpolation keeps time continuous across callback boundaries,
/// including 44.1 kHz stereo devices. Whisper always receives mono 16 kHz.
struct InputResampler {
    rate: u32,
    channels: usize,
    index: u64,
    next_output: f64,
    previous: f32,
}

impl InputResampler {
    fn new(rate: u32, channels: usize) -> Self {
        Self { rate, channels, index: 0, next_output: 0.0, previous: 0.0 }
    }

    fn convert<T: cpal::Sample>(&mut self, data: &[T]) -> Vec<f32>
    where f32: cpal::FromSample<T> {
        let mut output = Vec::new();
        for frame in data.chunks_exact(self.channels) {
            let mono = frame.iter().map(|v| f32::from_sample(*v)).sum::<f32>() / self.channels as f32;
            let mono = if mono.is_finite() { mono } else { 0.0 };
            while self.next_output <= self.index as f64 {
                let value = if self.index == 0 { mono } else {
                    let fraction = (self.next_output - (self.index - 1) as f64) as f32;
                    self.previous + (mono - self.previous) * fraction
                };
                output.push(value);
                self.next_output += self.rate as f64 / 16000.0;
            }
            self.previous = mono;
            self.index += 1;
        }
        output
    }
}

fn append_bounded(buffer: &mut Vec<f32>, data: &[f32], max: usize) {
    // Keep the beginning. The owner stops at the sample limit; rolling the
    // ring invalidates the chunker's absolute offsets and silently loses text.
    let remaining = max.saturating_sub(buffer.len());
    buffer.extend_from_slice(&data[..data.len().min(remaining)]);
}

fn build_stream<T>(device: &cpal::Device, config: &cpal::StreamConfig,
    buffer: Arc<Mutex<Vec<f32>>>, level: Arc<AtomicU32>, failure: Arc<Mutex<Option<String>>>,
    last_buffer: Arc<Mutex<std::time::Instant>>, max_samples: usize) -> anyhow::Result<Stream>
where T: cpal::SizedSample, f32: cpal::FromSample<T> {
    let mut resampler = InputResampler::new(config.sample_rate.0, config.channels as usize);
    Ok(device.build_input_stream(config, move |data: &[T], _| {
        let samples = resampler.convert(data);
        if samples.is_empty() { return; }
        *last_buffer.lock().unwrap_or_else(|p| p.into_inner()) = std::time::Instant::now();
        let rms = AudioCapture::rms(&samples);
        level.store(rms.to_bits(), Ordering::Relaxed);
        append_bounded(&mut buffer.lock().unwrap_or_else(|p| p.into_inner()), &samples, max_samples);
    }, move |error| {
        tracing::error!(?error, "Microphone stream interrupted");
        *failure.lock().unwrap_or_else(|p| p.into_inner()) = Some(format!(
            "Microphone input was interrupted: {error}. Check the input device, stop any app using it exclusively, then Retry."));
    }, None)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_stereo_48khz_is_downmixed_and_resampled_for_whisper() {
        let input: Vec<f32> = (0..48000).flat_map(|_| [0.2, 0.6]).collect();
        let mut converter = InputResampler::new(48000, 2);
        let output = converter.convert(&input);
        assert_eq!(output.len(), 16000);
        assert!(output.iter().all(|v| (*v - 0.4).abs() < 0.0001));
    }

    #[test]
    fn resampling_44100_keeps_time_across_callback_boundaries() {
        let input: Vec<f32> = (0..44100).map(|n| (n as f32 * 0.01).sin()).collect();
        let expected = InputResampler::new(44100, 1).convert(&input);
        let mut converter = InputResampler::new(44100, 1);
        let actual: Vec<f32> = input.chunks(257).flat_map(|chunk| converter.convert(chunk)).collect();
        assert_eq!(actual.len(), 16000);
        assert_eq!(actual, expected);
    }

    #[test]
    fn integer_microphone_samples_are_normalized() {
        let output = InputResampler::new(16000, 1).convert(&[i16::MIN, 0, i16::MAX]);
        assert_eq!(output[0], -1.0);
        assert_eq!(output[1], 0.0);
        assert!(output[2] > 0.99 && output[2] <= 1.0);
    }

    #[test]
    fn oversized_callback_cannot_overflow_recording_ring() {
        let mut buffer = vec![1.0, 2.0];
        append_bounded(&mut buffer, &[3.0, 4.0, 5.0, 6.0], 3);
        assert_eq!(buffer, vec![1.0, 2.0, 3.0]);
        append_bounded(&mut buffer, &[7.0], 3);
        assert_eq!(buffer, vec![1.0, 2.0, 3.0]);
    }

    #[test]
    fn user_limits_above_five_minutes_are_not_clamped_to_the_old_cap() {
        for (requested, expected) in [(0, 60), (60, 60), (300, 300), (900, 900), (3600, 3600), (9999, 3600)] {
            assert_eq!(crate::config::clamp_recording_seconds(requested), expected);
        }
    }

    #[test]
    fn recording_buffer_keeps_every_sample_past_five_minutes_and_preserves_start_at_limit() {
        let limit = 16000 * 6 * 60;
        let mut buffer = Vec::new();
        for second in 0..(6 * 60 + 2) {
            append_bounded(&mut buffer, &vec![second as f32; 16000], limit);
        }
        assert_eq!(buffer.len(), limit);
        assert_eq!(buffer[0], 0.0);
        assert_eq!(buffer[16000 * 300], 300.0);
        assert_eq!(buffer.last(), Some(&359.0));
    }

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
