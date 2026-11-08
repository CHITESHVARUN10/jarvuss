//! Browser-target and local-development URL resolution shared by routing.
//!
//! Mirrors Swift `OpenTargetResolver`. Native URL/application opening stays in
//! Swift; this module decides the canonical URL and browser name.

use crate::text_policy::{captures, replace, rx};

#[derive(Clone, Debug, uniffi::Record)]
pub struct OpenTarget {
    pub url: String,
    pub browser: String,
}

const SITE_TARGETS: &[(&str, &str)] = &[
    ("chatgpt", "https://chatgpt.com"),
    ("chat gpt", "https://chatgpt.com"),
    ("chatgpt.com", "https://chatgpt.com"),
    ("chat gpt.com", "https://chatgpt.com"),
    ("chat gpt ai", "https://chatgpt.com"),
    ("chatgpt.ai", "https://chatgpt.com"),
    ("vercel", "https://vercel.com"),
    ("versel", "https://vercel.com"),
    ("varcel", "https://vercel.com"),
    ("vercel.com", "https://vercel.com"),
    ("versel.com", "https://vercel.com"),
    ("claude", "https://claude.com"),
    ("claude ai", "https://claude.com"),
    ("claude.ai", "https://claude.com"),
    ("claude.com", "https://claude.com"),
    ("claude code", "https://code.claude.com"),
    ("cloud code", "https://code.claude.com"),
    ("clawed code", "https://code.claude.com"),
    ("claude code.com", "https://code.claude.com"),
    ("cloud code.com", "https://code.claude.com"),
    ("code.claude.com", "https://code.claude.com"),
    ("command code", "https://commandcode.ai"),
    ("commandcode", "https://commandcode.ai"),
    ("commend code", "https://commandcode.ai"),
    ("command code.com", "https://commandcode.ai"),
    ("commandcode.ai", "https://commandcode.ai"),
    ("command code.ai", "https://commandcode.ai"),
    ("github", "https://github.com"),
    ("git hub", "https://github.com"),
    ("github.com", "https://github.com"),
    ("youtube", "https://www.youtube.com"),
    ("you tube", "https://www.youtube.com"),
    ("youtube.com", "https://www.youtube.com"),
    ("google", "https://www.google.com"),
    ("netflix", "https://www.netflix.com"),
    ("twitter", "https://twitter.com"),
    ("x", "https://twitter.com"),
    ("twitter x", "https://twitter.com"),
    ("reddit", "https://www.reddit.com"),
    ("instagram", "https://www.instagram.com"),
    ("linkedin", "https://www.linkedin.com"),
    ("gmail", "https://mail.google.com"),
    ("maps", "https://maps.google.com"),
    ("google maps", "https://maps.google.com"),
];

const BROWSERS: &[(&str, &str)] = &[
    ("brave browser", "Brave Browser"),
    ("brave", "Brave Browser"),
    ("google chrome", "Google Chrome"),
    ("chrome", "Google Chrome"),
    ("safari", "Safari"),
    ("firefox", "Firefox"),
    ("microsoft edge", "Microsoft Edge"),
    ("edge", "Microsoft Edge"),
    ("arc browser", "Arc"),
    ("arc", "Arc"),
];

fn normalized(value: &str) -> String {
    let lower = value
        .trim()
        .to_lowercase()
        .trim_matches(|c: char| !c.is_alphanumeric() && !c.is_whitespace())
        .to_string();
    replace(r"\s+", &lower, " ")
        .trim_matches(|c: char| !c.is_alphanumeric() && !c.is_whitespace())
        .to_string()
}

#[uniffi::export]
pub fn canonical_browser(raw: String) -> Option<String> {
    let value = normalized(&raw);
    BROWSERS
        .iter()
        .find(|(alias, _)| value == *alias)
        .map(|(_, canonical)| canonical.to_string())
}

#[uniffi::export]
pub fn site_url(raw: String) -> Option<String> {
    let mut target = normalized(&raw);
    if target.is_empty() {
        return None;
    }
    if target.starts_with("http://") || target.starts_with("https://") {
        return Some(target);
    }
    target = target.replace(" dot com", ".com");
    target = target.replace(" dot ai", ".ai");
    if let Some((_, canonical)) = SITE_TARGETS.iter().find(|(alias, _)| target == *alias) {
        return Some(canonical.to_string());
    }
    if target.contains('.') && !target.contains(' ') {
        return Some(format!("https://{target}"));
    }
    None
}

