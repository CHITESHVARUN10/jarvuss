//! Port of Swift `IntentModelRouter` + `IntentModelClient` — HTTP client for
//! the learned intent model (`POST /parse_intent`), confidence gate, strict
//! intent mapping, and hit/miss logging into the RL corpus.

use crate::actions::PlannedAction;
use crate::intent_mapper;
use crate::rl_log;
use serde_json::{json, Value};
use std::time::{Duration, Instant};

/// Minimum mean token-probability for a model answer to be trusted.
pub const CONFIDENCE_THRESHOLD: f64 = 0.75;

/// Outcome of one routing attempt. `hit == false` means the caller must fall
/// through to the rule pipeline (the miss has already been logged).
#[derive(Debug, Clone, uniffi::Record)]
pub struct IntentRouteOutcome {
    pub actions: Vec<PlannedAction>,
    pub hit: bool,
    /// Miss reason: "parse_fail" | "low_confidence" | "unmappable" |
    /// "unavailable" | "disabled" | "empty".
    pub reason: Option<String>,
    pub confidence: f64,
    pub latency_ms: i64,
    pub total_ms: i64,
    pub raw: String,
}

fn is_enabled() -> bool {
    match std::env::var("JARVIS_INTENT_MODEL") {
        Ok(v) => {
            let v = v.to_lowercase();
            v != "off" && v != "0" && v != "false"
        }
        Err(_) => true,
    }
}

fn base_url(explicit: Option<String>) -> String {
    explicit
        .filter(|s| !s.is_empty())
        .or_else(|| std::env::var("JARVIS_BACKEND_URL").ok())
        .or_else(|| std::env::var("BACKEND_BASE_URL").ok())
        .unwrap_or_else(|| "http://127.0.0.1:8000".to_string())
}

fn miss(reason: &str, confidence: f64, total_ms: i64, raw: &str) -> IntentRouteOutcome {
    IntentRouteOutcome {
        actions: vec![],
        hit: false,
        reason: Some(reason.to_string()),
        confidence,
        latency_ms: 0,
        total_ms,
        raw: raw.to_string(),
    }
}

/// Route an utterance through the learned intent model.
/// Reads `JARVIS_INTENT_MODEL` / `JARVIS_BACKEND_URL` like the Swift client.
pub fn route_intent(text: &str, request_id: &str, explicit_base: Option<String>) -> IntentRouteOutcome {
    let start = Instant::now();
    if !is_enabled() {
        return miss("disabled", 0.0, 0, "");
    }
    if text.trim().is_empty() {
        return miss("empty", 0.0, 0, "");
    }

    let body = match post_parse_intent(&base_url(explicit_base), text) {
        Ok(body) => body,
        Err(err) => {
            let total_ms = start.elapsed().as_millis() as i64;
            log_miss(text, request_id, "unavailable", &err, 0.0, total_ms);
            return miss("unavailable", 0.0, total_ms, &err);
        }
    };

    let parsed: Value = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(_) => {
            let total_ms = start.elapsed().as_millis() as i64;
            log_miss(text, request_id, "parse_fail", &body, 0.0, total_ms);
            return miss("parse_fail", 0.0, total_ms, &body);
        }
    };

    let actions_json = parsed
        .get("actions")
        .cloned()
        .unwrap_or_else(|| json!([]));
    let confidence = parsed
        .get("confidence")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let parse_ok = parsed
        .get("parse_ok")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let raw = parsed
        .get("raw")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let latency_ms = parsed
        .get("latency_ms")
        .and_then(Value::as_i64)
        .unwrap_or(0);

    let total_ms = start.elapsed().as_millis() as i64;
    let empty_actions = actions_json
        .as_array()
        .map(|a| a.is_empty())
        .unwrap_or(true);

    if !parse_ok || empty_actions {
        log_miss(text, request_id, "parse_fail", &raw, confidence, total_ms);
        return miss("parse_fail", confidence, total_ms, &raw);
    }
    if confidence < CONFIDENCE_THRESHOLD {
        log_miss(text, request_id, "low_confidence", &raw, confidence, total_ms);
        return miss("low_confidence", confidence, total_ms, &raw);
    }
    let actions = match intent_mapper::map_intents(&actions_json) {
        Some(actions) => actions,
        None => {
            log_miss(text, request_id, "unmappable", &raw, confidence, total_ms);
            return miss("unmappable", confidence, total_ms, &raw);
        }
    };

    rl_log::append(
        &json!({
            "event": "model_hit",
            "request_id": request_id,
            "text": text,
            "raw": raw,
            "actions": actions_json,
            "confidence": confidence,
            "latency_ms": latency_ms,
            "total_ms": total_ms,
        })
        .to_string(),
    );

    IntentRouteOutcome {
        actions,
        hit: true,
        reason: None,
        confidence,
        latency_ms,
        total_ms,
        raw,
    }
}

fn log_miss(
    text: &str,
    request_id: &str,
    reason: &str,
    raw: &str,
    confidence: f64,
    total_ms: i64,
) {
    rl_log::append(
        &json!({
            "event": "model_miss",
            "request_id": request_id,
            "text": text,
            "reason": reason,
            "raw": raw,
            "confidence": confidence,
            "total_ms": total_ms,
        })
        .to_string(),
    );
}

fn post_parse_intent(base: &str, text: &str) -> Result<String, String> {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(3))
        .build()
        .map_err(|e| e.to_string())?;
    let url = format!("{}/parse_intent", base.trim_end_matches('/'));
    let response = client
        .post(&url)
        .json(&json!({ "text": text }))
        .send()
        .map_err(|e| e.to_string())?;
    let status = response.status();
    if !status.is_success() {
        return Err(format!("badStatus({})", status.as_u16()));
    }
    response.text().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disabled_env_short_circuits() {
        // Not setting the env var here (defaults to enabled), so assert the
        // empty-text guard instead — no network in unit tests.
        let outcome = route_intent("   ", "test-req", None);
        assert!(!outcome.hit);
        assert_eq!(outcome.reason.as_deref(), Some("empty"));
    }

    #[test]
    fn unreachable_backend_is_a_miss() {
        // Port 9 is discard — connection refused fast.
        let outcome = route_intent("open chrome", "test-req", Some("http://127.0.0.1:9".to_string()));
        assert!(!outcome.hit);
        assert_eq!(outcome.reason.as_deref(), Some("unavailable"));
    }
}
