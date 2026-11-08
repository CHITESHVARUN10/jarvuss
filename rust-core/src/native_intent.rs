//! Native, lazy T5 inference. Numerical kernels stay in ONNX Runtime; the
//! tokenizer, greedy decode and KV ownership mirror the Python reference.
use crate::intent_store::{self, Receipt};
use ort::{
    environment::Environment,
    session::{
        builder::{AutoDevicePolicy, GraphOptimizationLevel},
        Session,
    },
    value::{DynValue, Tensor},
};
use sentencepiece::SentencePieceProcessor;
use serde::Serialize;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    path::Path,
    sync::{Mutex, OnceLock, TryLockError},
    time::{Duration, Instant},
};

type Result<T> = std::result::Result<T, String>;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
static ENV: OnceLock<std::result::Result<Environment, String>> = OnceLock::new();
pub(crate) fn environment(library: &Path) -> Result<&'static Environment> {
    if !library.is_file() {
        return Err("native inference runtime is not installed".into());
    }
    ENV.get_or_init(|| {
        ort::init_from(library)
            .map_err(err)?
            .with_telemetry(false)
            .build()
            .map_err(err)
    })
    .as_ref()
    .map_err(Clone::clone)
}

pub struct Engine {
    enc: Session,
    dec: Session,
    sp: SentencePieceProcessor,
    added: HashMap<char, i64>,
    reverse: HashMap<i64, String>,
    layers: usize,
    heads: i64,
    d_kv: i64,
    start: i64,
}
#[derive(Debug, Serialize)]
pub struct Generation {
    pub raw: String,
    pub confidence: f64,
    pub input_ids: Vec<i64>,
    pub generated_ids: Vec<i64>,
}
impl Engine {
    pub fn load(folder: &Path, library: &Path) -> Result<Self> {
        let cfg: Value =
            serde_json::from_slice(&fs::read(folder.join("config.json")).map_err(err)?)
                .map_err(err)?;
        let integer = |k: &str| {
            cfg[k]
                .as_i64()
                .filter(|n| *n > 0 && *n <= 4096)
                .ok_or_else(|| format!("invalid {k}"))
        };
        let added: HashMap<String, i64> =
            serde_json::from_slice(&fs::read(folder.join("added_tokens.json")).map_err(err)?)
                .map_err(err)?;
        let reverse = added.iter().map(|(k, v)| (*v, k.clone())).collect();
        let mut chars = HashMap::new();
        for (k, v) in added {
            let mut it = k.chars();
            let ch = it.next().ok_or("empty added token")?;
            if it.next().is_some() || v < 0 {
                return Err("unsupported added token".into());
            }
            chars.insert(ch, v);
        }
        let env = environment(library)?;
        let threads = std::env::var("JARVIS_INTENT_THREADS")
            .ok()
            .and_then(|value| value.parse::<usize>().ok())
            .filter(|value| (1..=64).contains(value))
            .unwrap_or_else(|| {
                (std::thread::available_parallelism()
                    .map(usize::from)
                    .unwrap_or(4)
                    / 2)
                .max(1)
            });
        // ORT's CPU arena can grow pathologically (observed >2 GB with two
        // threads). Per-run allocation keeps memory stable with no measured
        // latency cost; opt back in with JARVIS_INTENT_ARENA=1.
        let arena = std::env::var("JARVIS_INTENT_ARENA")
            .map(|value| !matches!(value.as_str(), "0" | "false" | "off"))
            .unwrap_or(false);
        let session = || {
            Session::builder(env)
                .map_err(err)?
                // ort defaults to auto-selecting CoreML on macOS; Python explicitly
                // uses CPU. Pin CPU to preserve quantization and confidence scores.
                .with_auto_device(AutoDevicePolicy::PreferCPU)
                .map_err(err)?
                .with_execution_providers([ort::ep::CPU::default()
                    .with_arena_allocator(arena)
                    .build()])
                .map_err(err)?
                .with_optimization_level(GraphOptimizationLevel::All)
                .map_err(err)?
                .with_intra_threads(threads)
                .map_err(err)
        };
        Ok(Self {
            enc: session()?
                .commit_from_file(folder.join("encoder_model_quantized.onnx"))
                .map_err(err)?,
            dec: session()?
                .commit_from_file(folder.join("decoder_model_merged_quantized.onnx"))
                .map_err(err)?,
            sp: SentencePieceProcessor::open(folder.join("spiece.model")).map_err(err)?,
            added: chars,
            reverse,
            layers: integer("num_decoder_layers")? as usize,
            heads: integer("num_heads")?,
            d_kv: integer("d_kv")?,
            start: cfg["decoder_start_token_id"].as_i64().unwrap_or(0),
        })
    }
    pub fn encode(&self, text: &str) -> Result<Vec<i64>> {
        let mut ids = Vec::new();
        let mut buf = String::new();
        for ch in text.chars() {
            if let Some(id) = self.added.get(&ch) {
                self.flush_encode(&mut buf, &mut ids)?;
                ids.push(*id);
            } else {
                buf.push(ch);
            }
        }
        self.flush_encode(&mut buf, &mut ids)?;
        if ids.len() >= 128 {
            return Err("input_too_long".into());
        }
        ids.push(1);
        Ok(ids)
    }
    fn flush_encode(&self, buf: &mut String, ids: &mut Vec<i64>) -> Result<()> {
        if !buf.is_empty() {
            ids.extend(
                self.sp
                    .encode(buf)
                    .map_err(err)?
                    .into_iter()
                    .map(|p| i64::from(p.id)),
            );
            buf.clear();
        }
        Ok(())
    }
    pub fn decode(&self, ids: &[i64]) -> Result<String> {
        let mut parts = String::new();
        let mut buf = Vec::new();
        let flush = |buf: &mut Vec<u32>, parts: &mut String| -> Result<()> {
            if !buf.is_empty() {
                parts.push_str(&self.sp.decode_piece_ids(buf).map_err(err)?);
                buf.clear();
            }
            Ok(())
        };
        for id in ids {
            if *id == 1 {
                break;
            }
            if let Some(s) = self.reverse.get(id) {
                flush(&mut buf, &mut parts)?;
                parts.push_str(s);
            } else if *id != 0 && *id != 2 {
                buf.push(u32::try_from(*id).map_err(err)?);
            }
        }
        flush(&mut buf, &mut parts)?;
        Ok(parts.trim_matches(python_whitespace).to_owned())
    }
    pub fn generate(&mut self, text: &str) -> Result<Generation> {
        self.generate_until(text, None)
    }
    fn generate_until(&mut self, text: &str, deadline: Option<Instant>) -> Result<Generation> {
        let ids = self.encode(&format!("parse: {text}"))?;
        let len = ids.len();
        let mask = Tensor::from_array(([1, len], vec![1i64; len]))
            .map_err(err)?
            .into_dyn();
        let mut outputs=self.enc.run(ort::inputs!["input_ids"=>Tensor::from_array(([1,len],ids.clone())).map_err(err)?,"attention_mask"=>&mask]).map_err(err)?;
        let first = outputs
            .keys()
            .next()
            .ok_or("missing encoder output")?
            .to_string();
        let hidden = outputs.remove(&first).ok_or("missing encoder output")?;
        drop(outputs);
        let mut feed: HashMap<String, DynValue> = HashMap::new();
        feed.insert("encoder_attention_mask".into(), mask);
        feed.insert("encoder_hidden_states".into(), hidden);
        for layer in 0..self.layers {
            for kind in ["decoder", "encoder"] {
                for slot in ["key", "value"] {
                    feed.insert(
                        format!("past_key_values.{layer}.{kind}.{slot}"),
                        Tensor::from_array(([1, self.heads, 0, self.d_kv], Vec::<f32>::new()))
                            .map_err(err)?
                            .into_dyn(),
                    );
                }
            }
        }
        let mut generated = Vec::new();
        let mut logprobs = Vec::new();
        let mut current = self.start;
        for step in 0..448 {
            if deadline.is_some_and(|t| Instant::now() >= t) {
                return Err("intent inference timed out".into());
            }
            feed.insert(
                "input_ids".into(),
                Tensor::from_array(([1, 1], vec![current]))
                    .map_err(err)?
                    .into_dyn(),
            );
            feed.insert(
                "use_cache_branch".into(),
                Tensor::from_array(([1], vec![step > 0]))
                    .map_err(err)?
                    .into_dyn(),
            );
            let inputs: Vec<_> = feed.iter().map(|(k, v)| (k.as_str(), v)).collect();
            let mut out = self.dec.run(inputs).map_err(err)?;
            let logits = out.get("logits").ok_or("missing decoder logits")?;
            let (shape, values) = logits.try_extract_tensor::<f32>().map_err(err)?;
            let n = *shape.last().ok_or("invalid logits shape")? as usize;
            if n == 0 || values.len() < n {
                return Err("invalid decoder logits".into());
            }
            let scores = &values[values.len() - n..];
            let (next, logp) = argmax_logprob(scores)?;
            if next == 1 {
                drop(out);
                return Ok(Generation {
                    raw: self.decode(&generated)?,
                    confidence: if logprobs.is_empty() {
                        0.0
                    } else {
                        (logprobs.iter().sum::<f64>() / logprobs.len() as f64).exp()
                    },
                    input_ids: ids,
                    generated_ids: generated,
                });
            }
            generated.push(next);
            logprobs.push(logp);
            current = next;
            for layer in 0..self.layers {
                for kind in ["decoder", "encoder"] {
                    if step > 0 && kind == "encoder" {
                        continue;
                    }
                    for slot in ["key", "value"] {
                        let key = format!("present.{layer}.{kind}.{slot}");
                        feed.insert(
                            format!("past_key_values.{layer}.{kind}.{slot}"),
                            out.remove(&key).ok_or_else(|| format!("missing {key}"))?,
                        );
                    }
                }
            }
        }
        Ok(Generation {
            raw: String::new(),
            confidence: 0.0,
            input_ids: ids,
            generated_ids: generated,
        })
    }
}
fn argmax_logprob(scores: &[f32]) -> Result<(i64, f64)> {
    if scores.is_empty() || scores.iter().any(|v| !v.is_finite()) {
        return Err("invalid decoder scores".into());
    }
    // First index wins ties, matching numpy.argmax. Confidence uses float64.
    let mut best = 0;
    for i in 1..scores.len() {
        if scores[i] > scores[best] {
            best = i;
        }
    }
    let peak = f64::from(scores[best]);
    let sum = scores
        .iter()
        .map(|v| (f64::from(*v) - peak).exp())
        .sum::<f64>();
    Ok((best as i64, peak - (peak + sum.ln())))
}

