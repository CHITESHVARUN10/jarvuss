//! Routine input validation. UI labels and macOS URL serialization remain native.
use crate::text_policy::is_space;
use crate::workspace;
#[derive(Clone, Debug, PartialEq, uniffi::Enum)]
pub enum RoutineIssue {
    MissingValue,
    InvalidWebsite,
    InvalidApp,
    InvalidWorkspace,
    InvalidFile,
    UnsupportedTimer,
    UnknownAction,
}
#[uniffi::export]
pub fn routine_requires_value(type_name: String) -> bool {
    requires_value(&type_name)
}
fn requires_value(t: &str) -> bool {
    !["play_liked", "pause", "next", "previous", "stopwatch"].contains(&t)
}
#[uniffi::export]
pub fn routine_website(value: String) -> Option<String> {
    let text = value.trim_matches(is_space);
    if text.chars().any(char::is_whitespace) {
        return None;
    }
    let normalized = if text.contains("://") {
        text.to_string()
    } else {
        format!("https://{text}")
    };
    let url = url::Url::parse(&normalized).ok()?;
    if !["http", "https"].contains(&url.scheme()) || url.host_str().is_none_or(str::is_empty) {
        return None;
    }
    Some(normalized)
}
#[uniffi::export]
pub fn validate_routine_action(type_name: String, value: String) -> Option<RoutineIssue> {
    let t = type_name.as_str();
    let text = value.trim_matches(is_space);
    if requires_value(t) && text.is_empty() {
        return Some(RoutineIssue::MissingValue);
    }
    match t {
        "open_website" | "open_website_brave" | "open_website_chrome" => {
            if routine_website(value).is_none() {
                return Some(RoutineIssue::InvalidWebsite);
            }
        }
        "new_tab" | "new_window" => {
            if workspace::app(text).is_none() {
                return Some(RoutineIssue::InvalidApp);
            }
        }
        "workspace_command" => {
            let p = workspace::workspace_parts(value);
            if p.len() != 1 || p[0].request.is_none() {
                return Some(RoutineIssue::InvalidWorkspace);
            }
        }
        "open_file" => {
            if !text.starts_with('/') && !text.starts_with("~/") {
                return Some(RoutineIssue::InvalidFile);
            }
        }
        "timer" | "stopwatch" => return Some(RoutineIssue::UnsupportedTimer),
        "command" | "open_app" | "close_app" | "play_song" | "play_playlist" | "play_liked"
        | "pause" | "next" | "previous" | "open_folder" => {}
        _ => return Some(RoutineIssue::UnknownAction),
    }
    None
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn values_are_validated_without_executing() {
        assert_eq!(
            routine_website("example.com".into()).as_deref(),
            Some("https://example.com")
        );
        assert_eq!(
            validate_routine_action("open_website".into(), "file:///tmp/a".into()),
            Some(RoutineIssue::InvalidWebsite)
        );
        assert_eq!(
            validate_routine_action("new_tab".into(), "Mail".into()),
            Some(RoutineIssue::InvalidApp)
        );
        assert_eq!(
            validate_routine_action("play_song".into(), " ".into()),
            Some(RoutineIssue::MissingValue)
        );
        assert!(validate_routine_action("open_file".into(), "~/a.txt".into()).is_none());
        assert!(validate_routine_action(
            "workspace_command".into(),
            "open a new tab in Chrome and open a new window in Brave".into()
        )
        .is_some());
    }
}
