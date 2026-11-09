//! Port of Swift `IntentActionMapper` — strict JSON intent → `PlannedAction`.
//!
//! Every mapping is strict: an unknown name or a wrong/missing arg returns
//! `None`, which makes the intent router treat the whole response as a miss
//! and fall back to the rule pipeline.

use crate::actions::{DisplayAction, MediaAction, PlannedAction, SystemInfoAction, VolumeAction};
use serde_json::Value;

/// Map a JSON array of `{"name": "...", "args": {...}}` intents.
/// Returns `None` for any unknown intent, bad arg, or empty list.
pub fn map_intents(intents: &Value) -> Option<Vec<PlannedAction>> {
    let list = intents.as_array()?;
    let mut actions = Vec::with_capacity(list.len());
    for intent in list {
        let name = intent.get("name")?.as_str()?;
        let empty = Value::Object(Default::default());
        let args = intent.get("args").unwrap_or(&empty);
        actions.push(map_single(name, args)?);
    }
    if actions.is_empty() {
        None
    } else {
        Some(actions)
    }
}

/// Convenience wrapper taking the raw JSON text.
pub fn map_intents_json(json: &str) -> Option<Vec<PlannedAction>> {
    let value: Value = serde_json::from_str(json).ok()?;
    map_intents(&value)
}

