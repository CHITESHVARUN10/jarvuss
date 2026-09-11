//! Port of Swift `SafetyGuard` — pre-execution validation.
//! Same blocklists, same verdicts, no new behavior.

use regex::Regex;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SafetyVerdict {
    Allowed,
    Blocked { reason: String },
    InstallPreview { command: String, source: String },
}

fn destructive_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\b(delete|remove|rm|format|wipe|erase|overwrite|shred|truncate)\b")
            .expect("destructive regex")
    })
}

fn install_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(r"\b(install|brew install|npm install|pip install|gem install|yarn add|apt-get|yum|dnf)\b")
            .expect("install regex")
    })
}

fn sudo_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\bsudo\b").expect("sudo regex"))
}

pub const PROTECTED_PATHS: &[&str] = &[
    "/System",
    "/Library",
    "/private",
    "/usr",
    "/bin",
    "/sbin",
    "/etc",
    "/var",
    "/root",
    "/Applications/Utilities",
];

fn extract_package_name(lower: &str) -> Option<String> {
    for pattern in ["brew install ", "npm install ", "pip install ", "install "] {
        if let Some(idx) = lower.find(pattern) {
            let rest = lower[idx + pattern.len()..]
                .split_whitespace()
                .next()
                .unwrap_or("")
                .to_string();
            if !rest.is_empty() {
                return Some(rest);
            }
        }
    }
    None
}

fn run_checks(lower: &str, original: &str) -> SafetyVerdict {
    // 1. sudo — permanent block
    if sudo_re().is_match(lower) {
        return SafetyVerdict::Blocked {
            reason: "sudo commands are permanently disabled for safety.".to_string(),
        };
    }
    // 2. Destructive operations
    if destructive_re().is_match(lower) {
        return SafetyVerdict::Blocked {
            reason: "Destructive operations (delete/remove/format) are disabled.".to_string(),
        };
    }
    // 3. Install commands — preview only
    if install_re().is_match(lower) {
        let pkg = extract_package_name(lower).unwrap_or_else(|| original.to_string());
        return SafetyVerdict::InstallPreview {
            command: format!("install {pkg}"),
            source: "Requires face auth + confirmation (not yet active)".to_string(),
        };
    }
    // 4. Protected system paths
    for protected in PROTECTED_PATHS {
        if lower.contains(&protected.to_lowercase()) {
            return SafetyVerdict::Blocked {
                reason: format!("Access to '{protected}' is restricted."),
            };
        }
    }
    SafetyVerdict::Allowed
}

/// Validate a raw text command before it enters the pipeline.
pub fn validate_raw(command: &str) -> SafetyVerdict {
    run_checks(&command.to_lowercase(), command)
}

/// Validate a single planned action before it executes.
pub fn validate_action(action: &crate::PlannedAction) -> SafetyVerdict {
    use crate::PlannedAction as A;
    match action {
        A::OpenApp { name } | A::CloseApp { name } => run_checks(&name.to_lowercase(), name),
        A::SystemInfo { .. } | A::MediaControl { .. } | A::VolumeControl { .. } => {
            SafetyVerdict::Allowed
        }
        A::DisplayControl { .. } => SafetyVerdict::Allowed,
        A::OpenUrl { url } => {
            if url.to_lowercase().starts_with("file://") {
                let path = &url["file://".len()..];
                check_path(path)
            } else {
                SafetyVerdict::Allowed
            }
        }
        A::SearchWeb { query, .. } => run_checks(&query.to_lowercase(), query),
        A::OpenFolder { path } | A::OpenLatestFile { folder: path } => check_path(path),
        A::CreateFile { name } | A::CreateFolder { name } => check_path(name),
        A::AiQuery { query } => run_checks(&query.to_lowercase(), query),
        A::InstallPreview { package, source } => SafetyVerdict::InstallPreview {
            command: format!("install {package}"),
            source: source.clone(),
        },
    }
}

fn check_path(path: &str) -> SafetyVerdict {
    let lower = path.to_lowercase();
    for protected in PROTECTED_PATHS {
        if lower.starts_with(&protected.to_lowercase()) {
            return SafetyVerdict::Blocked {
                reason: format!("Access to '{protected}' is not allowed."),
            };
        }
    }
    run_checks(&lower, path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sudo_always_blocked() {
        assert!(matches!(
            validate_raw("sudo rm -rf /"),
            SafetyVerdict::Blocked { .. }
        ));
    }

    #[test]
    fn destructive_blocked() {
        assert!(matches!(
            validate_raw("delete my file"),
            SafetyVerdict::Blocked { .. }
        ));
        assert!(matches!(
            validate_raw("open Chrome"),
            SafetyVerdict::Allowed
        ));
    }

    #[test]
    fn install_is_preview() {
        match validate_raw("brew install wget") {
            SafetyVerdict::InstallPreview { command, .. } => {
                assert!(command.contains("wget"))
            }
            other => panic!("expected preview, got {other:?}"),
        }
    }

    #[test]
    fn protected_path_blocked() {
        assert!(matches!(
            validate_raw("open /System/Library/file"),
            SafetyVerdict::Blocked { .. }
        ));
    }

    #[test]
    fn media_and_volume_allowed() {
        use crate::{MediaAction, PlannedAction, VolumeAction};
        assert_eq!(
            validate_action(&PlannedAction::MediaControl {
                action: MediaAction::Pause
            }),
            SafetyVerdict::Allowed
        );
        assert_eq!(
            validate_action(&PlannedAction::VolumeControl {
                action: VolumeAction::Mute
            }),
            SafetyVerdict::Allowed
        );
    }
}
