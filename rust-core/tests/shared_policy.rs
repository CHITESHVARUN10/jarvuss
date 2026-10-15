use jarvis_core::{planner, queue, safety};
use serde::Deserialize;

#[derive(Deserialize)]
struct Fixture {
    text: String,
    actions: Option<Vec<String>>,
    priority: String,
    safety: String,
}

#[test]
fn shared_swift_and_rust_policy_fixtures() {
    let fixtures: Vec<Fixture> = serde_json::from_str(include_str!(
        "../../Tests/JarvisMacOSTests/Fixtures/command_policy.json"
    ))
    .unwrap();
    for fixture in fixtures {
        let verdict = match safety::validate_raw(&fixture.text) {
            safety::SafetyVerdict::Allowed => "allowed",
            safety::SafetyVerdict::Blocked { .. } => "blocked",
            safety::SafetyVerdict::InstallPreview { .. } => "install",
        };
        assert_eq!(verdict, fixture.safety, "safety: {}", fixture.text);
        let priority = match queue::classify(&fixture.text) {
            queue::CommandPriority::High => "high",
            queue::CommandPriority::Normal => "normal",
        };
        assert_eq!(priority, fixture.priority, "priority: {}", fixture.text);
        if let Some(expected) = fixture.actions {
            let actions: Vec<_> = planner::plan(&fixture.text)
                .iter()
                .map(|a| a.description())
                .collect();
            assert_eq!(actions, expected, "plan: {}", fixture.text);
        }
    }
}
