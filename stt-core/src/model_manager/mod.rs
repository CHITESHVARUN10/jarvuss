/// Model download, caching, and verification (macOS only).
///
/// Manages the lifecycle of the whisper model file:
/// 1. Points at the already-installed AgentTalk model
///    (`~/Library/Application Support/AgentTalk/models/`) — reused in place
/// 2. Falls back to downloading `ggml-large-v3-turbo.bin` from Hugging Face
///    (~1.5 GB) with resume support, only if the file is missing
/// 3. Verifies the pinned size, SHA-256, and ggml header before publishing
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
// Upstream LFS metadata for this exact revision (not the CDN's Xet object hash).
// https://huggingface.co/ggerganov/whisper.cpp/blob/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin
const MODEL_URL: &str = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo.bin";
const MODEL_BYTES: u64 = 1_624_555_275;
const MODEL_SHA256: &str = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69";
const RANGE_BYTES: u64 = 8 * 1024 * 1024;

struct ModelSpec { url: String, bytes: u64, sha256: String }

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
    spec: ModelSpec,
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
            spec: ModelSpec { url: MODEL_URL.into(), bytes: MODEL_BYTES, sha256: MODEL_SHA256.into() },
        };

        tracing::info!(model_dir = %manager.model_dir.display(), "ModelManager initialized");
        Ok(manager)
    }

    /// Cheap presence check; startup calls verify before reporting Ready.
    pub fn is_installed(&self) -> bool {
        fs::metadata(&self.model_path).map(|m| m.len() == self.spec.bytes).unwrap_or(false)
    }

    pub fn verify(&self) -> anyhow::Result<bool> { self.verify_path(&self.model_path) }

    fn verify_path(&self, path: &Path) -> anyhow::Result<bool> {
        if !path.exists() || fs::metadata(path)?.len() != self.spec.bytes { return Ok(false); }
        if !self.validate_ggml_header(path)? { return Ok(false); }
        let mut file = fs::File::open(path)?;
        let mut hasher = Sha256::new();
        let mut buffer = vec![0u8; 1024 * 1024];
        loop {
            let n = file.read(&mut buffer)?;
            if n == 0 { break; }
            hasher.update(&buffer[..n]);
        }
        Ok(format!("{:x}", hasher.finalize()) == self.spec.sha256)
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
    where F: Fn(f32, &str, &str),
    {
        let result = self.download(&on_progress);
        if result.is_err() { self.state = ModelState::Error; }
        result
    }

    fn download<F>(&mut self, on_progress: &F) -> anyhow::Result<()>
    where F: Fn(f32, &str, &str),
    {
        self.cancel.store(false, Ordering::SeqCst);
        self.state = ModelState::Verifying;
        if self.verify()? {
            self.state = ModelState::Ready;
            self.progress = 1.0;
            return Ok(());
        }
        fs::create_dir_all(&self.model_dir)?;
        let partial = self.model_path.with_extension("bin.part");
        if self.model_path.exists() {
            // Adopt legacy partials once; preserve invalid completed files for
            // diagnosis rather than silently deleting another app's model.
            if !partial.exists() && fs::metadata(&self.model_path)?.len() < self.spec.bytes {
                fs::rename(&self.model_path, &partial)?;
            } else { quarantine(&self.model_path)?; }
        }
        if partial.exists() && fs::metadata(&partial)?.len() >= self.spec.bytes {
            if self.verify_path(&partial)? {
                fs::rename(&partial, &self.model_path)?;
                self.state = ModelState::Ready;
                self.progress = 1.0;
                return Ok(());
            }
            fs::remove_file(&partial)?;
        }

        // Bounded Range requests allow slow links to make durable progress;
        // the deadline applies to each 8 MiB request, not the whole model.
        let client = reqwest::blocking::Client::builder()
            .timeout(Duration::from_secs(300)).connect_timeout(Duration::from_secs(15)).build()?;
        let mut downloaded = fs::metadata(&partial).map(|m| m.len()).unwrap_or(0);
        let initial_size = downloaded;
        let start = Instant::now();
        let mut last_progress = Instant::now();
        self.state = ModelState::Downloading;
        while downloaded < self.spec.bytes {
            if self.cancel.load(Ordering::SeqCst) { anyhow::bail!("Model download cancelled; partial retained"); }
            let end = (downloaded + RANGE_BYTES - 1).min(self.spec.bytes - 1);
            let mut response = client.get(&self.spec.url)
                .header("Range", format!("bytes={downloaded}-{end}"))
                .header("Accept-Encoding", "identity").send()?;
            let status = response.status().as_u16();
            let mut reset = false;
            let expected_body = match status {
                206 => {
                    let range = response.headers().get("content-range")
                        .and_then(|v| v.to_str().ok()).ok_or_else(|| anyhow::anyhow!("Missing Content-Range"))?;
                    let (first, last, total) = parse_range(range)?;
                    anyhow::ensure!(first == downloaded && last <= end && total == self.spec.bytes,
                        "Unexpected model Content-Range");
                    last - first + 1
                }
                200 => {
                    // A server ignoring Range sends a complete object. Restart
                    // safely instead of appending a second model to the partial.
                    anyhow::ensure!(response.content_length() == Some(self.spec.bytes), "Unexpected model response size");
                    reset = true;
                    self.spec.bytes
                }
                _ => anyhow::bail!("Model server returned HTTP {status}; partial retained"),
            };
            if let Some(length) = response.content_length() {
                anyhow::ensure!(length == expected_body, "Model response length disagrees with Content-Range");
            }
            let mut file = fs::OpenOptions::new().create(true).append(true).open(&partial)?;
            if reset { file.set_len(0)?; downloaded = 0; }
            let mut received = 0;
            let mut buffer = [0u8; 65536];
            loop {
                if self.cancel.load(Ordering::SeqCst) { anyhow::bail!("Model download cancelled; partial retained"); }
                let n = response.read(&mut buffer)?;
                if n == 0 { break; }
                anyhow::ensure!(received + n as u64 <= expected_body, "Model body exceeds declared range");
                file.write_all(&buffer[..n])?;
                received += n as u64;
                downloaded += n as u64;
                if last_progress.elapsed().as_millis() >= PROGRESS_INTERVAL_MS as u128 {
                    let speed = downloaded.saturating_sub(initial_size) as f64 / start.elapsed().as_secs_f64().max(0.001);
                    self.progress = downloaded as f32 / self.spec.bytes as f32;
                    self.speed = format_speed(speed);
                    self.remaining = format_duration(((self.spec.bytes - downloaded) as f64 / speed.max(1.0)) as u64);
                    on_progress(self.progress, &self.speed, &self.remaining);
                    last_progress = Instant::now();
                }
            }
            file.sync_data()?;
            anyhow::ensure!(received == expected_body, "Incomplete model response; partial retained for resume");
        }
        self.state = ModelState::Verifying;
        on_progress(1.0, "complete", "verifying");
        if !self.verify_path(&partial)? {
            fs::remove_file(&partial)?;
            anyhow::bail!("Model SHA-256 verification failed; retry to download a fresh copy");
        }
        fs::rename(&partial, &self.model_path)?;
        self.progress = 1.0;
        self.state = ModelState::Ready;
        Ok(())
    }
}

