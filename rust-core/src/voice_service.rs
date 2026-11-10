//! Bounded, serialized voice work and compatible saved enrollments. No model
//! loads for stats, reset, or verification when no voice has been enrolled.
use crate::{backend_services::ApiError, native_voice::VoiceEngine, voice_profiles};
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};
struct Loaded {
    engine: Option<VoiceEngine>,
    last_activity: Instant,
}
pub struct VoiceService {
    model: PathBuf,
    runtime: PathBuf,
    profile: PathBuf,
    loaded: Mutex<Loaded>,
    admitted: AtomicUsize,
}
struct Admission<'a>(&'a AtomicUsize);
impl Drop for Admission<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}
impl VoiceService {
    pub fn new(model: PathBuf, runtime: PathBuf, profile: PathBuf) -> Self {
        Self {
            model,
            runtime,
            profile,
            loaded: Mutex::new(Loaded {
                engine: None,
                last_activity: Instant::now(),
            }),
            admitted: AtomicUsize::new(0),
        }
    }
    pub fn stats(&self) -> Result<Value, ApiError> {
        let profiles = voice_profiles::load(&self.profile)
            .map_err(|_| ApiError::new(500, "Invalid voice profile"))?;
        Ok(json!({"enrolled_count":profiles.len()}))
    }
    pub fn run(&self, operation: &str, audio: &[u8]) -> Result<Value, ApiError> {
        self.admitted
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                if n < 2 {
                    Some(n + 1)
                } else {
                    None
                }
            })
            .map_err(|_| ApiError::new(503, "Voice service busy; try again shortly"))?;
        let _admission = Admission(&self.admitted);
        let mut loaded = self
            .loaded
            .lock()
            .map_err(|_| ApiError::new(503, "Voice service busy; try again shortly"))?;
        loaded.last_activity = Instant::now();
        if operation == "reset" {
            voice_profiles::save(&self.profile, &[])
                .map_err(|_| ApiError::new(500, "Could not reset voice profile"))?;
            return Ok(json!({"enrolled_count":0}));
        }
        let mut profiles = voice_profiles::load(&self.profile)
            .map_err(|_| ApiError::new(500, "Invalid voice profile"))?;
        if operation == "verify" && profiles.is_empty() {
            return Ok(voice_profiles::score(&[]));
        }
        if audio.is_empty() {
            return Err(ApiError::new(400, "Empty audio file"));
        }
        if audio.len() > 10 * 1024 * 1024 {
            return Err(ApiError::new(413, "Audio file exceeds 10 MB"));
        }
        if loaded.engine.is_none() {
            loaded.engine = Some(
                VoiceEngine::load(&self.model, &self.runtime)
                    .map_err(|_| ApiError::new(503, "Voice model unavailable"))?,
            );
        }
        let result = loaded.engine.as_mut().unwrap().embed(audio).map_err(|_| {
            ApiError::new(
                400,
                if operation == "enroll" {
                    "Enrollment failed: unsupported, silent or invalid audio"
                } else {
                    "Verification failed: unsupported, silent or invalid audio"
                },
            )
        })?;
        let candidate: Vec<f32> = serde_json::from_value(result["embedding"].clone())
            .map_err(|_| ApiError::new(500, "Invalid voice output"))?;
        if operation == "enroll" {
            profiles.push(candidate);
            voice_profiles::save(&self.profile, &profiles)
                .map_err(|_| ApiError::new(500, "Could not save voice profile"))?;
            Ok(json!({"enrolled_count":profiles.len()}))
        } else if operation == "verify" {
            Ok(voice_profiles::score(
                &profiles
                    .iter()
                    .map(|profile| voice_profiles::cosine(&candidate, profile))
                    .collect::<Vec<_>>(),
            ))
        } else {
            Err(ApiError::new(404, "Unknown voice operation"))
        }
    }
    pub fn unload_if_idle(&self) {
        if let Ok(mut loaded) = self.loaded.try_lock() {
            if loaded.last_activity.elapsed() >= Duration::from_secs(300) {
                loaded.engine = None;
            }
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn admits_only_one_running_and_one_waiting_job() {
        let dir = tempfile::tempdir().unwrap();
        let service = VoiceService::new(
            "missing".into(),
            "missing".into(),
            dir.path().join("voice.npy"),
        );
        let lock = service.loaded.lock().unwrap();
        std::thread::scope(|scope| {
            let first = scope.spawn(|| service.run("reset", &[]));
            let second = scope.spawn(|| service.run("reset", &[]));
            let deadline = Instant::now() + Duration::from_secs(2);
            while service.admitted.load(Ordering::SeqCst) < 2 && Instant::now() < deadline {
                std::thread::yield_now();
            }
            assert_eq!(service.admitted.load(Ordering::SeqCst), 2);
            assert_eq!(service.run("reset", &[]).unwrap_err().status, 503);
            drop(lock);
            assert!(first.join().unwrap().is_ok());
            assert!(second.join().unwrap().is_ok());
        });
        assert_eq!(service.admitted.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn no_profile_verification_stats_and_reset_do_not_load_models() {
        let dir = tempfile::tempdir().unwrap();
        let service = VoiceService::new(
            "missing".into(),
            "missing".into(),
            dir.path().join("voice.npy"),
        );
        assert_eq!(service.stats().unwrap()["enrolled_count"], 0);
        assert_eq!(
            service.run("verify", b"unneeded").unwrap()["confidence"],
            "none"
        );
        assert_eq!(service.run("reset", &[]).unwrap()["enrolled_count"], 0);
        assert!(service.loaded.lock().unwrap().engine.is_none());
    }
}
