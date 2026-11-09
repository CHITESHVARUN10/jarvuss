//! Database connection services. Spotify is controlled entirely by macOS.
use crate::backend_config::{Config, Credentials};
use rand::Rng;
use serde_json::{json, Value};
use std::{collections::HashMap, time::Duration};
#[derive(Debug)]
pub struct ApiError { pub status: u16, pub detail: String }
impl ApiError { pub fn new(status: u16, detail: impl Into<String>) -> Self { Self { status, detail: detail.into() } } }
impl From<String> for ApiError { fn from(v: String) -> Self { Self::new(500, v) } }
type Result<T> = std::result::Result<T, ApiError>;
fn text<'a>(v: &'a HashMap<String, String>, key: &str) -> &'a str { v.get(key).map(String::as_str).unwrap_or("") }
fn value(v: &Value, key: &str) -> String { v[key].as_str().unwrap_or("").to_string() }
pub fn random_token() -> String { let bytes: [u8; 32] = rand::rng().random(); bytes.iter().map(|b| format!("{b:02x}")).collect() }
pub struct Services<C: Credentials> { pub config: Config<C> }
impl<C: Credentials> Services<C> {
    pub fn new(config: Config<C>) -> Self { Self { config } }
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
    fn service(dir: &std::path::Path) -> Services<FakeCredentials> { Services::new(Config { directory: dir.to_owned(), credentials: FakeCredentials::default(), defaults: HashMap::new() }) }
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
