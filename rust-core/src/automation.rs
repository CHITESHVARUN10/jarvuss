//! Port of Swift automation matching (`AppState.matchedAutomation`) and the
//! `AutomationStore` persistence shell (same file, same JSON contract).

use std::fs;
use std::path::PathBuf;

/// One automation's match keys, sent from Swift (order = display order).
#[derive(Debug, Clone, uniffi::Record)]
pub struct AutomationKeywords {
    pub keyword: String,
    pub off_keyword: Option<String>,
}

/// Which automation matched and whether it was the off variant.
#[derive(Debug, Clone, uniffi::Record)]
pub struct AutomationMatch {
    pub index: u32,
    pub is_off_variant: bool,
}

/// Match a command against the automation list, in order.
/// Port of `AppState.matchedAutomation`: trim + lowercase both sides; the
/// off-keyword defaults to "<keyword> off"; the off variant wins per entry.
pub fn match_automation(text: &str, keywords: &[AutomationKeywords]) -> Option<AutomationMatch> {
    let lower = text.trim().to_lowercase();
    if lower.is_empty() {
        return None;
    }

    for (index, entry) in keywords.iter().enumerate() {
        let keyword = entry.keyword.trim().to_lowercase();
        if keyword.is_empty() {
            continue;
        }

        let off_keyword = entry
            .off_keyword
            .as_ref()
            .map(|v| v.trim().to_lowercase())
            .unwrap_or_else(|| format!("{keyword} off"));

        if !off_keyword.is_empty() && lower.contains(&off_keyword) {
            return Some(AutomationMatch {
                index: index as u32,
                is_off_variant: true,
            });
        }
        if lower.contains(&keyword) {
            return Some(AutomationMatch {
                index: index as u32,
                is_off_variant: false,
            });
        }
    }

    None
}

// ── Persistence (AutomationStore) ───────────────────────────────────

pub fn automations_path() -> PathBuf {
    let home = dirs::home_dir().unwrap_or_default();
    home.join("Library/Application Support/Jarvis/automations.json")
}

/// Raw JSON text of the automations file (Swift decodes it — the Codable
/// contract stays the single source of truth for the shape).
pub fn read_json() -> Option<String> {
    fs::read_to_string(automations_path()).ok()
}

/// Persistence failures surfaced to Swift (`AutomationStore.save` throws).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AutomationStoreError {
    #[error("invalid JSON: {message}")]
    InvalidJson { message: String },
    #[error("io error: {message}")]
    Io { message: String },
}

/// Validate + atomically write the automations JSON.
pub fn write_json(json: &str) -> Result<(), AutomationStoreError> {
    let value: serde_json::Value = serde_json::from_str(json).map_err(|e| {
        AutomationStoreError::InvalidJson {
            message: e.to_string(),
        }
    })?;
    if !value.is_array() {
        return Err(AutomationStoreError::InvalidJson {
            message: "automations JSON must be an array".to_string(),
        });
    }
    let path = automations_path();
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| AutomationStoreError::Io {
            message: e.to_string(),
        })?;
    }
    let tmp = path.with_extension("json.tmp");
    fs::write(&tmp, json).map_err(|e| AutomationStoreError::Io {
        message: e.to_string(),
    })?;
    fs::rename(&tmp, &path).map_err(|e| AutomationStoreError::Io {
        message: e.to_string(),
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(keyword: &str, off: Option<&str>) -> AutomationKeywords {
        AutomationKeywords {
            keyword: keyword.to_string(),
            off_keyword: off.map(|s| s.to_string()),
        }
    }

    #[test]
    fn matches_keyword_and_default_off_variant() {
        let list = vec![entry("focus mode", None)];
        assert_eq!(
            match_automation("turn on focus mode", &list).map(|m| (m.index, m.is_off_variant)),
            Some((0, false))
        );
        assert_eq!(
            match_automation("focus mode off please", &list).map(|m| (m.index, m.is_off_variant)),
            Some((0, true))
        );
    }

    #[test]
    fn custom_off_keyword_wins() {
        let list = vec![entry("gym mode", Some("stop gym"))];
        let m = match_automation("stop gym now", &list).unwrap();
        assert!(m.is_off_variant);
        // Off variant is checked first per entry.
        let m2 = match_automation("gym mode stop gym", &list).unwrap();
        assert!(m2.is_off_variant);
    }

    #[test]
    fn first_match_wins_in_order() {
        let list = vec![entry("work", None), entry("workout", None)];
        assert_eq!(match_automation("start workout", &list).unwrap().index, 0);
    }

    #[test]
    fn empty_input_or_empty_keyword_matches_nothing() {
        assert!(match_automation("   ", &[entry("focus", None)]).is_none());
        assert!(match_automation("hello", &[entry("  ", None)]).is_none());
    }
}