#[derive(Default)]
struct State {
    key: String,
    engine: Option<Engine>,
    active: Value,
    update_error: Option<String>,
    last_activity: Option<Instant>,
    cache: Vec<(String, String)>,
}

const CACHE_LIMIT: usize = 64;

fn cache_get<'a>(cache: &'a [(String, String)], text: &str) -> Option<&'a str> {
    cache
        .iter()
        .find(|(key, _)| key == text)
        .map(|(_, value)| value.as_str())
}

fn cache_put(cache: &mut Vec<(String, String)>, text: String, value: String) {
    if cache.iter().any(|(key, _)| *key == text) {
        return;
    }
    if cache.len() >= CACHE_LIMIT {
        cache.remove(0);
    }
    cache.push((text, value));
}

fn cache_enabled() -> bool {
    std::env::var("JARVIS_INTENT_CACHE")
        .map(|value| !matches!(value.as_str(), "0" | "false" | "off"))
        .unwrap_or(true)
}
static STATE: OnceLock<Mutex<State>> = OnceLock::new();
impl State {
    fn load(&mut self, bundled: &Path, data: &Path, library: &Path) -> Result<()> {
        let root = data.join("models/intent");
        let override_dir = std::env::var_os("JARVIS_INTENT_MODEL_DIR");
        let desired = if override_dir.is_none() {
            intent_store::receipt(&root, "current.json")
        } else {
            None
        };
        let configured = override_dir
            .as_ref()
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| bundled.to_owned());
        let key = format!(
            "{}:{}:{}",
            root.display(),
            configured.display(),
            serde_json::to_string(&desired).map_err(err)?
        );
        if self.key == key {
            return if self.engine.is_some() {
                Ok(())
            } else {
                Err("intent model unavailable".into())
            };
        }
        self.key = key;
        self.cache.clear();
        self.update_error = None;
        let mut choices: Vec<(Option<Receipt>, &str)> = Vec::new();
        if let Some(r) = desired.clone() {
            choices.push((Some(r), "downloaded"));
        }
        if override_dir.is_none() {
            if let Some(r) = intent_store::receipt(&root, "last-good.json") {
                if Some(&r) != desired.as_ref() {
                    choices.push((Some(r), "previous downloaded"));
                }
            }
        }
        choices.push((
            None,
            if override_dir.is_some() {
                "configured"
            } else {
                "bundled"
            },
        ));
        for (selected, source) in choices {
            if selected.is_none() && self.engine.is_some() {
                return Ok(());
            }
            let result: Result<Engine> = (|| {
                let folder = if let Some(r) = &selected {
                    intent_store::verify(&root, r)?
                } else {
                    configured.clone()
                };
                let mut e = Engine::load(&folder, library)?;
                if selected.is_some() {
                    let warm = e.generate("pause")?;
                    let v: Value = serde_json::from_str(&warm.raw).map_err(err)?;
                    if !v.as_array().is_some_and(|a| {
                        !a.is_empty() && a.iter().all(|i| i.is_object() && i["name"].is_string())
                    }) {
                        return Err("model warm-up failed".into());
                    }
                }
                Ok(e)
            })();
            match result {
                Ok(e) => {
                    self.engine = Some(e);
                    self.active = json!({"source":source,"version":selected.as_ref().map(|r|&r.version),"commit":selected.as_ref().map(|r|&r.commit)});
                    if let Some(r) = &selected {
                        let _ = intent_store::remember_good(&root, r);
                    }
                    return Ok(());
                }
                Err(_) => {
                    if selected.is_some() {
                        self.update_error=Some("The downloaded model failed validation; the previous model remains in use when available.".into());
                    }
                    if self.engine.is_some() {
                        return Ok(());
                    }
                }
            }
        }
        Err("intent model unavailable or incompatible".into())
    }
}
pub fn parse(text: &str, bundled: &Path, data: &Path, library: &Path) -> Result<String> {
    if text.chars().count() > 4096 {
        return Err("text exceeds 4096 characters".into());
    }
    let text = text.trim_matches(python_whitespace);
    if text.is_empty() {
        return Err("text is required".into());
    }
    let mut state = match STATE.get_or_init(Default::default).try_lock() {
        Ok(s) => s,
        Err(TryLockError::WouldBlock) => return Err("Intent model busy".into()),
        Err(_) => return Err("intent model unavailable".into()),
    };
    let start = Instant::now();
    state.last_activity = Some(start);
    state.load(bundled, data, library)?;
    if cache_enabled() {
        if let Some(cached) = cache_get(&state.cache, text) {
            if let Ok(mut value) = serde_json::from_str::<Value>(cached) {
                value["latency_ms"] = json!(0);
                value["cached"] = json!(true);
                return Ok(value.to_string());
            }
        }
    }
    let g=match state.engine.as_mut().ok_or("intent model unavailable")?.generate_until(text,Some(start+Duration::from_secs(2))){Ok(g)=>g,Err(e)if e=="input_too_long"=>return Ok(json!({"actions":null,"parse_ok":false,"confidence":0,"raw":"","latency_ms":0,"reason":e}).to_string()),Err(e)=>return Err(e)};
    let actions: Option<Value> = serde_json::from_str::<Value>(&g.raw).ok().filter(|v| {
        v.as_array()
            .is_some_and(|a| !a.is_empty() && a.iter().all(Value::is_object))
    });
    let parse_ok = actions.is_some();
    let confidence = (g.confidence * 10000.0).round_ties_even() / 10000.0;
    let response = json!({"actions":actions,"parse_ok":parse_ok,"raw":g.raw,"confidence":confidence,"latency_ms":start.elapsed().as_millis()}).to_string();
    if cache_enabled() && parse_ok {
        cache_put(&mut state.cache, text.to_string(), response.clone());
    }
    Ok(response)
}
pub fn status() -> String {
    let Ok(state) = STATE.get_or_init(Default::default).try_lock() else {
        return json!({"busy":true}).to_string();
    };
    let mut v = if state.active.is_object() {
        state.active.clone()
    } else {
        json!({"source":"not loaded"})
    };
    v["loaded"] = json!(state.engine.is_some());
    v["update_error"] = json!(state.update_error);
    v.to_string()
}

