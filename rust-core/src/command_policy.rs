//! Shared native command contract. Names come from the original utterance,
//! never from generated model arguments. macOS effects remain in Swift.
use crate::{actions::{MediaAction, PlannedAction as A}, local_search, open_target, shuffle, workspace};
use crate::text_policy::{captures, has};

#[derive(Clone, Debug, PartialEq, serde::Serialize, serde::Deserialize, uniffi::Record)]
pub struct FileQuery { pub op: String, pub folder: String, pub ext: String }

pub fn settings(raw: &str) -> Option<String> {
    let clean = local_search::clean_search_text(raw.to_owned());
    let g = captures(r"(?i)^(?:open|show|go to|take me to) (?:me )?(?:the )?(.+?) (?:settings|preferences|pane)$", &clean)?;
    let name = g[0].to_lowercase().replace("wi-fi", "wifi");
    let name = match name.as_str() {
        "display" | "brightness" => "displays", "audio" | "volume" => "sound",
        "notification" => "notifications", "privacy and security" | "privacy & security" | "security" => "privacy",
        "software update" | "updates" => "software_update", _ => &name,
    };
    ["bluetooth","wifi","network","sound","displays","keyboard","mouse","trackpad","accessibility","privacy","microphone","battery","notifications","storage","software_update","spotlight","general"]
        .contains(&name).then(|| name.to_owned())
}

#[uniffi::export]
pub fn parse_settings(raw: String) -> Option<String> { settings(&raw) }

#[uniffi::export]
pub fn parse_file_query(raw: String) -> Option<A> { file_query(&raw) }

pub fn file_query(raw: &str) -> Option<A> {
    let text = raw.trim().to_lowercase();
    let folders = ["downloads","download","documents","docs","desktop","pictures","photos","images","movies","videos","music"];
    let has_folder = folders.iter().any(|f| text.contains(f)) || text.contains("home folder") || text.contains("home directory");
    if !(has_folder || ["file","folder","pdf","ppt","doc","spreadsheet","image","photo"].iter().any(|w| text.contains(w)))
        || text.starts_with("open app ") || text.contains("youtube") || text.contains("google search") { return None; }
    let mut ext = "";
    for extension in ["pdf","pptx","ppt","docx","doc","xlsx","xls","csv","txt","md","json","png","jpg","jpeg","gif","heic","mp4","mov","mp3","zip","swift","py"] {
        if has(&format!(r"\b{}\b", extension), &text) { ext = match extension { "ppt" => "pptx", "doc" => "docx", "xls" => "xlsx", "jpeg" => "jpg", _ => extension }; break; }
    }
    if ext.is_empty() {
        for (pattern, extension) in [(r"\b(image|images|photo|photos|picture|pictures)\b","png"),(r"\b(spreadsheet|spreadsheets)\b","xlsx"),(r"\b(presentation|presentations|deck|decks|slides)\b","pptx"),(r"\b(video|videos|movie|movies)\b","mp4")] {
            if has(pattern, &text) { ext = extension; break; }
        }
    }
    let folder = folders.iter().find(|f| text.contains(**f)).copied().unwrap_or(if text.contains("home folder") || text.contains("home directory") { "home" } else { "downloads" });
    let wants_folders = has(r"\b(folders|subfolder|subfolders|directories|directory)\b", &text) || text.contains("how many folder ") || text.contains("number of folder ");
    let open = text.starts_with("open ") || text.starts_with("show me ") || text.contains("open the ");
    let newest = has(r"\b(latest|newest|recent|recently|last)\b", &text);
    let oldest = has(r"\b(oldest|earliest|first)\b", &text);
    let op = if open && newest { "openNewest" }
    else if open && oldest { "openOldest" }
    else if text.contains("how many") || text.contains("number of") || text.starts_with("count ") || text.contains("count the") || text.contains("total number") { if wants_folders { "countFolders" } else { "count" } }
    else if has(r"\b(biggest|largest|heaviest)\b", &text) { "largest" }
    else if ["how much space","total size","size of all","take up","total space"].iter().any(|s| text.contains(s)) { "totalSize" }
    else if has(r"\b(oldest|earliest)\b", &text) { "oldest" }
    else if has(r"\b(latest|newest|recent|recently)\b", &text) { "newest" }
    else if ["list ","show ","tell me ","what ","which ","give me "].iter().any(|s| text.starts_with(s)) || text.contains("name of") { if wants_folders { "listFolders" } else { "list" } }
    else { return None; };
    Some(A::FileQuery { query: FileQuery { op: op.into(), folder: folder.into(), ext: ext.into() } })
}

