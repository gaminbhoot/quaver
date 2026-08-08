use base64::Engine;
use lofty::prelude::*;
use lofty::probe::Probe;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use tauri::Manager;
use walkdir::WalkDir;

#[cfg(target_os = "macos")]
pub mod macos;

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct TrackMetadata {
    pub path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration: f64,
    pub format: String,
    pub cover_data_url: Option<String>,
    pub lyric_path: Option<String>,
}

#[derive(Serialize, Deserialize)]
struct LibraryConfig {
    music_folder: String,
}

fn library_config_path(app: &tauri::AppHandle) -> Result<PathBuf, String> {
    let app_data_dir = app.path().app_data_dir().map_err(|error| error.to_string())?;
    fs::create_dir_all(&app_data_dir).map_err(|error| error.to_string())?;
    Ok(app_data_dir.join("library.json"))
}

fn save_music_folder(app: &tauri::AppHandle, folder: &Path) -> Result<(), String> {
    let config = LibraryConfig {
        music_folder: folder.to_string_lossy().to_string(),
    };
    let contents = serde_json::to_vec_pretty(&config).map_err(|error| error.to_string())?;
    fs::write(library_config_path(app)?, contents).map_err(|error| error.to_string())
}

#[tauri::command]
fn select_folder(app: tauri::AppHandle) -> Option<String> {
    rfd::FileDialog::new()
        .set_title("Select Music Folder (Local or External Drive)")
        .pick_folder()
        .map(|folder| {
            // This is intentionally best-effort: choosing a folder should still work
            // even if the local preference cannot be written for some reason.
            if let Err(error) = save_music_folder(&app, &folder) {
                eprintln!("Could not save music folder preference: {error}");
            }
            folder.to_string_lossy().to_string()
        })
}

#[tauri::command]
fn get_saved_music_folder(app: tauri::AppHandle) -> Option<String> {
    let contents = fs::read(library_config_path(&app).ok()?).ok()?;
    let config: LibraryConfig = serde_json::from_slice(&contents).ok()?;
    let folder = Path::new(&config.music_folder);
    folder.is_dir().then(|| config.music_folder)
}

#[tauri::command]
fn scan_directory(dir_path: String) -> Vec<TrackMetadata> {
    let mut tracks = Vec::new();
    let root = Path::new(&dir_path);

    if !root.exists() || !root.is_dir() {
        return tracks;
    }

    for entry in WalkDir::new(root).into_iter().filter_map(|e| e.ok()) {
        let path = entry.path();
        if path.is_file() {
            if let Some(ext) = path.extension().and_then(|e| e.to_str()) {
                let ext_lower = ext.to_lowercase();
                if matches!(
                    ext_lower.as_str(),
                    "flac" | "m4a" | "alac" | "mp3" | "aac" | "wav" | "aiff" | "aif" | "ogg" | "opus" | "wma" | "ape" | "ac3" | "mka"
                ) {
                    if let Ok(tagged_file) = Probe::open(path).and_then(|p| p.read()) {
                        let properties = tagged_file.properties();
                        let duration = properties.duration().as_secs_f64();

                        let mut title = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
                        let mut artist = "Unknown Artist".to_string();
                        let mut album = "Unknown Album".to_string();
                        let mut cover_data_url = None;

                        if let Some(tag) = tagged_file.primary_tag().or_else(|| tagged_file.first_tag()) {
                            if let Some(t) = tag.title() {
                                if !t.trim().is_empty() {
                                    title = t.to_string();
                                }
                            }
                            if let Some(a) = tag.artist() {
                                if !a.trim().is_empty() {
                                    artist = a.to_string();
                                }
                            }
                            if let Some(al) = tag.album() {
                                if !al.trim().is_empty() {
                                    album = al.to_string();
                                }
                            }

                            // Extract Picture
                            if let Some(pic) = tag.pictures().first() {
                                let mime = pic.mime_type().map(|m| m.as_str()).unwrap_or("image/jpeg");
                                let b64 = base64::engine::general_purpose::STANDARD.encode(pic.data());
                                cover_data_url = Some(format!("data:{};base64,{}", mime, b64));
                            }
                        }

                        // Check for matching .lrc file
                        let lyric_path = path.with_extension("lrc");
                        let lyric_str = if lyric_path.exists() {
                            Some(lyric_path.to_string_lossy().to_string())
                        } else {
                            None
                        };

                        tracks.push(TrackMetadata {
                            path: path.to_string_lossy().to_string(),
                            title,
                            artist,
                            album,
                            duration,
                            format: ext_lower.to_uppercase(),
                            cover_data_url,
                            lyric_path: lyric_str,
                        });
                    }
                }
            }
        }
    }

    tracks
}

#[tauri::command]
fn read_lyrics_file(file_path: String) -> Result<String, String> {
    fs::read_to_string(&file_path).map_err(|e| e.to_string())
}

#[tauri::command]
fn start_drag(window: tauri::Window) -> Result<(), String> {
    window.start_dragging().map_err(|e| e.to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .menu(|app| tauri::menu::Menu::default(app))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![
            select_folder,
            get_saved_music_folder,
            scan_directory,
            read_lyrics_file,
            start_drag
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
