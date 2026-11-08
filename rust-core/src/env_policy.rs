//! `.env` parsing and merge precedence. File discovery and Keychain access
//! remain native; this module owns only the text contract.

use std::collections::HashMap;

#[uniffi::export]
pub fn parse_dotenv(text: String) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in text.lines() {
        let mut trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix("export ") {
            trimmed = rest.trim();
        }
        let Some((key, value)) = trimmed.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let mut value = value.trim();
        if value.len() >= 2 {
            let first = value.chars().next().unwrap();
            if (first == '"' || first == '\'') && value.chars().last() == Some(first) {
                value = &value[1..value.len() - 1];
            }
        }
        if key.is_empty() {
            continue;
        }
        out.insert(key.to_string(), value.to_string());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_quotes_export_and_comments() {
        let text = "# comment\nA=1\nexport B = \"two\"\nC='three'\nEMPTY=\nBAD\n=DROPPED\n";
        let values = parse_dotenv(text.into());
        assert_eq!(values.get("A").map(String::as_str), Some("1"));
        assert_eq!(values.get("B").map(String::as_str), Some("two"));
        assert_eq!(values.get("C").map(String::as_str), Some("three"));
        assert_eq!(values.get("EMPTY").map(String::as_str), Some(""));
        assert!(!values.contains_key(""));
        assert!(!values.contains_key("BAD"));
    }

    #[test]
    fn last_value_wins_and_spaces_are_trimmed() {
        let values = parse_dotenv(" A = first \nA=second\n".into());
        assert_eq!(values.get("A").map(String::as_str), Some("second"));
    }
}
