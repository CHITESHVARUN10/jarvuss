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

/// Compile saved steps to the same action contract as spoken commands.
#[uniffi::export]
pub fn compile_routine_action(type_name: String, value: String) -> Option<crate::actions::PlannedAction> {
    if validate_routine_action(type_name.clone(), value.clone()).is_some() { return None; }
    use crate::actions::{MediaAction as M, PlannedAction as A};
    let text = value.trim();
    Some(match type_name.as_str() {
        "open_website" => A::OpenUrl { url: routine_website(value)? },
        "open_website_brave" | "open_website_chrome" => A::OpenUrlInBrowser { url: routine_website(value)?, browser: if type_name == "open_website_brave" { "Brave Browser" } else { "Google Chrome" }.into() },
        "new_tab" | "new_window" => A::Workspace { command: workspace::WorkspaceRequest { operation: if type_name == "new_tab" { workspace::WorkspaceOperation::NewTab } else { workspace::WorkspaceOperation::NewWindow }, app: workspace::app(text)?, project: String::new(), root: String::new() } },
        "workspace_command" => A::Workspace { command: workspace::parse(text)? },
        "open_app" => A::OpenApp { name: text.into() }, "close_app" => A::CloseApp { name: text.into() },
        "play_song" => A::MediaControl { action: M::PlaySong { name: text.into() } },
        "play_playlist" => A::MediaControl { action: M::PlayPlaylist { name: text.into() } },
        "play_liked" => A::MediaControl { action: M::PlayLikedSongs }, "pause" => A::MediaControl { action: M::Pause },
        "next" => A::MediaControl { action: M::NextTrack }, "previous" => A::MediaControl { action: M::PreviousTrack },
        "open_folder" => A::OpenFolder { path: text.into() },
        "open_file" => {
            let path = if let Some(tail) = text.strip_prefix("~/") { dirs::home_dir()?.join(tail) } else { std::path::PathBuf::from(text) };
            A::OpenUrl { url: url::Url::from_file_path(path).ok()?.to_string() }
        }
        _ => return None,
    })
}
