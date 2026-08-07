//! Quaver — native macOS music player backend.
//!
//! Exposes Tauri commands for directory selection, recursive audio scanning,
//! metadata extraction (via the `lofty` crate), and JSON config persistence.

mod commands;
mod metadata;
mod scanner;

/// Application entry point invoked from `main.rs`.
#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_fs::init())
        .invoke_handler(tauri::generate_handler![
            commands::select_music_directory,
            commands::scan_directory,
            commands::extract_metadata,
            commands::load_config,
            commands::save_config,
            commands::load_lyrics,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Quaver");
}

// Re-export commonly used types so the frontend can keep a single import surface.
pub use metadata::Track;