#[uniffi::export]
pub fn parse_open_in_browser(lower: String) -> Option<OpenTarget> {
    let pattern = r"(?i)^open\s+(.+?)\s+(?:in|on|using|with)\s+(?:the\s+|my\s+)?(brave browser|google chrome|chrome|brave|safari|firefox|microsoft edge|edge|arc browser|arc)(?:\s+browser)?[.!?]*$";
    let caps = rx(pattern).captures(&lower).ok()??;
    let site = caps.get(1)?.as_str();
    let browser = caps.get(2)?.as_str();
    Some(OpenTarget {
        url: site_url(site.to_string())?,
        browser: canonical_browser(browser.to_string())?,
    })
}

fn is_react(lower: &str) -> bool {
    lower.contains("react") || lower.contains("vite")
}

fn extract_port(lower: &str) -> Option<i32> {
    let patterns = [
        r"localhost[:\s]+(\d{2,5})",
        r"\bport\s+(\d{2,5})",
        r"\b(?:on|at|in)\s+(\d{2,5})\b",
        r":(\d{2,5})\b",
        r"\b(\d{2,5})\b",
    ];
    for pattern in patterns {
        if let Some(groups) = captures(pattern, lower) {
            if let Some(value) = groups.first().and_then(|value| value.parse::<i32>().ok()) {
                return Some(value);
            }
        }
    }
    None
}

fn extract_browser(lower: &str) -> Option<String> {
    let pattern = r"(?:in|on|using|with)\s+(?:the\s+|my\s+)?(brave browser|google chrome|chrome|brave|safari|firefox|microsoft edge|edge|arc browser|arc)(?:\s+browser)?";
    let groups = captures(pattern, lower)?;
    canonical_browser(groups.first()?.to_string())
}

#[uniffi::export]
pub fn parse_local_dev(lower: String) -> Option<OpenTarget> {
    if !lower.starts_with("open ") {
        return None;
    }
    let has_cue = lower.contains("localhost")
        || lower.contains("local host")
        || lower.contains("react app")
        || lower.contains("react application")
        || lower.contains("vite")
        || regex_has_port(&lower);
    if !has_cue {
        return None;
    }
    let port = extract_port(&lower).unwrap_or(if is_react(&lower) { 5173 } else { 3000 });
    if !(1..=65535).contains(&port) {
        return None;
    }
    Some(OpenTarget {
        url: format!("http://localhost:{port}"),
        browser: extract_browser(&lower).unwrap_or_else(|| "Brave Browser".to_string()),
    })
}

fn regex_has_port(lower: &str) -> bool {
    rx(r"\bport\s+\d{2,5}\b").is_match(lower).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_sites_and_browsers() {
        assert_eq!(site_url("chat gpt".into()).as_deref(), Some("https://chatgpt.com"));
        assert_eq!(site_url("chatgpt dot com".into()).as_deref(), Some("https://chatgpt.com"));
        assert_eq!(site_url("example.com".into()).as_deref(), Some("https://example.com"));
        assert_eq!(site_url("not a website".into()), None);
        assert_eq!(canonical_browser("chrome".into()).as_deref(), Some("Google Chrome"));
        assert_eq!(canonical_browser("arc browser".into()).as_deref(), Some("Arc"));
    }

    #[test]
    fn open_in_browser_and_local_dev() {
        let target = parse_open_in_browser("open chatgpt in brave".into()).unwrap();
        assert_eq!(target.url, "https://chatgpt.com");
        assert_eq!(target.browser, "Brave Browser");
        let target = parse_open_in_browser("open vercel on google chrome".into()).unwrap();
        assert_eq!(target.url, "https://vercel.com");
        assert_eq!(target.browser, "Google Chrome");
        let target = parse_local_dev("open my react app on port 4500 in chrome".into()).unwrap();
        assert_eq!(target.url, "http://localhost:4500");
        assert_eq!(target.browser, "Google Chrome");
        assert_eq!(
            parse_local_dev("open localhost".into()).unwrap().url,
            "http://localhost:3000"
        );
        assert!(parse_local_dev("open youtube".into()).is_none());
    }
}
