//! Port of Swift `IntentRouterLog` — append-only JSONL writer for the
//! learned-intent-router RL corpus.
//!
//! Every event (model hit/miss, plan branch, execute outcome, parity check)
//! is one line: `{...fields, "ts": "<iso8601>"}` with sorted keys.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};

static WRITE_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn lock() -> &'static Mutex<()> {
    WRITE_LOCK.get_or_init(|| Mutex::new(()))
}

pub fn log_path() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_default();
    home.join("Library/Application Support/Jarvis/logs/intent_router.jsonl")
}

/// Append one event (a JSON object) with a timestamp. Returns false on
/// malformed input or I/O failure — logging must never break the pipeline.
pub fn append(event_json: &str) -> bool {
    let value: serde_json::Value = match serde_json::from_str(event_json) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let mut object = match value.as_object() {
        Some(o) => o.clone(),
        None => return false,
    };
    object.insert(
        "ts".to_string(),
        serde_json::Value::String(iso8601_now()),
    );
    // BTreeMap → keys serialized in sorted order (Swift logs `.sortedKeys`).
    let sorted: std::collections::BTreeMap<String, serde_json::Value> =
        object.into_iter().collect();
    let line = match serde_json::to_string(&sorted) {
        Ok(s) => s,
        Err(_) => return false,
    };
    write_line(&line)
}

fn write_line(line: &str) -> bool {
    let path = log_path();
    if let Some(parent) = path.parent() {
        if fs::create_dir_all(parent).is_err() {
            return false;
        }
    }
    let _guard = lock().lock().unwrap_or_else(|e| e.into_inner());
    let mut file = match OpenOptions::new().create(true).append(true).open(&path) {
        Ok(f) => f,
        Err(_) => return false,
    };
    file.write_all(line.as_bytes()).is_ok() && file.write_all(b"\n").is_ok()
}

fn iso8601_now() -> String {
    chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_sorted_line() {
        // Sanity: the transform keeps only object input and injects ts.
        assert!(!append("not json"));
        assert!(!append("[1,2,3]"));
    }

    #[test]
    fn writes_and_reads_back() {
        // Unique event so the assertion is stable against prior runs.
        let marker = format!("test_marker_{}", std::process::id());
        assert!(append(&format!(
            r#"{{"event":"test","marker":"{marker}"}}"#
        )));
        let content = fs::read_to_string(log_path()).unwrap_or_default();
        let line = content
            .lines()
            .rev()
            .find(|l| l.contains(&marker))
            .expect("line written");
        assert!(line.contains("\"ts\":"));
        assert!(line.contains("\"event\":\"test\""));
    }
}