fn parse_range(value: &str) -> anyhow::Result<(u64, u64, u64)> {
    let value = value.strip_prefix("bytes ").ok_or_else(|| anyhow::anyhow!("Invalid Content-Range unit"))?;
    let (interval, total) = value.split_once('/').ok_or_else(|| anyhow::anyhow!("Invalid Content-Range"))?;
    let (first, last) = interval.split_once('-').ok_or_else(|| anyhow::anyhow!("Invalid Content-Range bounds"))?;
    let (first, last, total) = (first.parse::<u64>()?, last.parse::<u64>()?, total.parse::<u64>()?);
    anyhow::ensure!(first <= last && last < total, "Invalid Content-Range bounds");
    Ok((first, last, total))
}

fn quarantine(path: &Path) -> anyhow::Result<()> {
    let suffix = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos();
    fs::rename(path, path.with_extension(format!("invalid-{suffix}")))?;
    Ok(())
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{TcpListener, TcpStream};
    use std::thread;

    fn bytes() -> Vec<u8> {
        let mut bytes = vec![42; 1024];
        bytes[..4].copy_from_slice(&0x67676d6cu32.to_le_bytes());
        bytes
    }

    fn fixture(url: String) -> (ModelManager, PathBuf) {
        let dir = std::env::temp_dir().join(format!("jarvis-model-{}-{}", std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        let mut manager = ModelManager::new_with_dir_override(Some(dir.clone())).unwrap();
        manager.spec = ModelSpec { url, bytes: 1024, sha256: format!("{:x}", Sha256::digest(bytes())) };
        (manager, dir)
    }

    fn response(status: &str, headers: &str, body: &[u8]) -> Vec<u8> {
        let mut data = format!("HTTP/1.1 {status}\r\nConnection: close\r\n{headers}\r\n").into_bytes();
        data.extend_from_slice(body);
        data
    }

    fn server(responses: Vec<Vec<u8>>) -> (String, thread::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/model.bin", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let handle = thread::spawn(move || {
            let mut requests = Vec::new();
            for response in responses {
                let deadline = Instant::now() + Duration::from_secs(5);
                let mut stream: TcpStream = loop {
                    if let Ok((stream, _)) = listener.accept() { break stream; }
                    assert!(Instant::now() < deadline, "model client never connected");
                    thread::sleep(Duration::from_millis(10));
                };
                stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") && request.len() < 16384 {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                }
                requests.push(String::from_utf8(request).unwrap());
                stream.write_all(&response).unwrap();
            }
            requests
        });
        (url, handle)
    }

    #[test]
    fn resumes_legacy_partial_and_publishes_only_verified_model() {
        let body = bytes();
        let (url, server) = server(vec![response("206 Partial Content",
            "Content-Range: bytes 8-1023/1024\r\nContent-Length: 1016\r\n", &body[8..])]);
        let (mut manager, dir) = fixture(url);
        fs::write(&manager.model_path, &body[..8]).unwrap();
        manager.download_with_progress(|_, _, _| {}).unwrap();
        assert!(manager.verify().unwrap());
        assert_eq!(manager.state, ModelState::Ready);
        assert!(server.join().unwrap()[0].to_lowercase().contains("range: bytes=8-1023"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn existing_models_are_checked_before_ready() {
        let (mut valid, dir) = fixture("http://127.0.0.1:9/unreachable".into());
        fs::write(&valid.model_path, bytes()).unwrap();
        valid.download_with_progress(|_, _, _| {}).unwrap();
        assert_eq!(valid.state, ModelState::Ready);
        fs::remove_dir_all(dir).unwrap();

        let (url, server) = server(vec![response("200 OK", "Content-Length: 1024\r\n", &bytes())]);
        let (mut corrupt, dir) = fixture(url);
        let mut bad = bytes();
        bad[33] ^= 1;
        fs::write(&corrupt.model_path, bad).unwrap();
        assert!(corrupt.is_installed());
        assert!(!corrupt.verify().unwrap());
        corrupt.download_with_progress(|_, _, _| {}).unwrap();
        assert!(corrupt.verify().unwrap());
        assert!(fs::read_dir(&dir).unwrap().any(|entry| entry.unwrap().path().extension().unwrap_or_default().to_string_lossy().starts_with("invalid-")));
        server.join().unwrap();
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn ignored_range_restarts_instead_of_appending() {
        let body = bytes();
        let (url, server) = server(vec![response("200 OK", "Content-Length: 1024\r\n", &body)]);
        let (mut manager, dir) = fixture(url);
        fs::write(&manager.model_path, &body[..8]).unwrap();
        manager.download_with_progress(|_, _, _| {}).unwrap();
        assert_eq!(fs::read(&manager.model_path).unwrap(), body);
        server.join().unwrap();
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn http_error_or_wrong_range_cannot_corrupt_partial() {
        for payload in [response("404 Not Found", "Content-Length: 4\r\n", b"html"),
            response("206 Partial Content", "Content-Range: bytes 0-1023/1024\r\nContent-Length: 1024\r\n", &bytes())] {
            let (url, server) = server(vec![payload]);
            let (mut manager, dir) = fixture(url);
            fs::write(&manager.model_path, &bytes()[..8]).unwrap();
            assert!(manager.download_with_progress(|_, _, _| {}).is_err());
            assert!(!manager.model_path.exists());
            assert_eq!(fs::read(manager.model_path.with_extension("bin.part")).unwrap(), bytes()[..8]);
            server.join().unwrap();
            fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn interrupted_response_resumes_from_actual_bytes_on_next_attempt() {
        let body = bytes();
        let (url, server) = server(vec![
            response("206 Partial Content", "Content-Range: bytes 8-1023/1024\r\nContent-Length: 1016\r\n", &body[8..101]),
            response("206 Partial Content", "Content-Range: bytes 101-1023/1024\r\nContent-Length: 923\r\n", &body[101..]),
        ]);
        let (mut manager, dir) = fixture(url);
        fs::write(&manager.model_path, &body[..8]).unwrap();
        assert!(manager.download_with_progress(|_, _, _| {}).is_err());
        assert_eq!(fs::metadata(manager.model_path.with_extension("bin.part")).unwrap().len(), 101);
        manager.download_with_progress(|_, _, _| {}).unwrap();
        assert!(manager.verify().unwrap());
        let requests = server.join().unwrap();
        assert!(requests[1].to_lowercase().contains("range: bytes=101-1023"));
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn header_valid_corrupt_download_is_not_accepted() {
        let mut body = bytes();
        body[30] ^= 1;
        let (url, server) = server(vec![response("200 OK", "Content-Length: 1024\r\n", &body)]);
        let (mut manager, dir) = fixture(url);
        assert!(manager.download_with_progress(|_, _, _| {}).is_err());
        assert!(!manager.model_path.exists());
        assert_eq!(manager.state, ModelState::Error);
        server.join().unwrap();
        fs::remove_dir_all(dir).unwrap();
    }
}
