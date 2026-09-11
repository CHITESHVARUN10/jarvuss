//! Action types mirrored 1:1 from Swift `ActionPlanner.swift`.
//! These are the UniFFI-exported records Swift will consume once the
//! Swift pipeline is cut over to `RustCore.plan()`.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum SystemInfoAction {
    CurrentTime,
    CurrentDate,
    WifiStatus,
    BluetoothDevices,
    BatteryStatus,
    SystemVolume,
}

impl SystemInfoAction {
    pub fn description(&self) -> &'static str {
        match self {
            Self::CurrentTime => "current time",
            Self::CurrentDate => "current date",
            Self::WifiStatus => "wifi status",
            Self::BluetoothDevices => "bluetooth devices",
            Self::BatteryStatus => "battery status",
            Self::SystemVolume => "system volume",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum MediaAction {
    Play,
    PlaySong { name: String },
    Pause,
    NextTrack,
    PreviousTrack,
    PlayLikedSongs,
    PlayPlaylist { name: String },
}

impl MediaAction {
    pub fn description(&self) -> String {
        match self {
            Self::Play => "play".to_string(),
            Self::PlaySong { name } => format!("play song '{name}'"),
            Self::Pause => "pause".to_string(),
            Self::NextTrack => "next track".to_string(),
            Self::PreviousTrack => "previous track".to_string(),
            Self::PlayLikedSongs => "play liked songs".to_string(),
            Self::PlayPlaylist { name } => format!("play playlist '{name}'"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, uniffi::Enum)]
pub enum VolumeAction {
    Increase { by: i32 },
    Decrease { by: i32 },
    Mute,
    Unmute,
    SetLevel { level: i32 },
}

impl VolumeAction {
    pub fn description(&self) -> String {
        match self {
            Self::Increase { by } => format!("increase by {by}%"),
            Self::Decrease { by } => format!("decrease by {by}%"),
            Self::Mute => "mute".to_string(),
            Self::Unmute => "unmute".to_string(),
            Self::SetLevel { level } => format!("set to {level}%"),
        }
    }

    pub fn response_text(&self) -> String {
        match self {
            Self::Increase { by } => format!("Volume increased by {by} percent"),
            Self::Decrease { by } => format!("Volume decreased by {by} percent"),
            Self::Mute => "Sound muted".to_string(),
            Self::Unmute => "Sound unmuted".to_string(),
            Self::SetLevel { level } => format!("Volume set to {level} percent"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Enum)]
pub enum DisplayAction {
    SetBrightness { percent: i32 },
    IncreaseBrightness { by: i32 },
    DecreaseBrightness { by: i32 },
    SetContrast { percent: i32 },
    IncreaseContrast { by: i32 },
    DecreaseContrast { by: i32 },
    SetResolution {
        width: i32,
        height: i32,
        refresh_rate: Option<f64>,
    },
    ListResolutions,
}

impl DisplayAction {
    pub fn description(&self) -> String {
        match self {
            Self::SetBrightness { percent } => format!("Set brightness to {percent}%"),
            Self::IncreaseBrightness { by } => format!("Increase brightness by {by}%"),
            Self::DecreaseBrightness { by } => format!("Decrease brightness by {by}%"),
            Self::SetContrast { percent } => format!("Set contrast to {percent}%"),
            Self::IncreaseContrast { by } => format!("Increase contrast by {by}%"),
            Self::DecreaseContrast { by } => format!("Decrease contrast by {by}%"),
            Self::SetResolution { width, height, .. } => {
                format!("Set resolution to {width}×{height}")
            }
            Self::ListResolutions => "List available resolutions".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, uniffi::Enum)]
pub enum PlannedAction {
    OpenApp { name: String },
    CloseApp { name: String },
    SystemInfo { info: SystemInfoAction },
    OpenUrl { url: String },
    SearchWeb { engine: String, query: String },
    OpenFolder { path: String },
    OpenLatestFile { folder: String },
    MediaControl { action: MediaAction },
    VolumeControl { action: VolumeAction },
    CreateFile { name: String },
    CreateFolder { name: String },
    AiQuery { query: String },
    InstallPreview { package: String, source: String },
    DisplayControl { action: DisplayAction },
}

impl PlannedAction {
    pub fn description(&self) -> String {
        match self {
            Self::OpenApp { name } => format!("Open '{name}'"),
            Self::CloseApp { name } => format!("Close '{name}'"),
            Self::SystemInfo { info } => format!("Info: {}", info.description()),
            Self::OpenUrl { url } => format!("Open URL: {url}"),
            Self::SearchWeb { engine, query } => format!("Search {engine} for '{query}'"),
            Self::OpenFolder { path } => format!("Open folder '{path}'"),
            Self::OpenLatestFile { folder } => format!("Open latest file in '{folder}'"),
            Self::MediaControl { action } => format!("Media: {}", action.description()),
            Self::VolumeControl { action } => format!("Volume: {}", action.description()),
            Self::CreateFile { name } => format!("Create file '{name}'"),
            Self::CreateFolder { name } => format!("Create folder '{name}'"),
            Self::AiQuery { query } => format!("AI query: '{query}'"),
            Self::InstallPreview { package, .. } => format!("Install preview: '{package}'"),
            Self::DisplayControl { action } => format!("Display: {}", action.description()),
        }
    }

    /// True for actions the legacy single-command Swift pipeline owns
    /// (app open/close/create/AI). Mirrors `AppState.planIsSingleLegacyAction`.
    pub fn is_single_legacy(&self) -> bool {
        matches!(
            self,
            Self::OpenApp { .. }
                | Self::CloseApp { .. }
                | Self::CreateFile { .. }
                | Self::CreateFolder { .. }
                | Self::AiQuery { .. }
        )
    }
}
