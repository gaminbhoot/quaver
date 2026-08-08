use tauri::Window;

/// macOS native glass materials helper module according to Section 4, 9, and 53 of
/// Quaver_macOS_Liquid_Glass_Guide.md.
pub fn apply_native_glass_effect(_window: &Window) {
    #[cfg(target_os = "macos")]
    {
        // Placeholder boundary for AppKit NSGlassEffectView / NSVisualEffectView integration
        // per Section 4 and Section 55 of the design guide.
    }
}
