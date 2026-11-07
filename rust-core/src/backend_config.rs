//! Shared settings format and signed-app credential brokerage. Never stores
//! secret values in JSON or process arguments.
use fs2::FileExt;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    io::{Read, Write},
    os::unix::{
        fs::{OpenOptionsExt, PermissionsExt},
        net::UnixStream,
    },
    path::{Path, PathBuf},
    time::Duration,
};

pub const SECRETS: &[&str] = &[
    "PGPASSWORD",
    "SPOTIFY_CLIENT_SECRET",
    "SPOTIFY_ACCESS_TOKEN",
    "SPOTIFY_REFRESH_TOKEN",
];
pub trait Credentials: Send + Sync {
    fn get(&self, keys: &[&str]) -> Result<HashMap<String, Option<String>>, String>;
    fn set(&self, values: &HashMap<String, String>) -> Result<(), String>;
}
pub struct Broker {
    path: PathBuf,
    token: String,
}
impl Broker {
    pub fn from_environment() -> Self {
        Self {
            path: std::env::var_os("JARVIS_CREDENTIAL_SOCKET")
                .map(PathBuf::from)
                .unwrap_or_default(),
            token: std::env::var("JARVIS_CREDENTIAL_TOKEN").unwrap_or_default(),
        }
    }
    fn request(&self, mut payload: Value) -> Result<Value, String> {
        let unavailable = || {
            "Saved credentials are unavailable. Open Jarvis and unlock your login Keychain or update Connections.".to_string()
        };
        if self.token.is_empty() || self.path.as_os_str().is_empty() {
            return Err(unavailable());
        }
        payload["token"] = json!(self.token);
        let mut bytes = serde_json::to_vec(&payload).map_err(|_| unavailable())?;
        bytes.push(b'\n');
        if bytes.len() > 65536 {
            return Err(unavailable());
        }
        let mut socket = UnixStream::connect(&self.path).map_err(|_| unavailable())?;
        socket
            .set_read_timeout(Some(Duration::from_secs(90)))
            .map_err(|_| unavailable())?;
        socket
            .set_write_timeout(Some(Duration::from_secs(90)))
            .map_err(|_| unavailable())?;
        socket.write_all(&bytes).map_err(|_| unavailable())?;
        let mut response = Vec::new();
        let mut buf = [0u8; 4096];
        while response.len() <= 65536 && !response.contains(&b'\n') {
            let n = socket.read(&mut buf).map_err(|_| unavailable())?;
            if n == 0 {
                break;
            }
            response.extend_from_slice(&buf[..n]);
        }
        if response.len() > 65536 {
            return Err(unavailable());
        }
        let result: Value = serde_json::from_slice(&response).map_err(|_| unavailable())?;
        if result["ok"] != true {
            return Err(unavailable());
        }
        Ok(result)
    }
}
impl Credentials for Broker {
    fn get(&self, keys: &[&str]) -> Result<HashMap<String, Option<String>>, String> {
        if !keys.iter().all(|k| SECRETS.contains(k)) {
            return Err("Unsupported credential".into());
        }
        let v = self.request(json!({"operation":"get","keys":keys}))?;
        let map = v["values"]
            .as_object()
            .ok_or("Invalid credential response")?;
        let mut result = HashMap::new();
        for key in keys {
            let value = map.get(*key).unwrap_or(&Value::Null);
            if !value.is_null() && !value.is_string() {
                return Err("Invalid credential response".into());
            }
            result.insert(key.to_string(), value.as_str().map(str::to_owned));
        }
        Ok(result)
    }
    fn set(&self, values: &HashMap<String, String>) -> Result<(), String> {
        if !values.keys().all(|k| SECRETS.contains(&k.as_str())) {
            return Err("Unsupported credential".into());
        }
        self.request(json!({"operation":"set","values":values}))?;
        Ok(())
    }
}
pub struct Config<C: Credentials> {
    pub directory: PathBuf,
    pub credentials: C,
    pub defaults: HashMap<String, String>,
}
pub fn read_env(path: &Path) -> HashMap<String, String> {
    let mut result = HashMap::new();
    if let Ok(text) = fs::read_to_string(path) {
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let line = line.strip_prefix("export ").unwrap_or(line).trim_start();
            if let Some((key, value)) = line.split_once('=') {
                let mut value = value.trim();
                if value.len() >= 2
                    && ((value.starts_with('\'') && value.ends_with('\''))
                        || (value.starts_with('"') && value.ends_with('"')))
                {
                    value = &value[1..value.len() - 1];
                }
                if !key.trim().is_empty() {
                    result.insert(key.trim().to_owned(), value.to_owned());
                }
            }
        }
    }
    result
}
impl Config<Broker> {
    pub fn from_environment(backend: &Path, directory: PathBuf) -> Self {
        let mut defaults = read_env(&backend.join(".env"));
        let repo_env = std::env::var_os("JARVIS_ENV_FILE")
            .map(PathBuf::from)
            .unwrap_or_else(|| backend.parent().unwrap_or(backend).join(".env"));
        defaults.extend(read_env(&repo_env));
        defaults.extend(std::env::vars());
        Self {
            directory,
            credentials: Broker::from_environment(),
            defaults,
        }
    }
}
impl<C: Credentials> Config<C> {
    fn settings(&self) -> Result<HashMap<String, String>, String> {
        let path = self.directory.join("connection_settings.json");
        if !path.exists() {
            return Ok(HashMap::new());
        }
        let mut values: HashMap<String, String> = serde_json::from_slice(
            &fs::read(path).map_err(|_| "Could not read connection settings")?,
        )
        .map_err(|_| "Invalid Jarvis connection settings")?;
        values.retain(|k, _| !SECRETS.contains(&k.as_str()));
        Ok(values)
    }
    pub fn load(&self, keys: &[&str]) -> Result<HashMap<String, String>, String> {
        let mut values = self.defaults.clone();
        values.extend(self.settings()?);
        let fetched = self.credentials.get(keys)?;
        for key in keys {
            if let Some(Some(value)) = fetched.get(*key) {
                values.insert((*key).into(), value.clone());
            } else if let Some(value) = values.get(*key).filter(|s| !s.is_empty()) {
                self.credentials
                    .set(&HashMap::from([((*key).into(), value.clone())]))?;
            }
        }
        Ok(values)
    }
    pub fn save(&self, updates: HashMap<String, String>) -> Result<(), String> {
        fs::create_dir_all(&self.directory).map_err(|_| "Could not create settings directory")?;
        fs::set_permissions(&self.directory, fs::Permissions::from_mode(0o700))
            .map_err(|_| "Could not secure settings directory")?;
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(self.directory.join("connection_settings.lock"))
            .map_err(|_| "Could not lock settings")?;
        lock.lock_exclusive()
            .map_err(|_| "Could not lock settings")?;
        let mut settings = self.settings()?;
        let secrets = updates
            .iter()
            .filter(|(k, _)| SECRETS.contains(&k.as_str()))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect::<HashMap<_, _>>();
        if !secrets.is_empty() {
            self.credentials.set(&secrets)?;
        }
        settings.extend(
            updates
                .into_iter()
                .filter(|(k, _)| !SECRETS.contains(&k.as_str())),
        );
        let mut temp = tempfile::NamedTempFile::new_in(&self.directory)
            .map_err(|_| "Could not save settings")?;
        serde_json::to_writer(&mut temp, &settings).map_err(|_| "Could not encode settings")?;
        temp.flush().map_err(|_| "Could not save settings")?;
        temp.as_file()
            .sync_all()
            .map_err(|_| "Could not sync settings")?;
        temp.persist(self.directory.join("connection_settings.json"))
            .map_err(|_| "Could not activate settings")?;
        Ok(())
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::sync::Mutex;
    #[derive(Default)]
    pub struct FakeCredentials(pub Mutex<HashMap<String, String>>);
    impl Credentials for FakeCredentials {
        fn get(&self, keys: &[&str]) -> Result<HashMap<String, Option<String>>, String> {
            let v = self.0.lock().unwrap();
            Ok(keys
                .iter()
                .map(|k| ((*k).into(), v.get(*k).cloned()))
                .collect())
        }
        fn set(&self, values: &HashMap<String, String>) -> Result<(), String> {
            self.0.lock().unwrap().extend(values.clone());
            Ok(())
        }
    }
    #[test]
    fn settings_keep_secrets_out_of_json_and_merge() {
        let dir = tempfile::tempdir().unwrap();
        let config = Config {
            directory: dir.path().to_owned(),
            credentials: FakeCredentials::default(),
            defaults: HashMap::new(),
        };
        config
            .save(HashMap::from([
                ("PGPASSWORD".into(), "synthetic secret".into()),
                ("PGHOST".into(), "localhost".into()),
            ]))
            .unwrap();
        config
            .save(HashMap::from([(
                "SPOTIFY_CLIENT_ID".into(),
                "example".into(),
            )]))
            .unwrap();
        let raw = fs::read_to_string(dir.path().join("connection_settings.json")).unwrap();
        assert!(!raw.contains("synthetic secret"));
        let v = config.load(&["PGPASSWORD"]).unwrap();
        assert_eq!(v["PGHOST"], "localhost");
        assert_eq!(v["PGPASSWORD"], "synthetic secret");
        assert_eq!(
            fs::metadata(dir.path().join("connection_settings.json"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
    #[test]
    fn damaged_settings_are_not_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        fs::write(dir.path().join("connection_settings.json"), "damaged").unwrap();
        let config = Config {
            directory: dir.path().to_owned(),
            credentials: FakeCredentials::default(),
            defaults: HashMap::new(),
        };
        assert!(config.save(HashMap::new()).is_err());
        assert_eq!(
            fs::read_to_string(dir.path().join("connection_settings.json")).unwrap(),
            "damaged"
        );
    }
    #[test]
    fn env_is_data_not_code() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.env");
        fs::write(
            &path,
            "export EXAMPLE='$(echo unsafe)'\n# comment\nLABEL=with spaces\n",
        )
        .unwrap();
        let v = read_env(&path);
        assert_eq!(v["EXAMPLE"], "$(echo unsafe)");
        assert_eq!(v["LABEL"], "with spaces");
    }
}
