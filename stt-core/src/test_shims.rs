//! Test-only shims for the `extern "Swift"` callbacks.
//!
//! `cargo test` links the crate without Swift, so the five
//! `__swift_bridge__$...` symbols implemented by the app's
//! BridgeCallbacks.swift would otherwise be undefined. These no-op
//! shims satisfy the linker; unit tests never assert on callbacks.
//!
//! Lives in its own file because swift-bridge-build parses src/lib.rs
//! textually and chokes on `$` in function names (`#[export_name]`
//! carries the real symbol since `$` is not a valid Rust identifier).

use crate::ffi::{AppPhase, ModelPhase};

#[export_name = "__swift_bridge__$on_state_changed"]
pub extern "C" fn test_on_state_changed(_phase: AppPhase, _model: ModelPhase) {
}

#[export_name = "__swift_bridge__$on_transcript_ready"]
pub extern "C" fn test_on_transcript_ready(_text: *mut std::ffi::c_void) {
}

#[export_name = "__swift_bridge__$on_partial_transcript"]
pub extern "C" fn test_on_partial_transcript(_text: *mut std::ffi::c_void) {
}

#[export_name = "__swift_bridge__$on_error"]
pub extern "C" fn test_on_error(_message: *mut std::ffi::c_void) {
}

#[export_name = "__swift_bridge__$on_download_progress"]
pub extern "C" fn test_on_download_progress(
    _progress: f32,
    _speed: *mut std::ffi::c_void,
    _remaining: *mut std::ffi::c_void,
) {
}
