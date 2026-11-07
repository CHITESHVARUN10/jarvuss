//! Native voice compatibility engine, validated against the Python reference
//! before packaging. Same model and audio policy; no training.
use crate::native_intent::environment;
use ort::{
    session::{
        builder::{AutoDevicePolicy, GraphOptimizationLevel},
        Session,
    },
    value::Tensor,
};
use rustfft::{num_complex::Complex, FftPlanner};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{fs, io::Cursor, path::Path};
type Result<T> = std::result::Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
#[derive(Deserialize)]
struct Frontend {
    mel_filters: Vec<Vec<f32>>,
    window: Vec<f64>,
}
pub struct VoiceEngine {
    session: Session,
    frontend: Frontend,
    audio: crate::native_audio::AudioLibraries,
}
impl VoiceEngine {
    pub fn load(model: &Path, runtime: &Path) -> Result<Self> {
        let frontend: Frontend =
            serde_json::from_slice(&fs::read(model.join("audio_frontend.json")).map_err(err)?)
                .map_err(err)?;
        if frontend.mel_filters.len() != 40
            || frontend.mel_filters.iter().any(|v| v.len() != 201)
            || frontend.window.len() != 400
        {
            return Err("invalid frontend coefficients".into());
        }
        let session = Session::builder(environment(runtime)?)
            .map_err(err)?
            .with_auto_device(AutoDevicePolicy::PreferCPU)
            .map_err(err)?
            .with_optimization_level(GraphOptimizationLevel::All)
            .map_err(err)?
            .with_intra_threads(5)
            .map_err(err)?
            .commit_from_file(model.join("speaker_encoder.onnx"))
            .map_err(err)?;
        Ok(Self {
            session,
            frontend,
            audio: crate::native_audio::AudioLibraries::load(model)?,
        })
    }
    pub fn embed(&mut self, audio: &[u8]) -> Result<Value> {
        let raw = self.audio.decode(audio)?;
        let prepared = prepare(&raw)?;
        let starts = partial_starts(prepared.len());
        let mut padded = prepared.clone();
        let needed = *starts.last().ok_or("missing audio slices")? * 160 + 25600;
        if padded.len() < needed {
            padded.resize(needed, 0.0);
        }
        let mel = self.mel(&padded);
        let frames = mel.len() / 40;
        let mut input = Vec::with_capacity(starts.len() * 160 * 40);
        for start in &starts {
            if start + 160 > frames {
                return Err("invalid mel slice".into());
            }
            input.extend_from_slice(&mel[start * 40..(start + 160) * 40]);
        }
        let output=self.session.run(ort::inputs!["mels"=>Tensor::from_array(([starts.len(),160,40],input)).map_err(err)?]).map_err(err)?;
        let value = output.get("embeddings").ok_or("missing voice embeddings")?;
        let (shape, partials) = value.try_extract_tensor::<f32>().map_err(err)?;
        if shape.as_ref() != [starts.len() as i64, 256] {
            return Err("invalid voice embedding shape".into());
        }
        let mut embedding = vec![0f32; 256];
        for partial in partials.chunks_exact(256) {
            for (sum, value) in embedding.iter_mut().zip(partial) {
                *sum += value;
            }
        }
        for value in &mut embedding {
            *value /= starts.len() as f32;
        }
        let norm = embedding.iter().map(|v| v * v).sum::<f32>().sqrt();
        if !norm.is_finite() || norm == 0.0 {
            return Err("invalid voice embedding".into());
        }
        for value in &mut embedding {
            *value /= norm;
        }
        Ok(
            json!({"embedding":embedding,"prepared_samples":prepared.len(),"partial_starts":starts,"mel_frames":frames}),
        )
    }
    fn mel(&self, wav: &[f32]) -> Vec<f32> {
        // librosa STFT: centered zero padding, periodic Hann, n_fft400/hop160,
        // float64 window/FFT followed by complex64 and float32 power/mel.
        let frames = 1 + wav.len() / 160;
        let mut out = Vec::with_capacity(frames * 40);
        let fft = FftPlanner::<f64>::new().plan_fft_forward(400);
        let mut buffer = vec![Complex::new(0.0, 0.0); 400];
        for frame in 0..frames {
            for (i, item) in buffer.iter_mut().enumerate() {
                let pos = frame as isize * 160 + i as isize - 200;
                let sample = if pos >= 0 {
                    wav.get(pos as usize).copied().unwrap_or(0.0)
                } else {
                    0.0
                };
                *item = Complex::new(f64::from(sample) * self.frontend.window[i], 0.0);
            }
            fft.process(&mut buffer);
            let power: Vec<_> = buffer[..201]
                .iter()
                .map(|v| (v.re as f32).hypot(v.im as f32).powi(2))
                .collect();
            for filter in &self.frontend.mel_filters {
                out.push(filter.iter().zip(&power).map(|(a, b)| a * b).sum());
            }
        }
        out
    }
}
pub fn decode_wav(audio: &[u8]) -> Result<Vec<f32>> {
    if audio.is_empty() || audio.len() > 10 * 1024 * 1024 {
        return Err("audio exceeds allowed size".into());
    }
    let mut wav = hound::WavReader::new(Cursor::new(audio)).map_err(err)?;
    let spec = wav.spec();
    if spec.sample_rate != 16000 || spec.channels != 1 {
        return Err("unsupported_audio_format".into());
    }
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => wav
            .samples::<f32>()
            .map(|v| v.map_err(err))
            .collect::<Result<_>>()?,
        hound::SampleFormat::Int => {
            let scale = 2f32.powi(i32::from(spec.bits_per_sample) - 1);
            wav.samples::<i32>()
                .map(|v| v.map(|n| n as f32 / scale).map_err(err))
                .collect::<Result<_>>()?
        }
    };
    if samples.iter().any(|v| !v.is_finite()) {
        return Err("invalid audio samples".into());
    }
    Ok(samples)
}
pub fn prepare(raw: &[f32]) -> Result<Vec<f32>> {
    if raw.len() < 480 {
        return Err("audio is too short".into());
    }
    let mut wav = raw.to_vec();
    let rms = (wav.iter().map(|v| (v * 32767.0).powi(2)).sum::<f32>() / wav.len() as f32).sqrt();
    if rms == 0.0 {
        return Err("silent audio".into());
    }
    let db = 20.0 * (rms / 32767.0).log10();
    let change = -30.0 - db;
    if change >= 0.0 {
        let gain = 10f32.powf(change / 20.0);
        for v in &mut wav {
            *v *= gain;
        }
    }
    wav.truncate(wav.len() / 480 * 480);
    let mut vad = webrtc_vad::Vad::new_with_rate_and_mode(
        webrtc_vad::SampleRate::Rate16kHz,
        webrtc_vad::VadMode::VeryAggressive,
    );
    let mut flags = Vec::new();
    for frame in wav.chunks_exact(480) {
        let pcm: Vec<i16> = frame
            .iter()
            .map(|v| {
                let n = (v * 32767.0).round_ties_even();
                (n as i64) as i16
            })
            .collect();
        flags.push(
            vad.is_voice_segment(&pcm)
                .map_err(|_| "voice detection failed")?,
        );
    }
    let mut mask = vec![false; flags.len()];
    for (i, item) in mask.iter_mut().enumerate() {
        let voiced = (i as isize - 3..=i as isize + 4)
            .filter(|j| *j >= 0 && flags.get(*j as usize) == Some(&true))
            .count();
        *item = voiced > 4;
    }
    let dilated: Vec<bool> = (0..mask.len())
        .map(|i| {
            (i as isize - 3..=i as isize + 3).any(|j| j >= 0 && mask.get(j as usize) == Some(&true))
        })
        .collect();
    wav = wav
        .chunks_exact(480)
        .zip(dilated)
        .filter(|(_, keep)| *keep)
        .flat_map(|(frame, _)| frame.iter().copied())
        .collect();
    if wav.is_empty() {
        return Err("no voiced audio".into());
    }
    let mut start = 0;
    let mut end = wav.len();
    if wav.len() > 1024 {
        for i in (0..wav.len() - 1024).step_by(1024) {
            let rms = (wav[i..i + 1024].iter().map(|v| v * v).sum::<f32>() / 1024.0).sqrt();
            if rms > 0.01 {
                start = i.saturating_sub(1024);
                break;
            }
        }
        let mut i = wav.len() - 1024;
        while i > 0 {
            let rms = (wav[i..i + 1024].iter().map(|v| v * v).sum::<f32>() / 1024.0).sqrt();
            if rms > 0.01 {
                end = (i + 2048).min(wav.len());
                break;
            }
            if i < 1024 {
                break;
            }
            i -= 1024;
        }
    }
    if end > start && end - start > 4000 {
        wav = wav[start..end].to_vec();
    }
    let peak = wav.iter().map(|v| v.abs()).fold(0.0f32, f32::max);
    if peak > 0.0 {
        for v in &mut wav {
            *v /= peak;
        }
    }
    Ok(wav)
}
pub fn partial_starts(samples: usize) -> Vec<usize> {
    let frames = (samples + 1).div_ceil(160);
    let steps = frames
        .saturating_add(77)
        .saturating_add(1)
        .saturating_sub(160)
        .max(1);
    let mut starts: Vec<_> = (0..steps).step_by(77).collect();
    let last = *starts.last().unwrap();
    let coverage = (samples as f64 - last as f64 * 160.0) / 25600.0;
    if coverage < 0.75 && starts.len() > 1 {
        starts.pop();
    }
    starts
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn short_and_silent_rejected() {
        assert!(prepare(&[]).is_err());
        assert!(prepare(&vec![0.0; 16000]).is_err());
        assert!(decode_wav(b"not a wave").is_err());
    }
    #[test]
    fn slices_match_reference_boundaries() {
        assert_eq!(partial_starts(0), vec![0]);
        assert_eq!(partial_starts(25600), vec![0]);
        assert_eq!(partial_starts(48000), vec![0, 77, 154]);
    }
}
