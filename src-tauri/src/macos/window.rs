// src-tauri/src/macos/window.rs
// Native macOS window setup and glass initialization.
// Configures the NSWindow and initializes the NativeGlassManager.

use super::glass::NativeGlassManager;
use std::sync::Mutex;

/// Global glass manager state, protected by a Mutex.
/// This lives as long as the application.
static GLASS_MANAGER: Mutex<Option<NativeGlassManager>> = Mutex::new(None);

/// Initialize native macOS glass for the given Tauri webview window.
/// Must be called after the window is created, during app setup.
pub fn initialize_native_sidebar(window: &tauri::WebviewWindow, app: tauri::AppHandle) {
    let _ = window.with_webview(|platform_webview| {
        let ns_window_ptr = platform_webview.ns_window();
        let wk_webview_ptr = platform_webview.inner();

        eprintln!("[macos] initialize_native_sidebar — NSWindow={:?} WKWebView={:?}", ns_window_ptr, wk_webview_ptr);

        match NativeGlassManager::new(ns_window_ptr, wk_webview_ptr, app) {
            Ok(mut manager) => {
                if let Err(e) = manager.attach_to_window() {
                    eprintln!("[macos] Failed to attach glass to window: {}", e);
                } else {
                    eprintln!("[macos] NativeGlassManager attached");
                }
                if let Ok(mut guard) = GLASS_MANAGER.lock() {
                    *guard = Some(manager);
                    eprintln!("[macos] NativeGlassManager stored globally");
                }
            }
            Err(e) => {
                eprintln!("[macos] Failed to create NativeGlassManager: {}", e);
            }
        }
    });
}

/// Reapply native/sidebar frames after a WebView-visible resize or fullscreen change.
pub fn sync_native_sidebar() {
    if let Ok(guard) = GLASS_MANAGER.lock() {
        if let Some(ref manager) = *guard {
            manager.sync_layout();
        }
    }
}

pub fn update_native_player(state: super::glass::NativePlayerState) {
    if let Ok(guard) = GLASS_MANAGER.lock() {
        if let Some(ref manager) = *guard {
            manager.update_player_state(state);
        }
    }
}

pub fn update_lyrics_mode(enabled: bool) {
    if let Ok(guard) = GLASS_MANAGER.lock() {
        if let Some(ref manager) = *guard {
            manager.set_lyrics_mode(enabled);
        }
    }
}

pub fn toggle_volume_popover() {
    if let Ok(guard) = GLASS_MANAGER.lock() {
        if let Some(ref manager) = *guard {
            manager.toggle_volume_popover();
        }
    }
}