fn string_arg(args: &Value, key: &str) -> Option<String> {
    let value = args.get(key)?.as_str()?;
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn string_arg_allow_empty(args: &Value, key: &str) -> Option<String> { Some(args[key].as_str()?.to_owned()) }
fn volume_arg(args: &Value, key: &str) -> Option<i32> {
    let n = args[key].as_f64()?;
    (n.is_finite() && n.fract() == 0.0 && (0.0..=100.0).contains(&n)).then_some(n as i32)
}
fn int_arg(args: &Value, key: &str) -> Option<i32> {
    let value = args.get(key)?;
    if let Some(n) = value.as_i64() { return i32::try_from(n).ok(); }
    if let Some(n) = value.as_f64() {
        return (n.is_finite() && n.fract() == 0.0 && n >= i32::MIN as f64 && n <= i32::MAX as f64).then_some(n as i32);
    }
    if let Some(s) = value.as_str() {
        return s.parse().ok();
    }
    None
}

pub fn map_single(name: &str, args: &Value) -> Option<PlannedAction> {
    let display = |action| Some(PlannedAction::DisplayControl { action });
    let volume = |action| Some(PlannedAction::VolumeControl { action });
    let media = |action| Some(PlannedAction::MediaControl { action });
    let info = |info| Some(PlannedAction::SystemInfo { info });

    match name {
        "app.open" => Some(PlannedAction::OpenApp {
            name: string_arg(args, "name")?,
        }),
        "app.close" => Some(PlannedAction::CloseApp {
            name: string_arg(args, "name")?,
        }),
        "url.open" => Some(PlannedAction::OpenUrl {
            url: string_arg(args, "url")?,
        }),
        "url.open_in" => Some(PlannedAction::OpenUrlInBrowser { url: string_arg(args, "url")?, browser: string_arg(args, "browser")? }),
        "files.query" => {
            let op = string_arg(args, "op")?;
            if !["count","countFolders","list","listFolders","largest","oldest","newest","totalSize","openNewest","openOldest"].contains(&op.as_str()) { return None; }
            Some(PlannedAction::FileQuery { query: crate::command_policy::FileQuery { op, folder: string_arg(args, "folder").unwrap_or_else(|| "downloads".into()), ext: args["ext"].as_str().unwrap_or("").into() } })
        }
        "settings.open" => {
            let pane = string_arg(args, "pane")?;
            crate::command_policy::settings(&format!("open {} settings", pane.replace('_', " "))).filter(|v| v == &pane)?;
            Some(PlannedAction::OpenSettings { pane })
        }
        "files.result" => {
            let op = match args["action"].as_str()? { "open" => crate::local_search::SelectionOperation::Open, "preview" => crate::local_search::SelectionOperation::Preview, "reveal" => crate::local_search::SelectionOperation::Reveal, _ => return None };
            let n = args["index"].as_f64()?;
            if !n.is_finite() || n.fract() != 0.0 || !(0.0..=100.0).contains(&n) { return None; }
            Some(PlannedAction::FileResult { selection: crate::local_search::FileSelection { operation: op, index: n as u32 } })
        }
        "files.search" => {
            let query = string_arg_allow_empty(args, "query")?;
            let scopes = string_arg_allow_empty(args, "scope")?;
            let min = args["min_bytes"].as_f64()?; let max = args["max_bytes"].as_f64()?;
            if query.chars().count() > 512 || scopes.chars().count() > 2048 || !min.is_finite() || !max.is_finite() || min < 0.0 || max < 0.0 || min.fract() != 0.0 || max.fract() != 0.0 || min >= i64::MAX as f64 || max >= i64::MAX as f64 || (max > 0.0 && max < min) { return None; }
            let mode = match args["mode"].as_str()? { "name" => crate::local_search::SearchMode::Name, "content" => crate::local_search::SearchMode::Content, _ => return None };
            use crate::local_search::{SearchKind as K, SearchDate as D};
            let kind = match args["kind"].as_str()? { "any" => K::Any, "folder" => K::Folder, "pdf" => K::Pdf, "presentation" => K::Presentation, "document" => K::Document, "spreadsheet" => K::Spreadsheet, "image" => K::Image, "audio" => K::Audio, "video" => K::Video, "mail" => K::Mail, "note" => K::Note, _ => return None };
            let date = match args["date"].as_str()? { "any" => D::Any, "today" => D::Today, "yesterday" => D::Yesterday, "this_week" => D::ThisWeek, "last_week" => D::LastWeek, "this_month" => D::ThisMonth, "last_month" => D::LastMonth, "last_7_days" => D::Last7Days, "last_30_days" => D::Last30Days, _ => return None };
            Some(PlannedAction::SearchFiles { request: crate::local_search::SearchRequest { query, mode, kind, scopes: scopes.split('|').filter(|s| !s.is_empty()).map(str::to_owned).collect(), date, minimum_bytes: min as i64, maximum_bytes: max as i64 } })
        }
        "web.search" => Some(PlannedAction::SearchWeb {
            engine: string_arg(args, "engine")?,
            query: string_arg(args, "query")?,
        }),

        "display.brightness_set" => display(DisplayAction::SetBrightness {
            percent: int_arg(args, "level")?,
        }),
        "display.brightness_up" => display(DisplayAction::IncreaseBrightness {
            by: int_arg(args, "by")?,
        }),
        "display.brightness_down" => display(DisplayAction::DecreaseBrightness {
            by: int_arg(args, "by")?,
        }),
        "display.contrast_set" => display(DisplayAction::SetContrast {
            percent: int_arg(args, "level")?,
        }),
        "display.contrast_up" => display(DisplayAction::IncreaseContrast {
            by: int_arg(args, "by")?,
        }),
        "display.contrast_down" => display(DisplayAction::DecreaseContrast {
            by: int_arg(args, "by")?,
        }),

        "volume.set" => volume(VolumeAction::SetLevel {
            level: volume_arg(args, "level")?,
        }),
        "volume.up" => volume(VolumeAction::Increase {
            by: volume_arg(args, "by")?,
        }),
        "volume.down" => volume(VolumeAction::Decrease {
            by: volume_arg(args, "by")?,
        }),
        "volume.mute" => volume(VolumeAction::Mute),
        "volume.unmute" => volume(VolumeAction::Unmute),

        "media.play" => media(MediaAction::Play),
        "media.pause" => media(MediaAction::Pause),
        "media.next" => media(MediaAction::NextTrack),
        "media.previous" => media(MediaAction::PreviousTrack),
        "media.play_song" => media(MediaAction::PlaySong {
            name: string_arg(args, "title")?,
        }),
        "media.play_playlist" => media(MediaAction::PlayPlaylist {
            name: string_arg(args, "name")?,
        }),
        "media.play_liked" => media(MediaAction::PlayLikedSongs),

        "info.time" => info(SystemInfoAction::CurrentTime),
        "info.date" => info(SystemInfoAction::CurrentDate),
        "info.day" => info(SystemInfoAction::CurrentDay),
        "info.month" => info(SystemInfoAction::CurrentMonth),
        "info.year" => info(SystemInfoAction::CurrentYear),
        "info.brightness" => info(SystemInfoAction::DisplayBrightness),
        "info.contrast" => info(SystemInfoAction::DisplayContrast),
        "info.volume" => info(SystemInfoAction::SystemVolume),
        "info.battery" => info(SystemInfoAction::BatteryStatus),
        "info.wifi" => info(SystemInfoAction::WifiStatus),
        "info.bluetooth" => info(SystemInfoAction::BluetoothDevices),

        "file.create" => Some(PlannedAction::CreateFile {
            name: string_arg(args, "name")?,
        }),
        "folder.create" => Some(PlannedAction::CreateFolder {
            name: string_arg(args, "name")?,
        }),
        "folder.open" => Some(PlannedAction::OpenFolder {
            path: string_arg(args, "name")?,
        }),
        "file.open_latest" => Some(PlannedAction::OpenLatestFile {
            folder: string_arg(args, "folder")?,
        }),

        "install.preview" => Some(PlannedAction::InstallPreview {
            package: string_arg(args, "package")?,
            source: string_arg(args, "source").unwrap_or_else(|| "homebrew".to_string()),
        }),

        "ai.query" => Some(PlannedAction::AiQuery {
            query: string_arg(args, "text")?,
        }),

        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn maps_ordered_multi_step() {
        let intents = json!([
            {"name": "app.open", "args": {"name": "Google Chrome"}},
            {"name": "volume.up", "args": {"by": 10}}
        ]);
        let actions = map_intents(&intents).expect("mapped");
        assert_eq!(
            actions,
            vec![
                PlannedAction::OpenApp {
                    name: "Google Chrome".to_string()
                },
                PlannedAction::VolumeControl {
                    action: VolumeAction::Increase { by: 10 }
                }
            ]
        );
    }

    #[test]
    fn rejects_unknown_intent() {
        let intents = json!([{"name": "app.explode", "args": {}}]);
        assert!(map_intents(&intents).is_none());
    }

    #[test]
    fn rejects_missing_or_wrong_args() {
        assert!(map_intents(&json!([{"name": "app.open", "args": {}}])).is_none());
        assert!(map_intents(&json!([{"name": "app.open", "args": {"name": ""}}])).is_none());
        // Numbers where a string is required.
        assert!(map_intents(&json!([{"name": "app.open", "args": {"name": 42}}])).is_none());
    }

    #[test]
    fn rejects_string_volume_but_accepts_integral_display_values() {
        assert!(map_intents(&json!([{"name": "volume.up", "args": {"by": "10"}}])).is_none());
        let b = map_intents(&json!([{"name": "display.brightness_set", "args": {"level": 70.0}}]))
            .unwrap();
        assert_eq!(
            b[0],
            PlannedAction::DisplayControl {
                action: DisplayAction::SetBrightness { percent: 70 }
            }
        );
    }

    #[test]
    fn install_preview_defaults_source() {
        let a = map_intents(&json!([{"name": "install.preview", "args": {"package": "wget"}}]))
            .unwrap();
        assert_eq!(
            a[0],
            PlannedAction::InstallPreview {
                package: "wget".to_string(),
                source: "homebrew".to_string()
            }
        );
    }

    #[test]
    fn empty_list_is_a_miss() {
        assert!(map_intents(&json!([])).is_none());
    }
}

/// Serving mapping shares native fields and validates learned family selection.
#[uniffi::export]
pub fn map_intents_with_source(json: String, source: Option<String>) -> Option<Vec<PlannedAction>> {
    let value: Value = serde_json::from_str(&json).ok()?;
    let intents = value.as_array()?;
    if intents.is_empty() { return None; }
    if intents.iter().any(|i| ["app.new_window","app.new_tab","project.open"].contains(&i["name"].as_str().unwrap_or(""))) {
        let native = crate::command_policy::native_command(source.clone()?)?;
        if native.len() != intents.len() { return None; }
        for (i,a) in intents.iter().zip(&native) {
            if matches!(a, PlannedAction::Workspace { .. }) {
                if i["name"].as_str()? != crate::command_policy::intent_name(a) || !i["args"].as_object()?.is_empty() { return None; }
            } else if map_single(i["name"].as_str()?, &i["args"])? != *a { return None; }
        }
        return Some(native);
    }
    let clauses = source.as_deref().map(crate::planner::split_by_conjunction).unwrap_or_default();
    let aligned = intents.len() > 1 && clauses.len() == intents.len();
    let mut mapped = Vec::new();
    for (index, intent) in intents.iter().enumerate() {
        let name = intent["name"].as_str()?;
        let empty = serde_json::json!({});
        let args = intent.get("args").unwrap_or(&empty);
        if !args.is_object() { return None; }
        if let Some(source_raw) = source.as_deref() {
            let raw = if aligned { clauses[index].as_str() } else { source_raw };
            if crate::command_policy::negated_action(raw) && name != "ai.query" { return None; }
            if (intents.len() == 1 || aligned) && ["volume.set","volume.up","volume.down","volume.mute","volume.unmute"].contains(&name) {
                mapped.push(crate::system_volume::parse(raw)?); continue;
            }
            if ["files.search","files.result","settings.open","media.shuffle"].contains(&name) {
                if (intents.len() != 1 && !aligned) || !args.as_object()?.is_empty() { return None; }
                let native = crate::command_policy::native_single(raw)?;
                if crate::command_policy::intent_name(&native) != name { return None; }
                mapped.push(native); continue;
            }
            if intents.len() == 1 || aligned {
                let native = crate::command_policy::native_single(raw).or_else(|| {
                    let mut actions = crate::planner::fast_path_route(raw)?;
                    (actions.len() == 1).then(|| actions.remove(0))
                });
                if let Some(native) = native {
                    if crate::command_policy::intent_name(&native) == name { mapped.push(native); continue; }
                }
            }
        }
        let mut action = map_single(name, args)?;
        if let Some(raw) = source.as_deref() {
            let copy = |value: &mut String| -> Option<()> {
                let regex = regex::Regex::new(&format!("(?i){}", regex::escape(value))).ok()?;
                let found = regex.find(raw)?;
                *value = raw[found.range()].to_owned(); Some(())
            };
            match &mut action {
                PlannedAction::MediaControl { action: MediaAction::PlaySong { name } | MediaAction::PlayPlaylist { name } }
                | PlannedAction::CreateFile { name } | PlannedAction::CreateFolder { name } => copy(name)?,
                _ => {}
            }
        }
        mapped.push(action);
    }
    Some(mapped)
}
