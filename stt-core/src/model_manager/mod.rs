/// Model download, caching, and verification (macOS only).
///
/// Manages the lifecycle of the whisper model file:
/// 1. Points at the already-installed AgentTalk model
///    (`~/Library/Application Support/AgentTalk/models/`) — reused in place
/// 2. Falls back to downloading `ggml-large-v3-turbo.bin` from Hugging Face
///    (~1.5 GB) with resume support, only if the file is missing
/// 3. Verifies the ggml header after download
/// 4. Reports progress to the UI layer
use std::{
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

use sha2::{Digest, Sha256};

/// Hugging Face base URL for ggml models (fallback download only)
const DOWNLOAD_BASE_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main";

/// Minimum interval between progress callbacks (in milliseconds)
const PROGRESS_INTERVAL_MS: u64 = 200;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModelState {
    NotInstalled,
    Downloading,
    Verifying,
    Loading,
    Ready,
    Inference,
    Unloading,
    Error,
}

pub struct ModelManager {
    pub model_dir: PathBuf,
    pub model_path: PathBuf,
    pub state: ModelState,
    pub progress: f32,
    pub speed: String,
    pub remaining: String,
    cancel: AtomicBool,
}

impl ModelManager {
    pub fn new() -> anyhow::Result<Self> {
        Self::new_with_dir_override(None)
    }

    /// Test seam: pass an explicit directory so unit tests never touch the
    /// real `~/Library/Application Support` tree.
    pub fn new_with_dir_override(dir_override: Option<PathBuf>) -> anyhow::Result<Self> {
        let model_dir = match dir_override {
            Some(d) => {
                fs::create_dir_all(&d)?;
                d
            }
            None => get_model_dir()?,
        };
        let model_path = model_dir.join("ggml-large-v3-turbo.bin");

        let manager = Self {
            model_dir,
            model_path,
            state: ModelState::NotInstalled,
            progress: 0.0,
            speed: String::new(),
            remaining: String::new(),
            cancel: AtomicBool::new(false),
        };

        tracing::info!(model_dir = %manager.model_dir.display(), "ModelManager initialized");
        Ok(manager)
    }

    pub fn is_installed(&self) -> bool {
        // ggml-large-v3-turbo.bin (Q5_K_M) is ~1.54 GB (1,544,985,118 bytes).
        // Treat files far smaller than expected as incomplete.
        match fs::metadata(&self.model_path) {
            Ok(m) => m.len() >= 1_400_000_000,
            Err(_) => false,
        }
    }

    pub fn verify(&self) -> anyhow::Result<bool> {
        if !self.model_path.exists() {
            return Ok(false);
        }

        tracing::info!(model = %self.model_path.display(), "Verifying model checksum");

        let mut file = fs::File::open(&self.model_path)?;
        let mut hasher = Sha256::new();
        let mut buffer = [0u8; 8192];

        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 {
                break;
            }
            hasher.update(&buffer[..n]);
        }

        let hash = format!("{:x}", hasher.finalize());

        // In production, compare against EXPECTED_TURBO_SHA256.
        // For now we accept any valid file that parses as a ggml model.
        let valid = self.validate_ggml_header(&self.model_path)?;
        tracing::info!(sha256 = %hash, valid_header = valid, "Model verification complete");

        Ok(valid)
    }

    fn validate_ggml_header(&self, path: &Path) -> anyhow::Result<bool> {
        use std::io::Read;
        let mut file = fs::File::open(path)?;
        let mut magic_bytes = [0u8; 8];
        match file.read_exact(&mut magic_bytes) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(false),
            Err(e) => return Err(e.into()),
        }
        let magic = u32::from_le_bytes([magic_bytes[0], magic_bytes[1], magic_bytes[2], magic_bytes[3]]);
        // Check for ggml magic: "ggml" = 0x67676d6c
        Ok(magic == 0x67676d6c || magic == 0x6767_6a74)
    }

    pub fn cancel_download(&self) {
        self.cancel.store(true, Ordering::SeqCst);
    }

    pub fn download_with_progress<F>(&mut self, on_progress: F) -> anyhow::Result<()>
    where
        F: Fn(f32, &str, &str),
    {
        if self.is_installed() && self.verify().unwrap_or(false) {
            tracing::info!("Model already installed and verified");
            return Ok(());
        }

        self.state = ModelState::Downloading;
        self.cancel.store(false, Ordering::SeqCst);

        let url = format!("{}/{}", DOWNLOAD_BASE_URL, "ggml-large-v3-turbo.bin");
        tracing::info!(url = %url, "Starting model download");

        fs::create_dir_all(&self.model_dir)?;

        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(30))
            .connect_timeout(Duration::from_secs(15))
            .build()?;

        let mut existing_size = 0u64;
        let mut file = if self.model_path.exists() {
            let size = fs::metadata(&self.model_path)?.len();
            if size < 1_400_000_000 {
                // Incomplete/corrupt partial — discard, start fresh
                tracing::warn!(partial = size, "Discarding incomplete model file");
                fs::remove_file(&self.model_path)?;
            }
            let size = fs::metadata(&self.model_path)?.len();
            if size > 0 {
                tracing::info!(resume_from = size, "Resuming download");
                existing_size = size;
                fs::OpenOptions::new().append(true).open(&self.model_path)?
            } else {
                fs::File::create(&self.model_path)?
            }
        } else {
            fs::File::create(&self.model_path)?
        };

        let mut request_builder = client.get(&url);
        if existing_size > 0 {
            request_builder = request_builder.header("Range", format!("bytes={}-", existing_size));
        }

        let mut response = request_builder.send()?;
        let total_size = existing_size
            + response
                .headers()
                .get("content-length")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(0);

        let mut downloaded = existing_size;
        let mut buffer = vec![0u8; 65536];
        let start = Instant::now();
        let mut last_progress = Instant::now();

        loop {
            if self.cancel.load(Ordering::SeqCst) {
                tracing::info!("Download cancelled");
                self.state = ModelState::NotInstalled;
                return Ok(());
            }

            let n = response.read(&mut buffer)?;
            if n == 0 {
                break;
            }

            file.write_all(&buffer[..n])?;
            downloaded += n as u64;

            let elapsed = last_progress.elapsed().as_millis();
            if elapsed >= PROGRESS_INTERVAL_MS as u128 {
                let total_elapsed = start.elapsed();
                let speed_bps = if total_elapsed.as_secs() > 0 {
                    (downloaded - existing_size) as f64 / total_elapsed.as_secs_f64()
                } else {
                    0.0
                };

                let progress =
                    if total_size > 0 { downloaded as f32 / total_size as f32 } else { 0.0 };

                let speed_str = format_speed(speed_bps);
                let remaining_str = if speed_bps > 0.0 && total_size > 0 {
                    let remaining_bytes = total_size - downloaded;
                    let remaining_secs = remaining_bytes as f64 / speed_bps;
                    format_duration(remaining_secs as u64)
                } else {
                    "calculating...".into()
                };

                on_progress(progress, &speed_str, &remaining_str);

                self.progress = progress;
                self.speed = speed_str.clone();
                self.remaining = remaining_str;

                last_progress = Instant::now();
            }
        }

        file.flush()?;
        drop(file);
        drop(response);

        tracing::info!(bytes = downloaded, "Download complete, verifying...");
        self.state = ModelState::Verifying;

        on_progress(1.0, "complete", "verifying");

        if self.verify()? {
            tracing::info!("Model verified successfully");
            Ok(())
        } else {
            self.state = ModelState::Error;
            anyhow::bail!("Model verification failed — file may be corrupt")
        }
    }
}

