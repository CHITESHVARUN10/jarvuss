//! App-facing connection services. Playback remains the native macOS adapter;
//! this module only resolves Spotify metadata and manages connection settings.
use crate::backend_config::{Config, Credentials};
use rand::{
    seq::{index, SliceRandom},
    Rng,
};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

#[derive(Debug)]
pub struct ApiError {
    pub status: u16,
    pub detail: String,
}
impl ApiError {
    pub fn new(status: u16, detail: impl Into<String>) -> Self {
        Self {
            status,
            detail: detail.into(),
        }
    }
}
impl From<String> for ApiError {
    fn from(v: String) -> Self {
        Self::new(500, v)
    }
}
type Result<T> = std::result::Result<T, ApiError>;
pub trait SpotifyNetwork: Send + Sync {
    fn api(&self, path: &str, token: &str, query: &[(&str, String)]) -> Result<(u16, Value)>;
    fn token(&self, id: &str, secret: &str, form: &[(&str, String)]) -> Result<Value>;
}
pub struct HttpSpotify {
    client: reqwest::blocking::Client,
}
impl HttpSpotify {
    pub fn new() -> std::result::Result<Self, String> {
        Ok(Self {
            client: reqwest::blocking::Client::builder()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(15))
                .build()
                .map_err(|_| "Could not initialize network client")?,
        })
    }
}
impl SpotifyNetwork for HttpSpotify {
    fn api(&self, path: &str, token: &str, query: &[(&str, String)]) -> Result<(u16, Value)> {
        let response = self
            .client
            .get(format!("https://api.spotify.com{path}"))
            .bearer_auth(token)
            .query(query)
            .send()
            .map_err(|_| ApiError::new(502, "Spotify could not be reached"))?;
        let status = response.status().as_u16();
        let mut bytes = Vec::new();
        response
            .take(2_000_001)
            .read_to_end(&mut bytes)
            .map_err(|_| ApiError::new(502, "Could not read Spotify response"))?;
        if bytes.len() > 2_000_000 {
            return Err(ApiError::new(502, "Spotify response exceeds limit"));
        }
        Ok((
            status,
            serde_json::from_slice(&bytes).unwrap_or(Value::Null),
        ))
    }
    fn token(&self, id: &str, secret: &str, form: &[(&str, String)]) -> Result<Value> {
        let response = self
            .client
            .post("https://accounts.spotify.com/api/token")
            .basic_auth(id, Some(secret))
            .form(form)
            .send()
            .map_err(|_| {
                ApiError::new(400, "Spotify token request failed: connection unavailable")
            })?;
        let status = response.status();
        let v: Value = response
            .json()
            .map_err(|_| ApiError::new(400, "Spotify token response was invalid"))?;
        if !status.is_success() {
            let reason = v["error_description"]
                .as_str()
                .or(v["error"].as_str())
                .unwrap_or("authorization failed");
            return Err(ApiError::new(
                400,
                format!(
                    "Spotify token request failed: {}",
                    reason.chars().take(300).collect::<String>()
                ),
            ));
        }
        Ok(v)
    }
}
use std::io::Read;
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn text<'a>(v: &'a HashMap<String, String>, key: &str) -> &'a str {
    v.get(key).map(String::as_str).unwrap_or("")
}
fn value(v: &Value, key: &str) -> String {
    v[key].as_str().unwrap_or("").to_string()
}
fn normalize(s: &str) -> String {
    s.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_lowercase()
}
fn playable(v: &Value) -> Option<String> {
    let uri = v["uri"].as_str()?;
    if uri.starts_with("spotify:track:") && v["is_local"] != true && v["is_playable"] != false {
        Some(uri.to_owned())
    } else {
        None
    }
}

