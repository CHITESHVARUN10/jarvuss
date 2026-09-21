//! End-to-end smoke test for the Jarvis STT core (dev only, not shipped).
//!
//! Loads the real Whisper model and transcribes a 16 kHz mono WAV file:
//! ```sh
//! say -v Samantha "Jarvis open Chrome" -o /tmp/utter.aiff
//! afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/utter.aiff /tmp/utter.wav
//! cargo run --example transcribe_file -- /tmp/utter.wav
//! ```

use std::path::PathBuf;

fn main() -> anyhow::Result<()> {
    let wav_path = std::env::args().nth(1).expect("usage: transcribe_file <file.wav>");

    let model_path: PathBuf = dirs::data_dir()
        .expect("no data dir")
        .join("AgentTalk")
        .join("models")
        .join("ggml-large-v3-turbo.bin");
    assert!(model_path.exists(), "model missing: {}", model_path.display());

    let mut reader = hound::WavReader::open(&wav_path)?;
    let spec = reader.spec();
    assert_eq!(spec.sample_rate, 16000, "expected 16 kHz, got {}", spec.sample_rate);
    assert_eq!(spec.channels, 1, "expected mono, got {}", spec.channels);
    let samples: Vec<f32> = reader
        .samples::<i16>()
        .map(|s| s.expect("sample read") as f32 / 32768.0)
        .collect();
    println!("read {} samples ({:.2}s)", samples.len(), samples.len() as f32 / 16000.0);

    let mut engine =
        jarvis_stt::inference::engine::InferenceEngine::new(model_path, 4);
    engine.load()?;
    let text = engine.transcribe(&samples)?;
    println!("TRANSCRIPT: '{text}'");

    let lower = text.to_lowercase();
    assert!(lower.contains("chrome"), "expected 'chrome' in transcript, got: '{text}'");
    assert!(lower.contains("jarvis"), "expected 'jarvis' in transcript, got: '{text}'");
    println!("E2E STT OK");
    Ok(())
}