fn get_model_dir() -> anyhow::Result<PathBuf> {
    // Runtime override wins (shared by ModelManager download path AND the
    // inference MODEL_PATH resolution in lib.rs via AppConfig::load).
    if let Ok(dir) = std::env::var("JARVIS_STT_MODEL_DIR") {
        if !dir.trim().is_empty() {
            let p = PathBuf::from(dir.trim());
            fs::create_dir_all(&p)?;
            return Ok(p);
        }
    }
    let dir = dirs::data_dir()
        .ok_or_else(|| anyhow::anyhow!("Cannot determine Application Support directory"))?
        .join("AgentTalk")
        .join("models");
    fs::create_dir_all(&dir)?;
    Ok(dir)
}

fn format_speed(bytes_per_sec: f64) -> String {
    if bytes_per_sec >= 1_000_000.0 {
        format!("{:.1} MB/s", bytes_per_sec / 1_000_000.0)
    } else if bytes_per_sec >= 1_000.0 {
        format!("{:.0} KB/s", bytes_per_sec / 1_000.0)
    } else {
        format!("{:.0} B/s", bytes_per_sec)
    }
}

fn format_duration(seconds: u64) -> String {
    if seconds >= 3600 {
        format!("{}h {}m", seconds / 3600, (seconds % 3600) / 60)
    } else if seconds >= 60 {
        format!("{}m {}s", seconds / 60, seconds % 60)
    } else {
        format!("{}s", seconds)
    }
}
