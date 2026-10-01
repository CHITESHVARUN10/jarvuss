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

fn int_arg(args: &Value, key: &str) -> Option<i32> {
    let value = args.get(key)?;
    if let Some(n) = value.as_i64() {
        return Some(n as i32);
    }
    if let Some(n) = value.as_f64() {
        return Some(n as i32);
    }
    if let Some(s) = value.as_str() {
        return s.parse().ok();
    }
    None
}

fn map_single(name: &str, args: &Value) -> Option<PlannedAction> {
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
            level: int_arg(args, "level")?,
        }),
        "volume.up" => volume(VolumeAction::Increase {
            by: int_arg(args, "by")?,
        }),
        "volume.down" => volume(VolumeAction::Decrease {
            by: int_arg(args, "by")?,
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
    fn accepts_numeric_strings_and_floats_for_int_args() {
        let a = map_intents(&json!([{"name": "volume.up", "args": {"by": "10"}}])).unwrap();
        assert_eq!(
            a[0],
            PlannedAction::VolumeControl {
                action: VolumeAction::Increase { by: 10 }
            }
        );
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