#[derive(Default)]
pub struct OAuthStates {
    pending: HashMap<String, Instant>,
}
impl OAuthStates {
    pub fn issue(&mut self) -> String {
        self.issue_at(Instant::now())
    }
    fn issue_at(&mut self, now: Instant) -> String {
        self.pending.retain(|_, expiry| *expiry > now);
        if self.pending.len() >= 32 {
            if let Some(key) = self
                .pending
                .iter()
                .min_by_key(|(_, expiry)| **expiry)
                .map(|(k, _)| k.clone())
            {
                self.pending.remove(&key);
            }
        }
        let token = random_token();
        self.pending
            .insert(token.clone(), now + Duration::from_secs(600));
        token
    }
    pub fn consume(&mut self, token: &str) -> bool {
        self.consume_at(token, Instant::now())
    }
    fn consume_at(&mut self, token: &str, now: Instant) -> bool {
        self.pending
            .remove(token)
            .is_some_and(|expiry| expiry > now)
    }
}
pub fn random_token() -> String {
    let bytes: [u8; 32] = rand::rng().random();
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub struct Services<C: Credentials, N: SpotifyNetwork> {
    pub config: Config<C>,
    network: N,
    token_lock: Mutex<()>,
    states: Mutex<OAuthStates>,
}
impl<C: Credentials, N: SpotifyNetwork> Services<C, N> {
    pub fn new(config: Config<C>, network: N) -> Self {
        Self {
            config,
            network,
            token_lock: Mutex::new(()),
            states: Mutex::new(OAuthStates::default()),
        }
    }
    fn spotify_values(&self) -> Result<HashMap<String, String>> {
        self.config
            .load(&[
                "SPOTIFY_CLIENT_SECRET",
                "SPOTIFY_ACCESS_TOKEN",
                "SPOTIFY_REFRESH_TOKEN",
            ])
            .map_err(Into::into)
    }
    fn redirect(v: &HashMap<String, String>) -> String {
        v.get("SPOTIFY_REDIRECT_URI")
            .cloned()
            .unwrap_or_else(|| "http://127.0.0.1:8000/spotify/callback".into())
    }
    fn save_tokens(&self, v: &Value, old_refresh: &str) -> Result<u64> {
        let access = value(v, "access_token");
        if access.is_empty() {
            return Err(ApiError::new(400, "Spotify response missing access token"));
        }
        let expires = v["expires_in"].as_u64().unwrap_or(3600);
        let refresh = v["refresh_token"].as_str().unwrap_or(old_refresh);
        let mut updates = HashMap::from([
            ("SPOTIFY_ACCESS_TOKEN".into(), access),
            (
                "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT".into(),
                now().saturating_add(expires).to_string(),
            ),
        ]);
        if !refresh.is_empty() {
            updates.insert("SPOTIFY_REFRESH_TOKEN".into(), refresh.into());
        }
        self.config.save(updates)?;
        Ok(expires)
    }
    fn access_token(&self) -> Result<String> {
        let _guard = self
            .token_lock
            .lock()
            .map_err(|_| ApiError::new(503, "Spotify service busy"))?;
        let v = self.spotify_values()?;
        let access = text(&v, "SPOTIFY_ACCESS_TOKEN");
        let expiry = text(&v, "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT")
            .parse::<u64>()
            .unwrap_or(0);
        if !access.is_empty() && expiry > now() + 30 {
            return Ok(access.into());
        }
        let refresh = text(&v, "SPOTIFY_REFRESH_TOKEN");
        let id = text(&v, "SPOTIFY_CLIENT_ID");
        let secret = text(&v, "SPOTIFY_CLIENT_SECRET");
        if id.is_empty() || secret.is_empty() || refresh.is_empty() {
            return Err(ApiError::new(401, "Spotify refresh token unavailable"));
        }
        let result = self.network.token(
            id,
            secret,
            &[
                ("grant_type", "refresh_token".into()),
                ("refresh_token", refresh.into()),
            ],
        )?;
        self.save_tokens(&result, refresh)?;
        Ok(value(&result, "access_token"))
    }
    pub fn spotify_status(&self) -> Result<Value> {
        let _guard = self
            .token_lock
            .lock()
            .map_err(|_| ApiError::new(503, "Spotify service busy"))?;
        let v = self.spotify_values()?;
        let expiry = text(&v, "SPOTIFY_ACCESS_TOKEN_EXPIRES_AT")
            .parse::<i64>()
            .unwrap_or(0);
        Ok(
            json!({"status":"ok","client_id_present":!text(&v,"SPOTIFY_CLIENT_ID").is_empty(),"client_secret_present":!text(&v,"SPOTIFY_CLIENT_SECRET").is_empty(),"access_token_present":!text(&v,"SPOTIFY_ACCESS_TOKEN").is_empty(),"expires_at":expiry,"expired":expiry<=now() as i64,"redirect_uri":Self::redirect(&v)}),
        )
    }
    pub fn spotify_save(&self, payload: &Value) -> Result<Value> {
        let id = value(payload, "client_id").trim().to_owned();
        let secret = value(payload, "client_secret").trim().to_owned();
        if id.is_empty() || secret.is_empty() {
            return Err(ApiError::new(
                400,
                "client_id and client_secret are required",
            ));
        }
        let _guard = self
            .token_lock
            .lock()
            .map_err(|_| ApiError::new(503, "Spotify service busy"))?;
        let mut updates = HashMap::from([
            ("SPOTIFY_CLIENT_ID".into(), id),
            ("SPOTIFY_CLIENT_SECRET".into(), secret),
            ("SPOTIFY_ACCESS_TOKEN".into(), String::new()),
            ("SPOTIFY_REFRESH_TOKEN".into(), String::new()),
            ("SPOTIFY_ACCESS_TOKEN_EXPIRES_AT".into(), "0".into()),
        ]);
        let redirect = value(payload, "redirect_uri");
        if !redirect.trim().is_empty() {
            updates.insert("SPOTIFY_REDIRECT_URI".into(), redirect.trim().into());
        }
        self.config.save(updates)?;
        Ok(
            json!({"status":"ok","message":"Spotify credentials saved. Open the connect link to authorize."}),
        )
    }
    pub fn connect_url(&self) -> Result<Value> {
        let v = self.config.load(&["SPOTIFY_CLIENT_SECRET"])?;
        let id = text(&v, "SPOTIFY_CLIENT_ID");
        if id.is_empty() {
            return Err(ApiError::new(500, "Missing SPOTIFY_CLIENT_ID"));
        }
        let state = self
            .states
            .lock()
            .map_err(|_| ApiError::new(503, "Spotify service busy"))?
            .issue();
        let redirect = Self::redirect(&v);
        let mut url = url::Url::parse("https://accounts.spotify.com/authorize").unwrap();
        url.query_pairs_mut().extend_pairs([("client_id",id),("response_type","code"),("redirect_uri",&redirect),("scope","user-read-playback-state user-modify-playback-state user-read-currently-playing user-library-read playlist-read-private"),("state",&state)]);
        Ok(json!({"status":"ok","url":url.as_str(),"redirect_uri":redirect}))
    }
    pub fn callback(&self, query: &HashMap<String, String>) -> Result<Value> {
        let state = text(query, "state");
        if !self
            .states
            .lock()
            .map_err(|_| ApiError::new(503, "Spotify service busy"))?
            .consume(state)
        {
            return Err(ApiError::new(
                400,
                "Invalid or expired OAuth state; connect again from Jarvis",
            ));
        }
        let error = text(query, "error");
        if !error.is_empty() {
            return Err(ApiError::new(
                400,
                format!("Spotify authorization refused: {error}"),
            ));
        }
        let code = text(query, "code");
        if code.is_empty() {
            return Err(ApiError::new(400, "Spotify callback missing code"));
        }
        let _guard = self
            .token_lock
            .lock()
            .map_err(|_| ApiError::new(503, "Spotify service busy"))?;
        let v = self.config.load(&["SPOTIFY_CLIENT_SECRET"])?;
        let (id, secret) = (
            text(&v, "SPOTIFY_CLIENT_ID"),
            text(&v, "SPOTIFY_CLIENT_SECRET"),
        );
        if id.is_empty() || secret.is_empty() {
            return Err(ApiError::new(500, "Missing Spotify client credentials"));
        }
        let result = self.network.token(
            id,
            secret,
            &[
                ("grant_type", "authorization_code".into()),
                ("code", code.into()),
                ("redirect_uri", Self::redirect(&v)),
            ],
        )?;
        let expires = self.save_tokens(&result, "")?;
        Ok(json!({"status":"ok","message":"Spotify authorization successful","expires_in":expires}))
    }
    pub fn token_status(&self) -> Result<Value> {
        let access = self.access_token()?;
        let v = self.config.load(&[])?;
        Ok(
            json!({"status":"ok","access_token_present":!access.is_empty(),"expires_at":text(&v,"SPOTIFY_ACCESS_TOKEN_EXPIRES_AT").parse::<u64>().unwrap_or(0)}),
        )
    }
    fn api(&self, path: &str, token: &str, query: &[(&str, String)]) -> Result<(u16, Value)> {
        self.network.api(path, token, query)
    }
    fn liked_page(&self, token: &str, offset: u64) -> Result<Value> {
        let (status, page) = self.api(
            "/v1/me/tracks",
            token,
            &[("limit", "50".into()), ("offset", offset.to_string())],
        )?;
        if !(200..300).contains(&status) || !page.is_object() {
            return Err(ApiError::new(
                400,
                "Spotify could not load saved tracks for shuffle.",
            ));
        }
        Ok(page)
    }
    fn liked(&self, token: &str, shuffle: bool) -> Result<Vec<String>> {
        let first = self.liked_page(token, 0)?;
        let items = first["items"]
            .as_array()
            .ok_or_else(|| ApiError::new(502, "Spotify returned invalid saved-track data"))?;
        if !shuffle {
            return Ok(items.iter().filter_map(|v| playable(&v["track"])).collect());
        }
        let total = first
            .get("total")
            .and_then(Value::as_u64)
            .or_else(|| {
                if first.get("total").is_none() {
                    Some(items.len() as u64)
                } else {
                    None
                }
            })
            .ok_or_else(|| ApiError::new(400, "Spotify returned an invalid saved-track count"))?;
        if total == 0 {
            return Ok(Vec::new());
        }
        let pages = total.div_ceil(50);
        let selected = index::sample(
            &mut rand::rng(),
            usize::try_from(pages).map_err(|_| ApiError::new(400, "Invalid library size"))?,
            5.min(pages as usize),
        )
        .into_vec();
        let mut unique = std::collections::HashSet::new();
        let mut uris = Vec::new();
        for page in selected {
            let page = if page == 0 {
                first.clone()
            } else {
                self.liked_page(token, page as u64 * 50)?
            };
            let items = page["items"]
                .as_array()
                .ok_or_else(|| ApiError::new(502, "Spotify returned invalid saved-track data"))?;
            for item in items {
                if let Some(uri) = playable(&item["track"]) {
                    if unique.insert(uri.clone()) {
                        uris.push(uri);
                    }
                }
            }
        }
        uris.shuffle(&mut rand::rng());
        uris.truncate(50);
        Ok(uris)
    }
    pub fn native_target(&self, kind: &str, name: &str, shuffle: bool) -> Result<Value> {
        if !["song", "playlist", "liked"].contains(&kind) {
            return Err(ApiError::new(400, "Unsupported Spotify lookup"));
        }
        if kind != "liked" && name.trim().is_empty() {
            return Err(ApiError::new(400, "A song or playlist name is required"));
        }
        let token = self.access_token()?;
        match kind {
            "song" => {
                let (status, v) = self.api(
                    "/v1/search",
                    &token,
                    &[
                        ("q", name.into()),
                        ("type", "track".into()),
                        ("limit", "1".into()),
                    ],
                )?;
                let uri = v["tracks"]["items"][0]["uri"]
                    .as_str()
                    .filter(|s| !s.is_empty());
                if !(200..300).contains(&status) || uri.is_none() {
                    return Err(ApiError::new(404, "No matching Spotify song found"));
                }
                Ok(json!({"uri":uri,"track_uri":uri}))
            }
            "playlist" => {
                let (status, v) =
                    self.api("/v1/me/playlists", &token, &[("limit", "50".into())])?;
                let key = normalize(name);
                let rows = v["items"]
                    .as_array()
                    .filter(|_| (200..300).contains(&status))
                    .ok_or_else(|| ApiError::new(404, "No matching Spotify playlist found"))?;
                let valid = |item: &&Value| item["uri"].as_str().is_some_and(|s| !s.is_empty());
                let found = rows
                    .iter()
                    .filter(valid)
                    .find(|item| normalize(item["name"].as_str().unwrap_or("")) == key)
                    .or_else(|| {
                        rows.iter().filter(valid).find(|item| {
                            let candidate = normalize(item["name"].as_str().unwrap_or(""));
                            candidate.contains(&key) || key.contains(&candidate)
                        })
                    })
                    .ok_or_else(|| ApiError::new(404, "No matching Spotify playlist found"))?;
                let uri = found["uri"].as_str().unwrap();
                let id = uri.rsplit(':').next().unwrap();
                let mut offset = 0;
                if shuffle {
                    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric()) {
                        return Err(ApiError::new(400,"Invalid Spotify playlist identifier"));
                    }
                    let mut selected = false;
                    for suffix in ["items", "tracks"] {
                        let (status, page) = self.api(
                            &format!("/v1/playlists/{id}/{suffix}"),
                            &token,
                            &[("limit", "1".into())],
                        )?;
                        if status == 404 && suffix == "items" {
                            continue;
                        }
                        if !(200..300).contains(&status) || !page.is_object() {
                            return Err(ApiError::new(400,"Spotify could not read this playlist to choose a random starting track."));
                        }
                        let total = page["total"].as_u64().filter(|n| *n > 0).ok_or_else(|| {
                            ApiError::new(404, "No playable items found in this playlist")
                        })?;
                        offset = rand::rng().random_range(0..total);
                        selected = true;
                        break;
                    }
                    if !selected { return Err(ApiError::new(404,"Playlist items are unavailable")); }
                }
                for suffix in ["items", "tracks"] {
                    let (status, page) = self.api(
                        &format!("/v1/playlists/{id}/{suffix}"),
                        &token,
                        &[("limit", "50".into()), ("offset", offset.to_string())],
                    )?;
                    if [404, 405].contains(&status) {
                        continue;
                    }
                    if status == 200 {
                        if let Some(items) = page["items"].as_array() {
                            for entry in items {
                                let track = if entry["track"].is_object() {
                                    &entry["track"]
                                } else {
                                    &entry["item"]
                                };
                                if let Some(track) = playable(track) {
                                    return Ok(json!({"uri":uri,"track_uri":track}));
                                }
                            }
                        }
                    }
                    break;
                }
                Err(ApiError::new(
                    404,
                    "Spotify could not find a playable track in this playlist.",
                ))
            }
            _ => {
                let (status, v) = self.api("/v1/me", &token, &[])?;
                let id = v["id"].as_str().filter(|s| !s.is_empty());
                if status != 200 || id.is_none() {
                    return Err(ApiError::new(if [401,403,429].contains(&status){status}else{502},"Spotify could not identify your Liked Songs library. Check Connections → Spotify."));
                }
                let tracks = self.liked(&token, shuffle)?;
                let track = tracks
                    .first()
                    .ok_or_else(|| ApiError::new(404, "No playable liked songs found"))?;
                Ok(
                    json!({"uri":format!("spotify:user:{}:collection",id.unwrap()),"track_uri":track}),
                )
            }
        }
    }
    pub fn postgres_status(&self) -> Result<Value> {
        let v = self.config.load(&["PGPASSWORD"])?;
        let missing: Vec<_> = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER"]
            .into_iter()
            .filter(|k| text(&v, k).trim().is_empty())
            .collect();
        Ok(
            json!({"status":"ok","configured":missing.is_empty(),"host":text(&v,"PGHOST").trim(),"port":if text(&v,"PGPORT").trim().is_empty(){"5432"}else{text(&v,"PGPORT").trim()},"database":text(&v,"PGDATABASE").trim(),"user":text(&v,"PGUSER").trim(),"password_present":!text(&v,"PGPASSWORD").is_empty(),"missing":missing}),
        )
    }
    pub fn postgres_save(&self, payload: &Value) -> Result<Value> {
        let mut updates = HashMap::new();
        for (key, field) in [
            ("PGHOST", "host"),
            ("PGPORT", "port"),
            ("PGDATABASE", "database"),
            ("PGUSER", "user"),
        ] {
            let mut v = value(payload, field).trim().to_owned();
            if key == "PGPORT" && v.is_empty() {
                v = "5432".into();
            }
            if v.is_empty() {
                return Err(ApiError::new(400, "host, database and user are required"));
            }
            updates.insert(key.into(), v);
        }
        let password = value(payload, "password");
        if !password.is_empty() {
            updates.insert("PGPASSWORD".into(), password);
        }
        self.config.save(updates)?;
        Ok(json!({"status":"ok","message":"Postgres credentials saved."}))
    }
    pub fn postgres_test(&self, payload: &Value) -> Result<Value> {
        use std::{
            io::Read,
            process::{Command, Stdio},
            thread,
        };
        use wait_timeout::ChildExt;
        let v = self.config.load(&["PGPASSWORD"])?;
        let missing: Vec<_> = ["PGHOST", "PGPORT", "PGDATABASE", "PGUSER"]
            .into_iter()
            .filter(|k| text(&v, k).trim().is_empty())
            .collect();
        if !missing.is_empty() {
            return Err(ApiError::new(
                400,
                format!("missing: {}", missing.join(", ")),
            ));
        }
        let which = std::env::var_os("PATH")
            .into_iter()
            .flat_map(|p| {
                std::env::split_paths(&p)
                    .map(|p| p.join("psql"))
                    .collect::<Vec<_>>()
            })
            .find(|p| p.is_file());
        let psql = which
            .or_else(|| {
                [
                    "/opt/homebrew/bin/psql",
                    "/opt/homebrew/opt/postgresql@18/bin/psql",
                    "/usr/local/bin/psql",
                    "/usr/local/opt/postgresql@18/bin/psql",
                    "/usr/bin/psql",
                ]
                .into_iter()
                .map(std::path::PathBuf::from)
                .find(|p| p.is_file())
            })
            .ok_or_else(|| ApiError::new(500, "could not run psql: executable not found"))?;
        let password = value(payload, "password");
        let mut child = Command::new(psql)
            .args([
                "-h",
                text(&v, "PGHOST").trim(),
                "-p",
                text(&v, "PGPORT").trim(),
                "-d",
                text(&v, "PGDATABASE").trim(),
                "-U",
                text(&v, "PGUSER").trim(),
                "-X",
                "-w",
                "-v",
                "ON_ERROR_STOP=1",
                "-tAc",
                "SELECT 1",
            ])
            .env(
                "PGPASSWORD",
                if password.is_empty() {
                    text(&v, "PGPASSWORD")
                } else {
                    &password
                },
            )
            .env("PGCONNECT_TIMEOUT", "5")
            .env(
                "PGOPTIONS",
                format!(
                    "{} -c statement_timeout=8000",
                    std::env::var("PGOPTIONS").unwrap_or_default()
                ),
            )
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|_| ApiError::new(500, "could not run psql"))?;
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let read = |stream: Box<dyn Read + Send>| {
            thread::spawn(move || {
                let mut data = Vec::new();
                let _ = stream.take(65536).read_to_end(&mut data);
                String::from_utf8_lossy(&data).to_string()
            })
        };
        let out = read(Box::new(stdout));
        let error = read(Box::new(stderr));
        let status = child
            .wait_timeout(Duration::from_secs(10))
            .map_err(|_| ApiError::new(500, "could not wait for psql"))?;
        let timed_out = status.is_none();
        if timed_out {
            let _ = child.kill();
            let _ = child.wait();
        }
        let output = out.join().unwrap_or_default();
        let error = error.join().unwrap_or_default();
        if timed_out {
            return Err(ApiError::new(500, "connection timed out after 10s"));
        }
        if !status.unwrap().success() || output.trim() != "1" {
            let detail = if error.trim().is_empty() {
                output.trim()
            } else {
                error.trim()
            };
            return Err(ApiError::new(
                500,
                if detail.is_empty() {
                    "connection refused".into()
                } else {
                    detail.chars().take(300).collect::<String>()
                },
            ));
        }
        Ok(json!({"status":"ok","message":"Connection OK — SELECT 1 returned 1."}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::backend_config::tests::FakeCredentials;
    use std::sync::atomic::{AtomicUsize, Ordering};
    struct MockNetwork {
        calls: AtomicUsize,
    }
    impl SpotifyNetwork for MockNetwork {
        fn api(&self, path: &str, _: &str, _: &[(&str, String)]) -> Result<(u16, Value)> {
            assert!(path.starts_with("/v1/"));
            Ok((
                200,
                match path {
                    "/v1/search" => json!({"tracks":{"items":[{"uri":"spotify:track:example"}]}}),
                    "/v1/me" => json!({"id":"example-user"}),
                    "/v1/me/tracks" => {
                        json!({"total":1,"items":[{"track":{"uri":"spotify:track:example"}}]})
                    }
                    _ => json!({}),
                },
            ))
        }
        fn token(&self, _: &str, _: &str, _: &[(&str, String)]) -> Result<Value> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(
                json!({"access_token":"new-synthetic","refresh_token":"refresh-synthetic","expires_in":3600}),
            )
        }
    }
    fn service(dir: &std::path::Path) -> Services<FakeCredentials, MockNetwork> {
        let config = Config {
            directory: dir.to_owned(),
            credentials: FakeCredentials::default(),
            defaults: HashMap::new(),
        };
        config
            .save(HashMap::from([
                ("SPOTIFY_CLIENT_ID".into(), "id".into()),
                ("SPOTIFY_CLIENT_SECRET".into(), "secret".into()),
                ("SPOTIFY_REFRESH_TOKEN".into(), "refresh".into()),
            ]))
            .unwrap();
        Services::new(
            config,
            MockNetwork {
                calls: AtomicUsize::new(0),
            },
        )
    }
    #[test]
    fn callback_requires_expiring_single_use_state() {
        let mut states = OAuthStates::default();
        let now = Instant::now();
        let token = states.issue_at(now);
        assert!(!states.consume_at(&token, now + Duration::from_secs(601)));
        let token = states.issue_at(now);
        assert!(states.consume_at(&token, now));
        assert!(!states.consume_at(&token, now));
        for _ in 0..40 {
            states.issue_at(now);
        }
        assert_eq!(states.pending.len(), 32);
    }
    #[test]
    fn parallel_requests_refresh_once() {
        let dir = tempfile::tempdir().unwrap();
        let s = service(dir.path());
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let s = &s;
                scope.spawn(move || {
                    assert_eq!(s.access_token().unwrap(), "new-synthetic");
                });
            }
        });
        assert_eq!(s.network.calls.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn native_targets_and_status_never_return_tokens() {
        let dir = tempfile::tempdir().unwrap();
        let s = service(dir.path());
        assert_eq!(
            s.native_target("song", "Blinding Lights", false).unwrap()["uri"],
            "spotify:track:example"
        );
        assert_eq!(
            s.native_target("liked", "", true).unwrap()["uri"],
            "spotify:user:example-user:collection"
        );
        assert!(!s
            .spotify_status()
            .unwrap()
            .to_string()
            .contains("new-synthetic"));
        assert!(!s
            .token_status()
            .unwrap()
            .to_string()
            .contains("new-synthetic"));
        assert!(s.native_target("bad", "", false).is_err());
    }
    #[test]
    fn oauth_callback_checks_state_before_network() {
        let dir = tempfile::tempdir().unwrap();
        let s = service(dir.path());
        assert!(s
            .callback(&HashMap::from([("code".into(), "fake".into())]))
            .is_err());
        assert_eq!(s.network.calls.load(Ordering::SeqCst), 0);
        let url = s.connect_url().unwrap();
        let u = url::Url::parse(url["url"].as_str().unwrap()).unwrap();
        let state = u
            .query_pairs()
            .find(|(k, _)| k == "state")
            .unwrap()
            .1
            .to_string();
        let q = HashMap::from([("state".into(), state), ("code".into(), "fake".into())]);
        assert!(s.callback(&q).is_ok());
        assert!(s.callback(&q).is_err());
        assert_eq!(s.network.calls.load(Ordering::SeqCst), 1);
    }
    #[test]
    fn postgres_save_retains_blank_password_and_reports_presence() {
        let dir = tempfile::tempdir().unwrap();
        let s = service(dir.path());
        let mut v =
            json!({"host":" localhost ","database":"test","user":"test","password":"synthetic"});
        s.postgres_save(&v).unwrap();
        v["password"] = json!("");
        s.postgres_save(&v).unwrap();
        let status = s.postgres_status().unwrap();
        assert_eq!(status["port"], "5432");
        assert_eq!(status["configured"], true);
        assert_eq!(status["password_present"], true);
        assert!(!status.to_string().contains("synthetic"));
    }
}
