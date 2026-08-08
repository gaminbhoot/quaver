// src-tauri/src/macos/window.rs
// Native macOS window setup and glass initialization.
// Configures the NSWindow and initializes the NativeGlassManager.

use super::glass::NativeGlassManager;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::Mutex;

/// Global glass manager state, protected by a Mutex.
/// This lives as long as the application.
static GLASS_MANAGER: Mutex<Option<NativeGlassManager>> = Mutex::new(None);

/// Initialize native macOS glass for the given Tauri webview window.
/// Must be called after the window is created, during app setup.
pub fn initialize_native_sidebar(window: &tauri::WebviewWindow, app: tauri::AppHandle) {
    let _ = window.with_webview(|platform_webview| {
        let _ = catch_unwind(AssertUnwindSafe(|| {
            let ns_window_ptr = platform_webview.ns_window();
            let wk_webview_ptr = platform_webview.inner();

            log::info!("[macos] NSWindow acquired: {:?}", ns_window_ptr);
            log::info!("[macos] WKWebView acquired: {:?}", wk_webview_ptr);

            // Keep WKWebView opaque and move it beside the native sidebar.
            match NativeGlassManager::new(ns_window_ptr, wk_webview_ptr, app) {
                Ok(mut manager) => {
                    // Attach the native Liquid Glass sidebar and resize WKWebView.
                    if let Err(e) = manager.attach_to_window() {
                        log::error!("[macos] Failed to attach glass to window: {}", e);
                    }

                    // Store the manager globally.
                    if let Ok(mut guard) = GLASS_MANAGER.lock() {
                        *guard = Some(manager);
                        log::info!("[macos] NativeGlassManager stored globally");
                    }
                }
                Err(e) => {
                    log::error!("[macos] Failed to create NativeGlassManager: {}", e);
                }
            }
        }));
    });
}

/// Reapply native/sidebar frames after a WebView-visible resize or fullscreen change.
pub fn sync_native_sidebar() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        if let Ok(guard) = GLASS_MANAGER.lock() {
            if let Some(ref manager) = *guard {
                manager.sync_layout();
            }
        }
    }));
}

pub fn update_native_player(state: super::glass::NativePlayerState) {
    if let Ok(guard) = GLASS_MANAGER.lock() {
        if let Some(ref manager) = *guard { manager.update_player_state(state); }
    }
}
