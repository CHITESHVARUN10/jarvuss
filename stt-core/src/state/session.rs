use std::sync::atomic::{AtomicU64, Ordering};

/// Identifies recordings across queued work and callbacks. Abandoning a
/// recording invalidates its results even when Whisper cannot be interrupted.
pub struct SessionEpoch(AtomicU64);

impl SessionEpoch {
    pub const fn new() -> Self {
        Self(AtomicU64::new(0))
    }
    pub fn current(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
    pub fn advance(&self) -> u64 {
        self.0.fetch_add(1, Ordering::SeqCst) + 1
    }
    pub fn is_current(&self, id: u64) -> bool {
        self.current() == id
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cancellation_and_restart_invalidate_old_recording() {
        let epoch = SessionEpoch::new();
        let first = epoch.advance();
        assert!(epoch.is_current(first));
        epoch.advance(); // cancellation
        assert!(!epoch.is_current(first));
        let second = epoch.advance();
        assert!(epoch.is_current(second));
        assert!(!epoch.is_current(first));
    }
}