pub fn shuffle_action(raw: &str) -> Option<A> {
    let s = shuffle::parse(raw)?;
    Some(A::MediaControl { action: match s.target {
        shuffle::ShuffleTarget::Current => MediaAction::SetShuffle { enabled: s.enabled },
        shuffle::ShuffleTarget::Liked => MediaAction::PlayLikedWithShuffle { enabled: s.enabled },
        shuffle::ShuffleTarget::Playlist => MediaAction::PlayPlaylistWithShuffle { name: s.name, enabled: s.enabled },
    } })
}

fn compound(raw: &str) -> bool {
    // Conjunctions in names remain literal; only a new action starts a clause.
    crate::text_policy::rx(r"(?i)\b(?:and|then|also)\s+(?:open|close|play|pause|set|search|find|launch|quit|create|increase|decrease|turn|mute|unmute)\b")
        .find_iter(raw).flatten().any(|m| crate::planner::outside_quotes(raw, m.start()))
}

pub fn negated_action(raw: &str) -> bool {
    has(&format!(r"(?i)^(?:please\s+)?(?:don't|don’t|do not|never|not to|without)\s+(?:{})\b", crate::planner::ACTION_VERBS.join("|")), raw.trim())
}

pub fn native_single(raw: &str) -> Option<A> {
    if negated_action(raw) { return None; }
    if let Some(pane) = settings(raw) { return Some(A::OpenSettings { pane }); }
    if let Some(selection) = local_search::selection(raw) { return Some(A::FileResult { selection }); }
    if let Some(request) = local_search::search(raw) { return Some(A::SearchFiles { request }); }
    if let Some(volume) = crate::system_volume::parse(raw) { return Some(volume); }
    if let Some(shuffle) = shuffle_action(raw) { return Some(shuffle); }
    if let Some(name) = shuffle::spotify_playlist_name(raw.to_owned()) { return Some(A::MediaControl { action: MediaAction::PlayPlaylist { name } }); }
    if compound(raw) { return None; }
    for (pattern, engine) in [
        (r"(?i)^search (?:on )?youtube for (.+)$", "YouTube"), (r"(?i)^youtube search for (.+)$", "YouTube"),
        (r"(?i)^search google for (.+)$", "Google"), (r"(?i)^google (.+)$", "Google"),
        (r"(?i)^search (?:on )?(?:the )?(?:web|internet) for (.+)$", "Google"),
        (r"(?i)^search for (.+)$", "Google"), (r"(?i)^search (.+?) (?:on|in) youtube[.!?]*$", "YouTube"),
        (r"(?i)^search (.+?) (?:on|in) (?:google|brave|the web|the internet)[.!?]*$", "Google")
    ] {
        if let Some(g) = captures(pattern, raw.trim()) {
            let query = g[0].trim().trim_end_matches(['.', '?', '!']).trim().to_owned();
            if !query.is_empty() { return Some(A::SearchWeb { engine: engine.into(), query }); }
        }
    }
    if let Some(q) = file_query(raw) { return Some(q); }
    if let Some(target) = open_target::parse_open_in_browser(raw.to_owned()).or_else(|| open_target::parse_local_dev(raw.to_lowercase())) {
        return Some(A::OpenUrlInBrowser { url: target.url, browser: target.browser });
    }
    // Explicit literals take precedence over normalization and model decoding.
    for (pattern, family) in [(r"(?i)^create (?:a |an )?file (?:named |called )?(.+)$", "file"), (r"(?i)^create (?:a |an )?folder (?:named |called )?(.+)$", "folder"), (r"(?i)^open folder (.+)$", "open_folder")] {
        if let Some(g) = captures(pattern, raw.trim()) {
            let name = g[0].trim().trim_matches('"').to_owned();
            if name.is_empty() { return None; }
            return Some(match family { "file" => A::CreateFile { name }, "folder" => A::CreateFolder { name }, _ => A::OpenFolder { path: name } });
        }
    }
    if let Some(g) = captures(r"(?i)^play\s+(?:the song\s+|song\s+)?(.+?)(?:\s+(?:on|in|from)\s+spotify)?[.!?]*$", raw.trim()) {
        let name = g[0].trim().trim_matches('"');
        if !name.is_empty() && (g[0].trim().starts_with('"') || !crate::planner::media_content_tokens(raw).is_empty()) && !has(r"(?i)\b(playlist|liked|shuffle)\b", name)
            && !["a song","the song","song","music","some music","something","a track","songs","some songs"].contains(&name.to_lowercase().as_str()) {
            return Some(A::MediaControl { action: MediaAction::PlaySong { name: name.to_owned() } });
        }
    }
    if let Some(g) = captures(r"(?i)^open\s+(https?://\S+)$", raw.trim()) { return Some(A::OpenUrl { url: g[0].clone() }); }
    None
}

