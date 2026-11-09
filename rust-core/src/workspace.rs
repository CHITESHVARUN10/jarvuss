//! Workspace interpretation only. Application IDs and OS execution stay in Swift.
use crate::text_policy::*;
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum WorkspaceApp {
    Brave,
    Chrome,
    Vscode,
    Finder,
    Terminal,
}
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Enum)]
pub enum WorkspaceOperation {
    NewWindow,
    NewTab,
    NewTerminalTab,
    OpenProject,
}
#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct WorkspaceRequest {
    pub operation: WorkspaceOperation,
    pub app: WorkspaceApp,
    pub project: String,
    pub root: String,
}
#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct WorkspacePart {
    pub text: String,
    pub request: Option<WorkspaceRequest>,
}
#[uniffi::export]
pub fn parse_workspace_app(text: String) -> Option<WorkspaceApp> {
    app(&text)
}
pub fn app(text: &str) -> Option<WorkspaceApp> {
    Some(match text.trim_matches(is_space).to_lowercase().as_str() {
        "brave" | "brave browser" => WorkspaceApp::Brave,
        "chrome" | "google chrome" => WorkspaceApp::Chrome,
        "code" | "vs code" | "vscode" | "visual studio code" => WorkspaceApp::Vscode,
        "finder" => WorkspaceApp::Finder,
        "terminal" => WorkspaceApp::Terminal,
        _ => return None,
    })
}
fn clean(raw: &str) -> String {
    let t = replace(
        r"(?i)^(?:hey\s+)?jarvis[,:]?\s+",
        raw.trim_matches(is_space),
        "",
    );
    let t = replace(r"(?i)^(?:(?:can|could) you\s+)?(?:please\s+)?", &t, "");
    replace(r"[.!?]+$", &t, "")
}
fn unquote(s: &str) -> String {
    s.trim_matches(|c| " \"'“”".contains(c)).to_string()
}
#[uniffi::export]
pub fn parse_workspace(raw: String) -> Option<WorkspaceRequest> {
    parse(&raw)
}
pub fn parse(raw: &str) -> Option<WorkspaceRequest> {
    let text = clean(raw);
    if let Some(g) = captures(
        r"^(?:open|create|make) (?:a |an |one )?new (window|tab|editor tab|terminal tab)(?: (?:in|on|for|of) (.+))?$",
        &text,
    ) {
        let kind = g[0].to_lowercase();
        let app = app(&g[1])?;
        return Some(WorkspaceRequest {
            operation: match kind.as_str() {
                "window" => WorkspaceOperation::NewWindow,
                "terminal tab" => WorkspaceOperation::NewTerminalTab,
                _ => WorkspaceOperation::NewTab,
            },
            app,
            project: String::new(),
            root: String::new(),
        });
    }
    if let Some(g) = captures(
        r"^(?:open|create|make) (?:a |an |one )?new (.+) (window|tab)$",
        &text,
    ) {
        if let Some(app) = app(&g[0]) {
            return Some(WorkspaceRequest {
                operation: if g[1].to_lowercase() == "window" {
                    WorkspaceOperation::NewWindow
                } else {
                    WorkspaceOperation::NewTab
                },
                app,
                project: String::new(),
                root: String::new(),
            });
        }
    }
    let mut body = captures(r"^open (.+)$", &text)?[0].clone();
    let mut target = WorkspaceApp::Finder;
    let mut explicit = false;
    if let Some(g) = captures(
        r"^(.+) (?:in|on|with) (?:a new window (?:in|of) )?(.+)$",
        &body,
    ) {
        if let Some(a) = app(&g[1]) {
            body = g[0].clone();
            target = a;
            explicit = true;
        }
    }
    let mut root = String::new();
    if let Some(g) = captures(r"^(.+) from (.+)$", &body) {
        body = g[0].clone();
        root = unquote(&g[1]);
    }
    let project = has(r"(?i)\bprojects?\b", &body);
    let followup =
        ["it", "that", "that project", "this project"].contains(&body.to_lowercase().as_str());
    if !project
        && !followup
        && !(explicit
            && matches!(
                target,
                WorkspaceApp::Finder | WorkspaceApp::Vscode | WorkspaceApp::Terminal
            ))
    {
        return None;
    }
    body = replace(r"(?i)^(?:my|the)\s+", &body, "");
    body = replace(r"(?i)\s+project$|^project\s+|^project$", &body, "");
    Some(WorkspaceRequest {
        operation: WorkspaceOperation::OpenProject,
        app: target,
        project: if followup {
            "@recent".to_string()
        } else {
            unquote(&body)
        },
        root,
    })
}
#[uniffi::export]
pub fn workspace_parts(raw: String) -> Vec<WorkspacePart> {
    let text = replace(
        r"(?i)(?:,\s*|\s+(?:and then|then|and)\s+)(?=(?:open|create|make)\b)",
        &clean(&raw),
        "\u{001f}",
    );
    text.split('\u{001f}')
        .map(|p| WorkspacePart {
            text: p.to_string(),
            request: parse(p),
        })
        .collect()
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_names_destinations_and_boundaries() {
        let r = parse("open \"Research and Design\" project from \"Drive A\" in VS Code").unwrap();
        assert_eq!(r.project, "Research and Design");
        assert_eq!(r.root, "Drive A");
        assert_eq!(r.app, WorkspaceApp::Vscode);
        assert_eq!(
            workspace_parts("open Chrome and open a new tab in Chrome".into()).len(),
            2
        );
        assert_eq!(parse("open it in Terminal").unwrap().project, "@recent");
        assert!(parse("play portfolio on Spotify").is_none());
        assert!(parse("open a new tab").is_none());
    }
}
