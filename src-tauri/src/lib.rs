use base64::Engine;
use lofty::prelude::*;
use lofty::probe::Probe;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use tauri::{Emitter, Manager};
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

fn find_folder_cover(track_path: &Path) -> Option<String> {
    let parent = track_path.parent()?;
    let cover_names = [
        "cover.jpg", "cover.jpeg", "cover.png", "cover.webp",
        "folder.jpg", "folder.jpeg", "folder.png", "folder.webp",
        "album.jpg", "album.jpeg", "album.png", "album.webp",
        "front.jpg", "front.jpeg", "front.png", "front.webp",
        "Cover.jpg", "Cover.jpeg", "Cover.png",
        "Folder.jpg", "Folder.jpeg", "Folder.png",
        "Album.jpg", "Front.jpg"
    ];
    for name in cover_names {
        let candidate = parent.join(name);
        if candidate.is_file() {
            if let Ok(bytes) = fs::read(&candidate) {
                let ext = candidate.extension().and_then(|e| e.to_str()).unwrap_or("jpeg");
                let mime = match ext.to_lowercase().as_str() {
                    "png" => "image/png",
                    "webp" => "image/webp",
                    _ => "image/jpeg",
                };
                let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                return Some(format!("data:{mime};base64,{b64}"));
            }
        }
    }
    None
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

                            // Extract Picture (Primary tag or any tag)
                            if let Some(pic) = tag.pictures().first().or_else(|| tagged_file.tags().iter().find_map(|t| t.pictures().first())) {
                                let mime = pic.mime_type().map(|m| m.as_str()).unwrap_or("image/jpeg");
                                let b64 = base64::engine::general_purpose::STANDARD.encode(pic.data());
                                cover_data_url = Some(format!("data:{};base64,{}", mime, b64));
                            }
                        }

                        // Folder artwork fallback if no embedded picture was found in tags
                        if cover_data_url.is_none() {
                            cover_data_url = find_folder_cover(path);
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

#[cfg(target_os = "macos")]
#[tauri::command]
fn sync_native_sidebar(window: tauri::WebviewWindow) {
    let _ = window.run_on_main_thread(|| macos::window::sync_native_sidebar());
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn update_native_player(state: macos::glass::NativePlayerState, window: tauri::WebviewWindow) {
    let _ = window.run_on_main_thread(move || macos::window::update_native_player(state));
}

#[cfg(target_os = "macos")]
#[tauri::command]
fn update_lyrics_mode(enabled: bool, window: tauri::WebviewWindow) {
    let _ = window.run_on_main_thread(move || macos::window::update_lyrics_mode(enabled));
}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn sync_native_sidebar() {}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn update_native_player(_state: serde_json::Value) {}

#[cfg(not(target_os = "macos"))]
#[tauri::command]
fn update_lyrics_mode(_enabled: bool) {}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .menu(build_menu)
        .on_menu_event(|app, event| {
            if event.id() == "add_folder" {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.emit("trigger-add-folder", ());
                }
            }
        })
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![
            select_folder,
            get_saved_music_folder,
            scan_directory,
            read_lyrics_file,
            start_drag,
            sync_native_sidebar,
            update_native_player,
            update_lyrics_mode
        ])
        .setup(|app| {
            // Initialize native AppKit sidebar on the main window.
            #[cfg(target_os = "macos")]
            {
                if let Some(window) = app.get_webview_window("main") {
                    macos::window::initialize_native_sidebar(&window, app.handle().clone());
                }
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

/// Build the native macOS application menu.
fn build_menu(app: &tauri::AppHandle) -> Result<tauri::menu::Menu<tauri::Wry>, tauri::Error> {
    use tauri::menu::*;

    let menu = Menu::new(app)?;

    // App menu
    let app_menu = Submenu::new(app, "Quaver", true)?;
    app_menu.append(&PredefinedMenuItem::about(app, Some("About Quaver"), None)?)?;
    app_menu.append(&PredefinedMenuItem::separator(app)?)?;
    app_menu.append(&PredefinedMenuItem::services(app, None)?)?;
    app_menu.append(&PredefinedMenuItem::separator(app)?)?;
    app_menu.append(&PredefinedMenuItem::hide(app, None)?)?;
    app_menu.append(&PredefinedMenuItem::hide_others(app, None)?)?;
    app_menu.append(&PredefinedMenuItem::show_all(app, None)?)?;
    app_menu.append(&PredefinedMenuItem::separator(app)?)?;
    app_menu.append(&PredefinedMenuItem::quit(app, None)?)?;
    menu.append(&app_menu)?;

    // File menu
    let file_menu = Submenu::new(app, "File", true)?;
    file_menu.append(&MenuItem::with_id(
        app,
        "add_folder",
        "Add Music Folder...",
        true,
        Some("CmdOrCtrl+O"),
    )?)?;
    menu.append(&file_menu)?;

    // Edit menu (standard macOS)
    let edit_menu = Submenu::new(app, "Edit", true)?;
    edit_menu.append(&PredefinedMenuItem::undo(app, None)?)?;
    edit_menu.append(&PredefinedMenuItem::redo(app, None)?)?;
    edit_menu.append(&PredefinedMenuItem::separator(app)?)?;
    edit_menu.append(&PredefinedMenuItem::cut(app, None)?)?;
    edit_menu.append(&PredefinedMenuItem::copy(app, None)?)?;
    edit_menu.append(&PredefinedMenuItem::paste(app, None)?)?;
    edit_menu.append(&PredefinedMenuItem::select_all(app, None)?)?;
    menu.append(&edit_menu)?;

    // View menu
    let view_menu = Submenu::new(app, "View", true)?;
    view_menu.append(&PredefinedMenuItem::fullscreen(app, None)?)?;
    menu.append(&view_menu)?;

    // Window menu
    let window_menu = Submenu::new(app, "Window", true)?;
    window_menu.append(&PredefinedMenuItem::minimize(app, None)?)?;
    window_menu.append(&PredefinedMenuItem::maximize(app, None)?)?;
    window_menu.append(&PredefinedMenuItem::separator(app)?)?;
    window_menu.append(&PredefinedMenuItem::close_window(app, None)?)?;
    menu.append(&window_menu)?;

    Ok(menu)
}