fn python_whitespace(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

pub fn unload_if_idle(seconds: u64) -> bool {
    let Ok(mut state) = STATE.get_or_init(Default::default).try_lock() else {
        return false;
    };
    if state.engine.is_none()
        || !state
            .last_activity
            .is_some_and(|t| t.elapsed().as_secs() >= seconds)
    {
        return false;
    }
    *state = State::default();
    release_free_pages();
    true
}

/// Ask macOS to return free pages after a large model drop. Without this the
/// allocator can keep the session's pages resident long after the model is
/// gone, which makes the footprint look unchanged.
#[cfg(target_os = "macos")]
fn release_free_pages() {
    unsafe extern "C" {
        fn malloc_zone_pressure_relief(zone: *mut std::ffi::c_void, goal: usize) -> usize;
    }
    unsafe {
        malloc_zone_pressure_relief(std::ptr::null_mut(), 0);
    }
}

#[cfg(not(target_os = "macos"))]
fn release_free_pages() {}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn argmax_ties_and_confidence() {
        let (n, p) = argmax_logprob(&[1.0, 1.0, 0.0]).unwrap();
        assert_eq!(n, 0);
        assert!((p.exp() - 1.0 / (2.0 + (-1.0f64).exp())).abs() < 1e-12);
        assert!(argmax_logprob(&[f32::NAN]).is_err());
    }
    #[test]
    fn cache_is_bounded_and_deduplicates() {
        let mut cache = Vec::new();
        for index in 0..100 {
            cache_put(&mut cache, format!("t{index}"), format!("v{index}"));
        }
        assert_eq!(cache.len(), CACHE_LIMIT);
        assert_eq!(cache_get(&cache, "t99"), Some("v99"));
        cache_put(&mut cache, "t99".into(), "new".into());
        assert_eq!(cache_get(&cache, "t99"), Some("v99"));
        assert_eq!(cache_get(&cache, "missing"), None);
    }

    #[test]
    fn rejects_input_without_loading() {
        assert!(parse(
            "",
            Path::new("missing"),
            Path::new("missing"),
            Path::new("missing")
        )
        .is_err());
        assert!(parse(
            &"x".repeat(4097),
            Path::new("missing"),
            Path::new("missing"),
            Path::new("missing")
        )
        .is_err());
    }
}
