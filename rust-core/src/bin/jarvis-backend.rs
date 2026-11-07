//! Local compatibility transport. Rust owns app-facing services; a private,
//! lazily launched Python worker temporarily retains voice/legacy endpoints.
use jarvis_core::{
    backend_config::{Broker, Config},
    backend_services::{random_token, ApiError, HttpSpotify, Services},
    native_intent,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    io::{Read, Write},
    net::TcpListener,
    os::{
        fd::AsRawFd,
        unix::{fs::PermissionsExt, process::CommandExt},
    },
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
use tiny_http::{Header, Request, Response, Server, StatusCode};

struct VoiceWorker {
    child: Option<Child>,
    url: Option<String>,
}
impl VoiceWorker {
    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.url = None;
    }
    fn start(
        &mut self,
        backend: &Path,
        token: &str,
        client: &reqwest::blocking::Client,
    ) -> Result<String, ApiError> {
        if let Some(child) = self.child.as_mut() {
            if matches!(child.try_wait(), Ok(None)) {
                return self
                    .url
                    .clone()
                    .ok_or_else(|| ApiError::new(503, "Voice helper unavailable"));
            }
        }
        self.stop();
        let python = backend.join("venv/bin/python");
        if !python.is_file() {
            return Err(ApiError::new(
                503,
                "Voice dependencies are unavailable. Prepare the helper in Setup.",
            ));
        }
        let listener = TcpListener::bind("127.0.0.1:0")
            .map_err(|_| ApiError::new(503, "Could not reserve voice helper port"))?;
        let port = listener
            .local_addr()
            .map_err(|_| ApiError::new(503, "Could not reserve voice helper port"))?
            .port();
        let fd = listener.as_raw_fd();
        let mut command = Command::new(python);
        command
            .current_dir(backend)
            .args([
                "-m",
                "uvicorn",
                "voice_auth_service:app",
                "--fd",
                "3",
                "--workers",
                "1",
                "--no-access-log",
            ])
            .env("JARVIS_VOICE_ONLY", "1")
            .env("JARVIS_HELPER_AUTH_TOKEN", token)
            .env("PYTHONDONTWRITEBYTECODE", "1")
            .stdin(Stdio::null())
            .stdout(Stdio::inherit())
            .stderr(Stdio::inherit());
        // Only async-signal-safe operations between fork and exec. The reserved
        // loopback socket is passed directly, avoiding a port-allocation race.
        unsafe {
            command.pre_exec(move || {
                if fd != 3 && libc::dup2(fd, 3) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::fcntl(3, libc::F_SETFD, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        self.child = Some(
            command
                .spawn()
                .map_err(|_| ApiError::new(503, "Could not start voice helper"))?,
        );
        drop(listener);
        let url = format!("http://127.0.0.1:{port}");
        self.url = Some(url.clone());
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            if matches!(self.child.as_mut().unwrap().try_wait(), Ok(Some(_))) {
                self.stop();
                return Err(ApiError::new(503, "Voice helper exited during startup"));
            }
            if let Ok(response) = client
                .get(format!("{url}/health"))
                .header("X-Jarvis-Token", token)
                .timeout(Duration::from_millis(250))
                .send()
            {
                if response.status().is_success() {
                    return Ok(url);
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        self.stop();
        Err(ApiError::new(503, "Voice helper startup timed out"))
    }
}
impl Drop for VoiceWorker {
    fn drop(&mut self) {
        self.stop();
    }
}
struct App {
    services: Services<Broker, HttpSpotify>,
    backend: PathBuf,
    data: PathBuf,
    token: String,
    voice: Mutex<VoiceWorker>,
    native_voice: jarvis_core::voice_service::VoiceService,
    client: reqwest::blocking::Client,
    owner: u32,
    keep_warm: AtomicBool,
}
struct Reply {
    status: u16,
    body: Vec<u8>,
    location: Option<String>,
}
impl Reply {
    fn json(value: Value) -> Self {
        Self {
            status: 200,
            body: value.to_string().into_bytes(),
            location: None,
        }
    }
    fn error(error: ApiError) -> Self {
        Self {
            status: error.status,
            body: json!({"detail":error.detail}).to_string().into_bytes(),
            location: None,
        }
    }
}
fn authorized(expected: &str, supplied: Option<&str>) -> bool {
    supplied.is_some_and(|s| !s.is_empty() && bool::from(expected.as_bytes().ct_eq(s.as_bytes())))
}
fn query(url: &str) -> (String, HashMap<String, String>) {
    let (path, q) = url.split_once('?').unwrap_or((url, ""));
    (
        path.to_owned(),
        url::form_urlencoded::parse(q.as_bytes())
            .into_owned()
            .collect(),
    )
}
fn field<'a>(query: &'a HashMap<String, String>, key: &str) -> &'a str {
    query.get(key).map(String::as_str).unwrap_or("")
}
impl App {
    fn native_voice_enabled(&self) -> bool {
        std::env::var("JARVIS_VOICE_RUNTIME")
            .unwrap_or_else(|_| "native".into())
            .to_lowercase()
            != "python"
    }
    fn proxy(
        &self,
        method: &str,
        path: &str,
        body: Vec<u8>,
        content_type: &str,
    ) -> Result<Reply, ApiError> {
        let base = self
            .voice
            .lock()
            .map_err(|_| ApiError::new(503, "Voice helper busy"))?
            .start(&self.backend, &self.token, &self.client)?;
        let method = reqwest::Method::from_bytes(method.as_bytes())
            .map_err(|_| ApiError::new(405, "Unsupported method"))?;
        let response = self
            .client
            .request(method, format!("{base}{path}"))
            .header("X-Jarvis-Token", &self.token)
            .header("Content-Type", content_type)
            .body(body)
            .timeout(Duration::from_secs(60))
            .send()
            .map_err(|_| ApiError::new(503, "Voice helper unavailable"))?;
        let status = response.status().as_u16();
        let mut data = Vec::new();
        response
            .take(2_000_001)
            .read_to_end(&mut data)
            .map_err(|_| ApiError::new(503, "Voice helper response failed"))?;
        if data.len() > 2_000_000 {
            return Err(ApiError::new(502, "Helper response exceeds limit"));
        }
        Ok(Reply {
            status,
            body: data,
            location: None,
        })
    }
    fn route(
        &self,
        method: &str,
        path: &str,
        q: &HashMap<String, String>,
        body: Vec<u8>,
        content_type: &str,
        original: &str,
    ) -> Result<Reply, ApiError> {
        let payload = || -> Result<Value, ApiError> {
            serde_json::from_slice(&body).map_err(|_| ApiError::new(422, "Invalid JSON request"))
        };
        let value = match (method, path) {
            ("GET", "/health") => {
                json!({"status":"ok","api_version":4,"credential_owner_pid":self.owner,"runtime":"rust"})
            }
            ("GET", "/spotify/status") => self.services.spotify_status()?,
            ("POST", "/spotify/credentials") => self.services.spotify_save(&payload()?)?,
            ("GET", "/spotify/connect-url") => self.services.connect_url()?,
            ("GET", "/spotify/login") => {
                let v = self.services.connect_url()?;
                return Ok(Reply {
                    status: 307,
                    body: Vec::new(),
                    location: v["url"].as_str().map(str::to_owned),
                });
            }
            ("GET", "/spotify/callback" | "/callback") => self.services.callback(q)?,
            ("GET", "/spotify/token") => self.services.token_status()?,
            ("GET", "/spotify/native-target") => {
                let shuffle = match field(q, "shuffle").to_lowercase().as_str() {
                    "" | "0" | "false" | "off" | "no" => false,
                    "1" | "true" | "on" | "yes" => true,
                    _ => return Err(ApiError::new(422, "Invalid shuffle value")),
                };
                self.services
                    .native_target(field(q, "kind"), field(q, "name"), shuffle)?
            }
            ("GET", "/postgres/status") => self.services.postgres_status()?,
            ("POST", "/postgres/credentials") => self.services.postgres_save(&payload()?)?,
            ("POST", "/postgres/test") => self.services.postgres_test(&payload()?)?,
            ("GET", "/intent_model/status") => {
                serde_json::from_str(&native_intent::status()).unwrap_or(Value::Null)
            }
            ("POST", "/parse_intent")
                if std::env::var("JARVIS_INTENT_RUNTIME")
                    .unwrap_or_default()
                    .to_lowercase()
                    != "python" =>
            {
                let v = payload()?;
                let text = v["text"]
                    .as_str()
                    .ok_or_else(|| ApiError::new(422, "text is required"))?;
                let library = self
                    .backend
                    .parent()
                    .unwrap_or(&self.backend)
                    .join("native/libonnxruntime.1.31.0.dylib");
                let raw = native_intent::parse(
                    text,
                    &self.backend.join("models/intent-t5-small"),
                    &self.data,
                    &library,
                )
                .map_err(|_| ApiError::new(503, "Intent model unavailable or busy"))?;
                serde_json::from_str(&raw)
                    .map_err(|_| ApiError::new(500, "Invalid native intent response"))?
            }
            // Compatibility endpoints stay behind the same authenticated Rust
            // boundary until their Python implementations are retired.
            ("GET", "/stats") if self.native_voice_enabled() => self.native_voice.stats()?,
            ("POST", "/reset") if self.native_voice_enabled() => {
                self.native_voice.run("reset", &[])?
            }
            ("POST", "/enroll" | "/verify") if self.native_voice_enabled() => {
                let boundary = multer::parse_boundary(content_type)
                    .map_err(|_| ApiError::new(422, "Missing audio upload boundary"))?;
                let audio: Result<Vec<u8>, ApiError> = futures_executor::block_on(async {
                    let stream = futures_util::stream::once(async {
                        Ok::<_, std::convert::Infallible>(body)
                    });
                    let mut form = multer::Multipart::new(stream, boundary);
                    let mut audio = None;
                    while let Some(field) = form
                        .next_field()
                        .await
                        .map_err(|_| ApiError::new(400, "Invalid audio upload"))?
                    {
                        if field.name() == Some("file") {
                            let data = field
                                .bytes()
                                .await
                                .map_err(|_| ApiError::new(400, "Invalid audio upload"))?;
                            if data.is_empty() {
                                return Err(ApiError::new(400, "Empty audio file"));
                            }
                            if data.len() > 10 * 1024 * 1024 {
                                return Err(ApiError::new(413, "Audio file exceeds 10 MB"));
                            }
                            audio = Some(data.to_vec());
                        }
                    }
                    audio.ok_or_else(|| ApiError::new(422, "Audio file is required"))
                });
                self.native_voice
                    .run(path.trim_start_matches('/'), &audio?)?
            }
            ("GET", "/stats")
            | (
                "POST",
                "/enroll"
                | "/verify"
                | "/reset"
                | "/parse_intent"
                | "/spotify/play"
                | "/spotify/play-song"
                | "/spotify/play-playlist"
                | "/spotify/play-liked"
                | "/spotify/shuffle"
                | "/spotify/pause"
                | "/spotify/next"
                | "/spotify/previous",
            ) => return self.proxy(method, original, body, content_type),
            _ => return Err(ApiError::new(404, "Not Found")),
        };
        Ok(Reply::json(value))
    }
    fn handle(&self, mut request: Request) {
        let original = request.url().to_owned();
        let (path, q) = query(&original);
        let method = request.method().as_str().to_owned();
        let header = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("X-Jarvis-Token"))
            .map(|h| h.value.as_str());
        let callback =
            method == "GET" && ["/spotify/callback", "/callback"].contains(&path.as_str());
        if !callback && !authorized(&self.token, header) {
            respond(
                request,
                Reply::error(ApiError::new(401, "Local authentication required")),
            );
            return;
        }
        if !callback {
            if let Some(value) = request
                .headers()
                .iter()
                .find(|h| h.field.equiv("X-Jarvis-Keep-Warm"))
                .map(|h| h.value.as_str())
            {
                if value == "0" || value == "1" {
                    self.keep_warm.store(value == "1", Ordering::Relaxed);
                }
            }
        }
        let content_type = request
            .headers()
            .iter()
            .find(|h| h.field.equiv("Content-Type"))
            .map(|h| h.value.as_str().to_owned())
            .unwrap_or_else(|| "application/json".into());
        let limit = if ["/enroll", "/verify"].contains(&path.as_str()) {
            10 * 1024 * 1024 + 65536
        } else {
            65536
        };
        if request.body_length().is_some_and(|n| n > limit) {
            respond(
                request,
                Reply::error(ApiError::new(413, "Request exceeds limit")),
            );
            return;
        }
        let mut body = Vec::new();
        if request
            .as_reader()
            .take(limit as u64 + 1)
            .read_to_end(&mut body)
            .is_err()
        {
            respond(
                request,
                Reply::error(ApiError::new(400, "Could not read request")),
            );
            return;
        }
        if body.len() > limit {
            respond(
                request,
                Reply::error(ApiError::new(413, "Request exceeds limit")),
            );
            return;
        }
        let reply = self
            .route(&method, &path, &q, body, &content_type, &original)
            .unwrap_or_else(Reply::error);
        respond(request, reply);
    }
}
fn respond(request: Request, reply: Reply) {
    let mut response = Response::from_data(reply.body)
        .with_status_code(StatusCode(reply.status))
        .with_header(Header::from_bytes("Content-Type", "application/json").unwrap())
        .with_header(Header::from_bytes("Cache-Control", "no-store").unwrap());
    if let Some(location) = reply.location {
        if let Ok(header) = Header::from_bytes("Location", location) {
            response.add_header(header);
        }
    }
    let _ = request.respond(response);
}
fn write_token(directory: &Path, token: &str) -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(directory)?;
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
    let mut temp = tempfile::NamedTempFile::new_in(directory)?;
    temp.write_all(token.as_bytes())?;
    temp.as_file().sync_all()?;
    temp.persist(directory.join("backend_auth.token"))?;
    Ok(())
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 || args[1] != "--backend-dir" {
        return Err("usage: jarvis-backend --backend-dir DIRECTORY".into());
    }
    let backend = PathBuf::from(&args[2]).canonicalize()?;
    let data = std::env::var_os("JARVIS_DATA_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_default()
                .join("Library/Application Support/Jarvis")
        });
    let port = std::env::var("JARVIS_BACKEND_PORT")
        .unwrap_or_else(|_| "8000".into())
        .parse::<u16>()?;
    let server = Arc::new(
        Server::http(("127.0.0.1", port)).map_err(|_| "Could not bind the local helper port")?,
    );
    let token = random_token();
    write_token(&data, &token)?;
    let owner = std::env::var("JARVIS_CREDENTIAL_OWNER_PID")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let services = Services::new(
        Config::from_environment(&backend, data.clone()),
        HttpSpotify::new()?,
    );
    let client = reqwest::blocking::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(60))
        .build()?;
    let native_dir = backend.parent().unwrap_or(&backend).join("native");
    let native_voice = jarvis_core::voice_service::VoiceService::new(
        native_dir.join("voice"),
        native_dir.join("libonnxruntime.1.31.0.dylib"),
        data.join("embeddings.npy"),
        backend.join("embeddings.npy"),
    );
    let app = Arc::new(App {
        services,
        backend,
        data,
        token,
        voice: Mutex::new(VoiceWorker {
            child: None,
            url: None,
        }),
        native_voice,
        client,
        owner,
        keep_warm: AtomicBool::new(false),
    });
    let running = Arc::new(AtomicBool::new(true));
    let signal = running.clone();
    ctrlc::set_handler(move || {
        signal.store(false, Ordering::SeqCst);
    })?;
    // Bound active HTTP work; health checks remain independent of inference.
    for _ in 0..8 {
        let server = server.clone();
        let app = app.clone();
        let running = running.clone();
        std::thread::spawn(move || {
            while running.load(Ordering::SeqCst) {
                if let Ok(Some(request)) = server.recv_timeout(Duration::from_millis(250)) {
                    app.handle(request);
                }
            }
        });
    }
    eprintln!(
        "[Backend] Native connection helper ready port={}",
        server
            .server_addr()
            .to_ip()
            .ok_or("Missing listen address")?
            .port()
    );
    while running.load(Ordering::SeqCst) {
        if owner != 0 && unsafe { libc::kill(owner as i32, 0) } != 0 {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
        if !app.keep_warm.load(Ordering::Relaxed) {
            app.native_voice.unload_if_idle();
        }
    }
    running.store(false, Ordering::SeqCst);
    if let Ok(mut voice) = app.voice.lock() {
        voice.stop();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn authentication_requires_exact_token() {
        assert!(!authorized("example", None));
        assert!(!authorized("example", Some("")));
        assert!(!authorized("example", Some("example-more")));
        assert!(authorized("example", Some("example")));
    }
    #[test]
    fn token_is_private_and_rotates() {
        let dir = tempfile::tempdir().unwrap();
        let a = random_token();
        write_token(dir.path(), &a).unwrap();
        assert_eq!(
            fs::read_to_string(dir.path().join("backend_auth.token")).unwrap(),
            a
        );
        assert_eq!(
            fs::metadata(dir.path().join("backend_auth.token"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let b = random_token();
        assert_ne!(a, b);
        write_token(dir.path(), &b).unwrap();
        assert_eq!(
            fs::read_to_string(dir.path().join("backend_auth.token")).unwrap(),
            b
        );
    }
}
