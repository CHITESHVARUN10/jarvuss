//! Port of Swift `AppAliasResolver` — canonical app names + fuzzy match.

use regex::Regex;
use std::sync::OnceLock;

fn normalize_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"[^a-z0-9\s]").expect("normalize regex"))
}

fn squash_ws_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"\s+").expect("ws regex"))
}

fn normalize(value: &str) -> String {
    let lower = value.to_lowercase();
    let cleaned = normalize_re().replace_all(&lower, " ");
    squash_ws_re()
        .replace_all(&cleaned, " ")
        .trim()
        .to_string()
}

fn alias_map() -> Vec<(&'static str, Vec<&'static str>)> {
    vec![
        ("Google Chrome", vec!["chrome", "google chrome", "googlechrom"]),
        (
            "GitHub Desktop",
            vec![
                "github",
                "github desktop",
                "git hub",
                "git hub desktop",
                "githab desktop",
                "get her desktop",
                "getha desktop",
                "get desktop",
                "gate desktop",
                "get up desktop",
                "gita desktop",
            ],
        ),
        (
            "System Settings",
            vec!["system settings", "settings", "system setting"],
        ),
        (
            "Brave Browser",
            vec!["brave", "brave browser", "browser", "web browser"],
        ),
        (
            "Visual Studio Code",
            vec!["vscode", "vs code", "visual studio code", "visual code"],
        ),
        ("Finder", vec!["finder"]),
        ("Terminal", vec!["terminal"]),
        ("Spotify", vec!["spotify"]),
        ("WhatsApp", vec!["whatsapp"]),
    ]
}

pub fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut m = vec![vec![0usize; b.len() + 1]; a.len() + 1];
    for i in 0..=a.len() {
        m[i][0] = i;
    }
    for j in 0..=b.len() {
        m[0][j] = j;
    }
    for i in 1..=a.len() {
        for j in 1..=b.len() {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            m[i][j] = (m[i - 1][j] + 1).min((m[i][j - 1] + 1).min(m[i - 1][j - 1] + cost));
        }
    }
    m[a.len()][b.len()]
}

/// Resolve a spoken app name to its canonical macOS application name.
pub fn resolve(name: &str) -> String {
    let value = normalize(name);
    if value.is_empty() {
        return name.to_string();
    }
    for (canonical, aliases) in alias_map() {
        if aliases.iter().any(|a| *a == value) {
            return canonical.to_string();
        }
    }
    if let Some(fuzzy) = fuzzy_resolve(&value) {
        return fuzzy;
    }
    name.to_string()
}

fn fuzzy_resolve(value: &str) -> Option<String> {
    let mut best: Option<String> = None;
    let mut best_dist = usize::MAX;
    for (canonical, aliases) in alias_map() {
        for alias in aliases {
            let d = levenshtein(value, alias);
            if d < best_dist {
                best_dist = d;
                best = Some(canonical.to_string());
            }
        }
    }
    let best = best?;
    let max_allowed = (value.chars().count() / 4).max(1);
    if best_dist <= max_allowed {
        Some(best)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_aliases() {
        assert_eq!(resolve("chrome"), "Google Chrome");
        assert_eq!(resolve("VS Code"), "Visual Studio Code");
        assert_eq!(resolve("get her desktop"), "GitHub Desktop");
    }

    #[test]
    fn fuzzy_matches_typos() {
        assert_eq!(resolve("chrom"), "Google Chrome");
    }

    #[test]
    fn unknown_passthrough() {
        assert_eq!(resolve("SomeRandomApp"), "SomeRandomApp");
    }
}
