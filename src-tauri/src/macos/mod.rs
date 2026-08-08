// src-tauri/src/macos/mod.rs
// Native macOS integration module for Quaver.
// Bridges Tauri's WKWebView with AppKit Liquid Glass (NSGlassEffectView).

pub mod glass;
pub mod window;

pub use glass::NativeGlassManager;
