//! Bounded project-root traversal and alias matching.
//!
//! Swift resolves security-scoped bookmarks and starts/stops access; this
//! module receives concrete paths and returns matches or a user-facing error.

use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

#[derive(Clone, Debug, uniffi::Record)]
pub struct ProjectLocationInput {
    pub name: String,
    pub path: String,
    pub is_root: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ProjectMatch {
    pub path: String,
    pub root_name: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct ProjectLookupResult {
    pub matches: Vec<ProjectMatch>,
    pub error: Option<String>,
}

fn error(message: impl Into<String>) -> ProjectLookupResult {
    ProjectLookupResult {
        matches: vec![],
        error: Some(message.into()),
    }
}

fn normalize(value: &str) -> String {
    value
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

fn within(url: &Path, root: &Path) -> bool {
    url == root || url.starts_with(root)
}

fn canonical(path: &str) -> Option<PathBuf> {
    fs::canonicalize(path).ok()
}

/// Foundation's `resolvingSymlinksInPath` presents the `/var`, `/tmp` and
/// `/etc` spellings, not the `/private/...` targets. Keep containment checks
/// on the real path while returning the Foundation-style display path.
fn display_path(path: &Path) -> PathBuf {
    let text = path.to_string_lossy();
    for (private, public) in [
        ("/private/var", "/var"),
        ("/private/tmp", "/tmp"),
        ("/private/etc", "/etc"),
    ] {
        if text == private {
            return PathBuf::from(public);
        }
        if let Some(rest) = text.strip_prefix(private) {
            if rest.starts_with('/') {
                return PathBuf::from(format!("{public}{rest}"));
            }
        }
    }
    path.to_path_buf()
}

fn is_directory(path: &Path) -> bool {
    fs::metadata(path).map(|value| value.is_dir()).unwrap_or(false)
}

fn unique(mut matches: Vec<ProjectMatch>) -> Vec<ProjectMatch> {
    let mut seen = HashSet::new();
    matches.retain(|item| seen.insert(item.path.clone()));
    matches
}

#[uniffi::export]
pub fn find_projects(
    query: String,
    root: String,
    locations: Vec<ProjectLocationInput>,
    max_entries: u32,
    max_depth: u32,
    prefer_direct: bool,
) -> ProjectLookupResult {
    if query.contains('/')
        || query.contains('\\')
        || query == "."
        || query == ".."
        || query.contains('\0')
    {
        return error("Use a project name or saved alias, rather than a path.");
    }
    if (!query.is_empty() && normalize(&query).is_empty())
        || (!root.is_empty() && normalize(&root).is_empty())
    {
        return error("Use a project or root name containing letters or numbers.");
    }
    let root_key = normalize(&root);
    let roots: Vec<&ProjectLocationInput> = locations
        .iter()
        .filter(|item| item.is_root && (root_key.is_empty() || normalize(&item.name) == root_key))
        .collect();
    if !root_key.is_empty() && roots.is_empty() {
        return error(format!(
            "No project root named ‘{root}’. Add it in System → Project locations."
        ));
    }
    let key = normalize(&query);
    let aliases: Vec<&ProjectLocationInput> = locations
        .iter()
        .filter(|item| !item.is_root && !key.is_empty() && normalize(&item.name) == key)
        .collect();

    let root_paths: Vec<PathBuf> = roots
        .iter()
        .filter_map(|item| canonical(&item.path))
        .collect();

    let mut alias_matches = Vec::new();
    for alias in aliases {
        let Some(url) = canonical(&alias.path) else {
            return error(format!(
                "The saved project ‘{}’ is unavailable. Connect its drive or choose the folder again.",
                alias.name
            ));
        };
        if !root_key.is_empty() && !root_paths.iter().any(|root| within(&url, root)) {
            continue;
        }
        if !is_directory(&url) {
            return error(format!(
                "The saved project ‘{}’ is unavailable. Connect its drive or choose the folder again.",
                alias.name
            ));
        }
        alias_matches.push(ProjectMatch {
            path: display_path(&url).to_string_lossy().to_string(),
            root_name: alias.name.clone(),
        });
    }
    if !alias_matches.is_empty() {
        return ProjectLookupResult {
            matches: unique(alias_matches),
            error: None,
        };
    }
    if roots.is_empty() {
        return error("Add a project root or project alias in System → Project locations first.");
    }
    if prefer_direct && max_depth > 1 {
        let direct = find_projects(
            query.clone(),
            root.clone(),
            locations.clone(),
            max_entries,
            1,
            false,
        );
        if direct.error.is_none() && !direct.matches.is_empty() {
            return direct;
        }
    }

    const EXCLUDED: &[&str] = &[
        "node_modules",
        "vendor",
        "build",
        "dist",
        "target",
        "pods",
        "__pycache__",
        "venv",
    ];
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut matches = Vec::new();
    let mut visited: HashSet<PathBuf> = HashSet::new();
    let mut entries: u64 = 0;
    let mut unavailable = Vec::new();

    for saved in &roots {
        let Some(root_url) = canonical(&saved.path) else {
            unavailable.push(saved.name.clone());
            continue;
        };
        if !is_directory(&root_url) {
            unavailable.push(saved.name.clone());
            continue;
        }
        let mut pending: Vec<(PathBuf, u32)> = vec![(root_url.clone(), 0)];
        let mut cursor = 0;
        while cursor < pending.len() {
            if Instant::now() > deadline {
                return error(
                    "Project lookup timed out. Choose a narrower root or add a project alias.",
                );
            }
            let (parent, depth) = pending[cursor].clone();
            cursor += 1;
            if !visited.insert(parent.clone()) {
                continue;
            }
            let children = match fs::read_dir(&parent) {
                Ok(value) => value,
                Err(_) => {
                    let name = parent
                        .file_name()
                        .map(|value| value.to_string_lossy().to_string())
                        .unwrap_or_default();
                    return error(format!(
                        "Cannot read ‘{name}’. Check folder access in System → Project locations."
                    ));
                }
            };
            for child in children.flatten() {
                entries += 1;
                if entries > max_entries as u64 {
                    return error(
                        "Project lookup reached its limit. Choose a narrower root or add a project alias.",
                    );
                }
                let name = child.file_name().to_string_lossy().to_string();
                if name.starts_with('.') {
                    continue;
                }
                let symlink = child
                    .file_type()
                    .map(|value| value.is_symlink())
                    .unwrap_or(true);
                if symlink {
                    continue;
                }
                let path = child.path();
                let Some(url) = fs::canonicalize(&path).ok() else {
                    continue;
                };
                if !is_directory(&url) || !within(&url, &root_url) {
                    continue;
                }
                if EXCLUDED.contains(&name.to_lowercase().as_str()) {
                    continue;
                }
                let matches_query = key.is_empty() || normalize(&name) == key;
                if matches_query {
                    matches.push(ProjectMatch {
                        path: display_path(&url).to_string_lossy().to_string(),
                        root_name: saved.name.clone(),
                    });
                }
                if depth + 1 < max_depth {
                    pending.push((url, depth + 1));
                }
            }
        }
    }
    if !unavailable.is_empty() {
        return error(format!(
            "Project roots unavailable: {}. Connect their drives or remove them in System → Project locations.",
            unavailable.join(", ")
        ));
    }
    ProjectLookupResult {
        matches: unique(matches),
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs as stdfs;

    fn temp_root() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let id = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "jarvis-project-test-{}-{id}",
            std::process::id()
        ));
        let _ = stdfs::remove_dir_all(&path);
        stdfs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn finds_and_filters_without_escaping_root() {
        let root = temp_root();
        stdfs::create_dir_all(root.join("work/Portfolio-Site")).unwrap();
        stdfs::create_dir_all(root.join("work/node_modules/hidden")).unwrap();
        stdfs::create_dir_all(root.join("work/one/two/three/too-deep")).unwrap();
        let locations = vec![ProjectLocationInput {
            name: "Work".into(),
            path: root.join("work").to_string_lossy().to_string(),
            is_root: true,
        }];
        let result = find_projects("portfolio site".into(), String::new(), locations.clone(), 10000, 3, true);
        assert!(result.error.is_none());
        assert_eq!(result.matches.len(), 1);
        for query in ["hidden", "too-deep"] {
            let result = find_projects(query.into(), String::new(), locations.clone(), 10000, 3, true);
            assert!(result.matches.is_empty());
        }
        let limited = find_projects("work".into(), String::new(), locations, 0, 3, true);
        assert!(limited.error.is_some());
        let _ = stdfs::remove_dir_all(root);
    }

    #[test]
    fn alias_and_invalid_paths() {
        let root = temp_root();
        stdfs::create_dir_all(root.join("portfolio")).unwrap();
        let locations = vec![
            ProjectLocationInput {
                name: "projects".into(),
                path: root.to_string_lossy().to_string(),
                is_root: true,
            },
            ProjectLocationInput {
                name: "website".into(),
                path: root.join("portfolio").to_string_lossy().to_string(),
                is_root: false,
            },
        ];
        let result = find_projects("website".into(), String::new(), locations.clone(), 10000, 3, true);
        assert_eq!(result.matches.len(), 1);
        let result = find_projects("missing".into(), "nope".into(), locations, 10000, 3, true);
        assert!(result.error.unwrap().contains("No project root named"));
        let _ = stdfs::remove_dir_all(root);
    }
}
