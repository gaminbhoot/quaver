# Quaver macOS Native Liquid Glass Architecture

## Overview
Quaver implements a hybrid architecture combining Tauri 2 + WKWebView with native macOS AppKit `NSGlassEffectView` and `NSGlassEffectContainerView` controls.

```text
                    QUAVER
                       │
            ┌──────────┴──────────┐
            │                     │
          Tauri                 AppKit
            │                     │
        WKWebView              NSWindow
            │                     │
       HTML / JS             Liquid Glass
            │                     │
       Application UI       Native surfaces
            │                     │
            └──────────┬──────────┘
                       │
                    macOS 26+
```

## System Requirements & Dependencies
- **Target Platform**: macOS 26+
- **Tauri Framework**: Tauri 2.11.5
- **Objective-C Runtime Crates**:
  - `objc2`: `v0.6.4`
  - `objc2-app-kit`: `v0.3.2` (Features: `NSResponder`, `NSView`, `NSWindow`, `NSColor`, `NSGlassEffectView`, `objc2-core-foundation`)
  - `objc2-foundation`: `v0.3.2` (Features: `NSGeometry`, `NSString`, `NSThread`)

## Native Glass Architecture
The native macOS glass integration consists of four main components in `src-tauri/src/macos/`:

1. **`glass.rs` (`NativeGlassManager`)**:
   - Instantiates `NSGlassEffectView` for the Sidebar (style: `Regular`, corner radius: `18.0`).
   - Instantiates `NSGlassEffectView` for the Mini-Player (style: `Regular`, corner radius: `24.0`).
   - Wraps both glass surfaces inside an `NSGlassEffectContainerView` to merge nearby glass effects and optimize rendering passes.
   - Inserts the container into the `NSWindow` content view's hierarchy directly below the `WKWebView`.

2. **`webview.rs` (`make_webview_transparent`)**:
   - Uses Key-Value Coding (KVC) on the `WKWebView` to set `drawsBackground = NO`.
   - Makes the web view container background transparent so native glass surfaces beneath it render through without obstruction.

3. **`geometry.rs` (`GlassRegionGeometry`)**:
   - Converts browser coordinate space (origin top-left, Y downward) to AppKit coordinate space (origin bottom-left, Y upward).
   - Handles `devicePixelRatio` and window content height adjustments.

4. **`window.rs` (`initialize_native_glass`)**:
   - Acquired via `window.with_webview()` on the main thread during app setup.
   - Retains `NativeGlassManager` instance for the lifetime of the window.

## Frontend Bridge (`src/nativeGlass.js`)
- Uses `getBoundingClientRect()` on DOM elements (`.sidebar`, `.mini-player`).
- Uses `ResizeObserver` and window `resize`/`fullscreenchange` event listeners.
- Sends geometry updates to Rust via `update_glass_geometry` IPC command with frame debouncing (~16ms).
- Adds `native-glass-active` class to `document.documentElement` to toggle CSS container transparency.

## Fallback Behavior & Accessibility
- **CSS Fallback**: When native glass is inactive or running on non-macOS platforms, CSS `backdrop-filter: blur(...)` styles remain intact.
- **Reduced Transparency**: Fully supports `@media (prefers-reduced-transparency: reduce)` by substituting solid opaque backgrounds for accessibility compliance.
- **Public API Safety**: No `macos-private-api` flags used; fully App Store compliant.
