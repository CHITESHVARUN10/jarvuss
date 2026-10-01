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
pub mod automation;
pub mod intent_mapper;
pub mod intent_router;
pub mod ollama;
pub mod planner;
pub mod queue;
pub mod rl_log;
pub mod safety;
pub mod validator;
pub mod wake;

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

/// Safety verdict for a raw command (cut-over counterpart of
/// `SafetyGuard.validate(rawCommand:)`).
#[uniffi::export]
pub fn check_safety(raw: String) -> SafetyVerdict {
    safety::validate_raw(&raw)
}

/// Local hardware reads ("what is the current brightness level").
/// Runs BEFORE the learned intent model in the Swift pipeline.
#[uniffi::export]
pub fn resolve_local_state(cleaned: String) -> Option<Vec<PlannedAction>> {
    let lower = cleaned.to_lowercase();
    planner::answer_local_state_query(&cleaned, &lower)
}

/// Result of the post-model planning flow (Swift cut-over API).
#[derive(uniffi::Record)]
pub struct PlanResult {
    pub actions: Vec<PlannedAction>,
    /// Which branch decided this: "fastpath", "rule", "drop", "ai".
    pub branch: String,
    /// True when nothing local decided it and the caller must run the
    /// Ollama fallback (the query is returned in `actions` for now).
    pub needs_ollama: bool,
}

/// Fast-path + strict rules + guards — mirrors the Swift post-model flow
/// (`FastPathRouter.route` → `ruleBasedPlan` → misfire drop → short-AI).
/// The learned intent model runs in Swift BEFORE this call.
#[uniffi::export]
pub fn plan_after_model(cleaned: String) -> PlanResult {
    let lower = cleaned.to_lowercase();
    match planner::plan_after_safety(&cleaned, &lower) {
        planner::PlanStep::Actions(branch, actions) => PlanResult {
            actions,
            branch: branch.to_string(),
            needs_ollama: false,
        },
        planner::PlanStep::NeedsOllama(query) => PlanResult {
            actions: vec![PlannedAction::AiQuery { query }],
            branch: "ollama".to_string(),
            needs_ollama: true,
        },
    }
}

// ── Phase 2: queue priority, wake word, intent router, RL log, automations ──

/// Command queue priority classification (`CommandPriority.classify`).
#[uniffi::export]
pub fn classify_command_priority(text: String) -> queue::CommandPriority {
    queue::classify(&text)
}

/// Wake-word prefix detection (`WakeWordManager.isWakeWordDetected`).
#[uniffi::export]
pub fn is_wake_word_detected(text: String, wake_word: String) -> bool {
    wake::is_wake_word_detected(&text, &wake_word)
}

/// Wake-word stripping (`WakeWordManager.extractCommand`).
#[uniffi::export]
pub fn extract_wake_command(text: String, wake_word: String) -> String {
    wake::extract_command(&text, &wake_word)
}

/// Route an utterance through the learned intent model (HTTP + confidence
/// gate + strict mapping + hit/miss logging into the RL corpus).
#[uniffi::export]
pub fn route_intent(
    text: String,
    request_id: String,
    base_url: Option<String>,
) -> intent_router::IntentRouteOutcome {
    intent_router::route_intent(&text, &request_id, base_url)
}

/// Strict JSON intent → actions mapping (`IntentActionMapper.map`).
#[uniffi::export]
pub fn map_intents_json(json: String) -> Option<Vec<PlannedAction>> {
    intent_mapper::map_intents_json(&json)
}

/// Automation matching (`AppState.matchedAutomation`).
#[uniffi::export]
pub fn match_automation(
    text: String,
    keywords: Vec<automation::AutomationKeywords>,
) -> Option<automation::AutomationMatch> {
    automation::match_automation(&text, &keywords)
}

/// Read the automations JSON (AutomationStore.load).
#[uniffi::export]
pub fn read_automations_json() -> Option<String> {
    automation::read_json()
}

/// Atomically write the automations JSON (AutomationStore.save).
#[uniffi::export]
pub fn write_automations_json(
    json: String,
) -> Result<(), automation::AutomationStoreError> {
    automation::write_json(&json)
}

/// Append one event to the intent-router RL corpus (IntentRouterLog.append).
#[uniffi::export]
pub fn rl_append(event_json: String) -> bool {
    rl_log::append(&event_json)
}

// ── Phase 1.1: Ollama fallback (client + both response shapes) ──────

/// Raw `/api/generate` call (free-form answers, e.g. `aiQuery` responses).
#[uniffi::export]
pub fn ollama_generate(prompt: String) -> ollama::OllamaGenerateOutcome {
    ollama::generate(&prompt)
}

/// Planner fallback: tools prompt + "Shape A" → ordered actions
/// (falls back to a single `AiQuery(cleaned)` when the output is unparseable).
#[uniffi::export]
pub fn ollama_plan(cleaned: String) -> ollama::OllamaPlanResult {
    ollama::plan(&cleaned)
}

/// Normalizer fallback: tools prompt + "Shape B" → structured command.
#[uniffi::export]
pub fn ollama_normalize(cleaned: String) -> ollama::NormalizedCommand {
    ollama::normalize(&cleaned)
}