#[uniffi::export]
pub fn native_command(raw: String) -> Option<Vec<A>> {
    if !matches!(crate::safety::validate_raw(&raw), crate::safety::SafetyVerdict::Allowed) { return None; }
    let parts = workspace::workspace_parts(raw.clone());
    if parts.iter().any(|p| p.request.is_some()) {
        return parts.into_iter().map(|p| {
            if let Some(command) = p.request { Some(vec![A::Workspace { command }]) }
            else { crate::planner::fast_path_route(&p.text).filter(|a| !a.is_empty() && !a.iter().any(|x| matches!(x, A::AiQuery { .. }))) }
        }).collect::<Option<Vec<_>>>().map(|a| a.into_iter().flatten().collect());
    }
    native_single(&raw).map(|a| vec![a])
}

#[uniffi::export]
pub fn fast_command(raw: String) -> Option<Vec<A>> { crate::planner::fast_path_route(&raw) }

pub fn intent_name(a: &A) -> &str {
    match a {
        A::Workspace { command } => match command.operation { workspace::WorkspaceOperation::OpenProject => "project.open", workspace::WorkspaceOperation::NewWindow => "app.new_window", _ => "app.new_tab" },
        A::OpenApp { .. } => "app.open", A::CloseApp { .. } => "app.close",
        A::SearchWeb { .. } => "web.search", A::FileQuery { .. } => "files.query",
        A::SearchFiles { .. } => "files.search", A::FileResult { .. } => "files.result", A::OpenSettings { .. } => "settings.open",
        A::MediaControl { action: MediaAction::PlaySong { .. } } => "media.play_song",
        A::MediaControl { action: MediaAction::PlayPlaylist { .. } } => "media.play_playlist",
        A::MediaControl { action: MediaAction::SetShuffle { .. } | MediaAction::PlayLikedWithShuffle { .. } | MediaAction::PlayPlaylistWithShuffle { .. } } => "media.shuffle",
        A::CreateFile { .. } => "file.create", A::CreateFolder { .. } => "folder.create", A::OpenFolder { .. } => "folder.open",
        A::OpenUrl { .. } => "url.open", A::OpenUrlInBrowser { .. } => "url.open_in",
        _ => "",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn preserves_unfamiliar_literals() {
        assert_eq!(native_single("play Zéphyr_42 by AB"), Some(A::MediaControl { action: MediaAction::PlaySong { name: "Zéphyr_42 by AB".into() } }));
        assert_eq!(native_single("create file Report_V2.JSON"), Some(A::CreateFile { name: "Report_V2.JSON".into() }));
        assert_eq!(native_single("open https://example.com/MyCase?q=AB"), Some(A::OpenUrl { url: "https://example.com/MyCase?q=AB".into() }));
    }
    #[test] fn preserves_compound_operations() {
        assert!(native_single("play Memories and open Chrome").is_none());
        assert_eq!(native_command("open a new tab in Chrome and open Spotify".into()).unwrap().len(), 2);
    }
}

#[uniffi::export]
pub fn command_parts(raw: String) -> Vec<String> { crate::planner::split_by_conjunction(&raw) }
#[uniffi::export]
pub fn command_verb_count(raw: String) -> u32 { crate::planner::action_verb_count(&raw) }
#[uniffi::export]
pub fn media_content_words(raw: String) -> Vec<String> { crate::planner::media_content_tokens(&raw) }
#[uniffi::export]
pub fn parse_media_command(raw: String) -> Option<A> {
    shuffle_action(&raw).or_else(|| crate::planner::parse_media_command(&raw.to_lowercase()))
}
#[uniffi::export]
pub fn rule_command(raw: String) -> Option<Vec<A>> { crate::planner::rule_based_plan(&raw, &raw.to_lowercase()) }
#[uniffi::export]
pub fn clean_command(raw: String) -> String { crate::planner::strip_wake_word(&crate::planner::strip_trailing_noise(&raw)) }
#[uniffi::export]
pub fn parse_tool_actions(raw: String) -> Option<Vec<A>> { crate::ollama::parse_tool_array(&raw) }

#[cfg(test)]
mod shared_policy_tests {
    use super::*;
    #[test]
    fn real_command_chain_and_quoted_names_survive() {
        let parts = command_parts("open spotify, open whatsapp and also open youtube and in spotify play a song".into());
        assert_eq!(parts, ["open spotify","open whatsapp","open youtube","play a song"]);
        let actions = rule_command("play \"Rock and Roll\" and open Chrome".into()).unwrap();
        assert_eq!(actions[0], A::MediaControl { action: MediaAction::PlaySong { name: "Rock and Roll".into() } });
        assert_eq!(actions.len(), 2);
    }
    #[test]
    fn cancelled_request_does_not_initialize_the_model() {
        let cancellation = crate::InferenceCancellation::new();
        cancellation.cancel();
        let missing = std::path::Path::new("/nonexistent-test-model");
        assert_eq!(crate::native_intent::parse_cancellable("pause", missing, missing, missing, Some(&cancellation)).unwrap_err(), "intent inference cancelled");
    }
}
