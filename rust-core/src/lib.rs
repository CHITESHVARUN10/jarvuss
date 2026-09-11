//! Jarvis core engine — Rust port of the Swift command pipeline.
//!
//! Phase 1 scope: pure logic only (no mic, no Apple frameworks, no network).
//! - [`plan_command`] mirrors `ActionPlanner.plan(from:)` rule path.
//! - [`safety`] mirrors `SafetyGuard`.
//! - [`validator`] mirrors `CommandValidator`.
//! - [`alias`] mirrors `AppAliasResolver`.
//!
//! Hardware execution (volume/display/app/file) and the Ollama HTTP fallback
//! stay in Swift for Phase 1; this crate guarantees intent parity via tests.

pub mod actions;
pub mod alias;
pub mod planner;
pub mod safety;
pub mod validator;

pub use actions::{DisplayAction, MediaAction, PlannedAction, SystemInfoAction, VolumeAction};
pub use safety::{SafetyVerdict, validate_action, validate_raw};
pub use validator::validate as validate_command;

uniffi::setup_scaffolding!();

/// Plan a raw command string into ordered actions.
/// Exported to Swift via UniFFI once bindings are generated.
#[uniffi::export]
pub fn plan_command(raw: String) -> Vec<PlannedAction> {
    planner::plan(&raw)
}

/// Validate a raw command string (cleaned form or rejection).
#[uniffi::export]
pub fn validate_command_string(raw: String) -> Option<String> {
    validator::validate(&raw)
}

/// Resolve a spoken app name to its canonical macOS name.
#[uniffi::export]
pub fn resolve_app(name: String) -> String {
    alias::resolve(&name)
}
