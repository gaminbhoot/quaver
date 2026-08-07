//! Tauri command handlers exposed to the JavaScript frontend.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tauri::AppHandle;
use tauri_plugin_dialog::DialogExt;

use crate::metadata::{extract_metadata_for_files, Metadata, Track};
use crate::scanner::scan_directory_recursive;

/// Application-level config persisted to disk between launches.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AppConfig {
    /// Last directory the user pointed Quaver at.
    #[serde(default)]
    pub last_directory: Option<String>,
    /// Any additional directories the user added.
    #[serde(default)]
    pub directories: Vec<String>,
    /// Last playing track path (so we can resume on relaunch).
    #[serde(default)]
    pub last_track: Option<String>,
    /// Last playback position in seconds.
    #[serde(default)]
    pub last_position_secs: Option<f64>,
}

/// Optional args for `scan_directory` — currently empty but reserved for
/// future filters (e.g. recursive depth, file extensions to include).
#[derive(Debug, Default, Deserialize)]
pub struct ScanArgs {
    #[serde(default)]
    pub extensions: Option<Vec<String>>,
}

/// Open the native macOS folder picker and return the selected path.
#[tauri::command]
pub async fn select_music_directory(app: AppHandle) -> Result<Option<String>, String> {
    let (tx, rx) = std::sync::mpsc::channel();
    app.dialog()
        .file()
        .set_title("Select a music folder")
        .pick_folder(move |folder| {
            let _ = tx.send(folder);
        });
    let folder = rx
        .recv()
        .map_err(|e| format!("dialog channel error: {e}"))?;
    Ok(folder.map(|p| p.to_string()))
}

/// Recursively scan a directory for audio + lyric files.
#[tauri::command]
pub async fn scan_directory(path: String, args: Option<ScanArgs>) -> Result<Vec<Track>, String> {
    let extensions = args
        .and_then(|a| a.extensions)
        .unwrap_or_else(|| {
            vec![
                "flac".into(),
                "m4a".into(),
                "mp3".into(),
                "alac".into(),
                "ogg".into(),
                "opus".into(),
            ]
        });
    scan_directory_recursive(Path::new(&path), &extensions).map_err(|e| e.to_string())
}

/// Extract metadata for a list of file paths in a single Rust call.
#[tauri::command]
pub async fn extract_metadata(file_paths: Vec<String>) -> Result<Vec<Metadata>, String> {
    let paths: Vec<PathBuf> = file_paths.into_iter().map(PathBuf::from).collect();
    extract_metadata_for_files(&paths).map_err(|e| e.to_string())
}

/// Load the persisted app config (or return defaults if none exists).
#[tauri::command]
pub async fn load_config() -> Result<AppConfig, String> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(AppConfig::default());
    }
    let raw = fs::read_to_string(&path).map_err(|e| e.to_string())?;
    serde_json::from_str(&raw).map_err(|e| e.to_string())
}

/// Persist the supplied app config to disk.
#[tauri::command]
pub async fn save_config(config: AppConfig) -> Result<(), String> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let raw = serde_json::to_string_pretty(&config).map_err(|e| e.to_string())?;
    fs::write(&path, raw).map_err(|e| e.to_string())
}

/// Read a `.lrc` file from disk and return its raw text.
#[tauri::command]
pub async fn load_lyrics(path: String) -> Result<String, String> {
    fs::read_to_string(&path).map_err(|e| e.to_string())
}

fn config_path() -> Result<PathBuf, String> {
    let mut dir = dirs::config_dir()
        .ok_or_else(|| "could not resolve user config directory".to_string())?;
    dir.push("Quaver");
    dir.push("config.json");
    Ok(dir)
}
