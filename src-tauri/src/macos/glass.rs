use base64::Engine;
use objc2::{define_class, msg_send, rc::Retained, runtime::AnyObject, AnyThread, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSButton, NSGlassEffectView, NSGlassEffectViewStyle,
    NSVisualEffectView, NSVisualEffectMaterial, NSVisualEffectBlendingMode, NSVisualEffectState,
    NSFont, NSImage, NSImageView, NSSearchField, NSSlider, NSTextAlignment, NSView, NSWindow,
};
use objc2_foundation::{ns_string, NSPoint, NSRect, NSSize, NSString};
use serde::Deserialize;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use tauri::Emitter;

const SIDEBAR_WIDTH: f64 = 254.0;
const SIDEBAR_INSET: f64 = 12.0;

static APP_HANDLE: OnceLock<tauri::AppHandle> = OnceLock::new();

fn emit_sidebar_action(action: &str, query: Option<String>) {
    let Some(app) = APP_HANDLE.get() else {
        return;
    };

    let payload = serde_json::json!({ "action": action, "query": query });
    if let Err(error) = app.emit("native-sidebar-action", payload) {
        log::warn!("[macos] Failed to emit native sidebar action: {error}");
    }
}

define_class!(
    #[unsafe(super(objc2_foundation::NSObject))]
    #[thread_kind = MainThreadOnly]
    struct NativeSidebarController;

    impl NativeSidebarController {
        #[unsafe(method(showAllSongs:))]
        fn show_all_songs(&self, _sender: &AnyObject) { emit_sidebar_action("all", None); }

        #[unsafe(method(showLikedSongs:))]
        fn show_liked_songs(&self, _sender: &AnyObject) { emit_sidebar_action("liked", None); }

        #[unsafe(method(showRecentlyPlayed:))]
        fn show_recently_played(&self, _sender: &AnyObject) { emit_sidebar_action("recent", None); }

        #[unsafe(method(showNowPlaying:))]
        fn show_now_playing(&self, _sender: &AnyObject) { emit_sidebar_action("now-playing", None); }

        #[unsafe(method(showArtists:))]
        fn show_artists(&self, _sender: &AnyObject) { emit_sidebar_action("artists", None); }

        #[unsafe(method(showAlbums:))]
        fn show_albums(&self, _sender: &AnyObject) { emit_sidebar_action("albums", None); }

        #[unsafe(method(addFolder:))]
        fn add_folder(&self, _sender: &AnyObject) { emit_sidebar_action("add-folder", None); }

        #[unsafe(method(searchChanged:))]
        fn search_changed(&self, sender: &NSSearchField) {
            emit_sidebar_action("search", Some(sender.stringValue().to_string()));
        }

        #[unsafe(method(playerShuffle:))]
        fn player_shuffle(&self, _sender: &AnyObject) { emit_sidebar_action("player-shuffle", None); }
        #[unsafe(method(playerPrevious:))]
        fn player_previous(&self, _sender: &AnyObject) { emit_sidebar_action("player-previous", None); }
        #[unsafe(method(playerToggle:))]
        fn player_toggle(&self, _sender: &AnyObject) { emit_sidebar_action("player-toggle", None); }
        #[unsafe(method(playerNext:))]
        fn player_next(&self, _sender: &AnyObject) { emit_sidebar_action("player-next", None); }
        #[unsafe(method(playerRepeat:))]
        fn player_repeat(&self, _sender: &AnyObject) { emit_sidebar_action("player-repeat", None); }
        #[unsafe(method(playerLike:))]
        fn player_like(&self, _sender: &AnyObject) { emit_sidebar_action("player-like", None); }
        #[unsafe(method(playerQueue:))]
        fn player_queue(&self, _sender: &AnyObject) { emit_sidebar_action("player-queue", None); }
        #[unsafe(method(playerCoverClicked:))]
        fn player_cover_clicked(&self, _sender: &AnyObject) { emit_sidebar_action("player-open-lyrics", None); }

        #[unsafe(method(playerSeek:))]
        fn player_seek(&self, sender: &NSSlider) {
            let val = sender.doubleValue();
            emit_sidebar_action("player-seek", Some(val.to_string()));
        }

        #[unsafe(method(playerVolume:))]
        fn player_volume(&self, sender: &NSSlider) {
            let val = sender.doubleValue();
            emit_sidebar_action("player-volume", Some(val.to_string()));
        }

        #[unsafe(method(toggleVolume:))]
        fn toggle_volume(&self, _sender: &AnyObject) {
            // Detached bubble toggle is now handled by NativeGlassManager directly
            // (tag-based lookup threw foreign exception on Tahoe SDK).
            // Emit an action; window.rs will flip visibility.
            emit_sidebar_action("toggle-volume-popover", None);
        }
    }
);

impl NativeSidebarController {
    fn new(mtm: MainThreadMarker) -> Retained<Self> {
        let this = Self::alloc(mtm).set_ivars(());
        // SAFETY: NSObject's designated initializer has no additional requirements.
        unsafe { msg_send![super(this), init] }
    }
}

fn target(controller: &NativeSidebarController) -> &AnyObject {
    // SAFETY: Objective-C objects are layout-compatible with AnyObject; AppKit
    // retains neither targets nor actions, so NativeGlassManager retains controller.
    unsafe { &*(controller as *const NativeSidebarController as *const AnyObject) }
}

/// Owns the native sidebar and preserves the existing WKWebView as the library view.
pub struct NativeGlassManager {
    _window: Retained<NSWindow>,
    webview: Retained<NSView>,
    sidebar: Retained<NSView>,
    player: Retained<NSView>,
    volume_popover: Retained<NSView>,
    player_cover: Retained<NSImageView>,
    player_cover_btn: Retained<NSButton>,
    player_title: Retained<objc2_app_kit::NSTextField>,
    player_artist: Retained<objc2_app_kit::NSTextField>,
    player_time_label: Retained<objc2_app_kit::NSTextField>,
    player_play_btn: Retained<NSButton>,
    player_like_btn: Retained<NSButton>,
    player_shuffle_btn: Retained<NSButton>,
    player_repeat_btn: Retained<NSButton>,
    player_prev_btn: Retained<NSButton>,
    player_next_btn: Retained<NSButton>,
    player_waveform_btn: Retained<NSButton>,
    player_more_btn: Retained<NSButton>,
    player_lyrics_btn: Retained<NSButton>,
    player_queue_btn: Retained<NSButton>,
    player_volume_btn: Retained<NSButton>,
    player_progress_slider: Retained<NSSlider>,
    player_volume_slider: Retained<NSSlider>,
    _controller: Retained<NativeSidebarController>,
    in_lyrics_mode: AtomicBool,
    is_attached: bool,
    // Dirty-state cache — avoid repeated decode/setter work on every progress tick
    last_cover: Mutex<Option<String>>,
    last_title: Mutex<Option<String>>,
    last_artist: Mutex<Option<String>>,
    last_playing: AtomicBool,
    last_playing_init: AtomicBool,
    last_progress_bits: AtomicU64,
    last_volume_bits: AtomicU64,
    last_time_label: Mutex<Option<String>>,
    last_liked: Mutex<Option<bool>>,
    last_shuffle: Mutex<Option<bool>>,
    last_repeat: Mutex<Option<String>>,
}

#[derive(Deserialize, Debug)]
pub struct NativePlayerState {
    pub title: String,
    pub artist: String,
    pub playing: bool,
    pub cover: Option<String>,
    pub liked: Option<bool>,
    pub shuffle: Option<bool>,
    pub repeat: Option<String>,
    pub progress: Option<f64>,
    pub volume: Option<f64>,
    pub in_lyrics_mode: Option<bool>,
    pub elapsed: Option<String>,
    pub total: Option<String>,
}

unsafe impl Send for NativeGlassManager {}
unsafe impl Sync for NativeGlassManager {}

impl NativeGlassManager {
    pub fn new(
        ns_window_ptr: *mut std::ffi::c_void,
        wk_webview_ptr: *mut std::ffi::c_void,
        app: tauri::AppHandle,
    ) -> Result<Self, String> {
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| "[macos] Native sidebar must be created on the main thread".to_string())?;
        let _ = APP_HANDLE.set(app);

        if ns_window_ptr.is_null() || wk_webview_ptr.is_null() {
            return Err("[macos] NSWindow or WKWebView pointer is null".to_string());
        }

        // SAFETY: Tauri provides valid native pointers during with_webview.
        let window = unsafe {
            Retained::retain(ns_window_ptr.cast::<NSWindow>())
                .ok_or_else(|| "[macos] Failed to retain NSWindow".to_string())?
        };
        // SAFETY: WKWebView inherits NSView and is retained by Wry for the window lifetime.
        let webview = unsafe {
            Retained::retain(wk_webview_ptr.cast::<NSView>())
                .ok_or_else(|| "[macos] Failed to retain WKWebView".to_string())?
        };

        // Liquid Glass (Tahoe): try NSGlassEffectView first, fall back to NSVisualEffectView
        // on foreign exception. Both are retained as Retained<NSView> so every later
        // NSView callsite (addSubview / setHidden / setFrame / layer / subviews) keeps compiling.
        let sidebar: Retained<NSView> = match objc2::exception::catch(|| {
            let v = NSGlassEffectView::new(mtm);
            v.setStyle(NSGlassEffectViewStyle::Regular);
            v.setCornerRadius(22.0);
            v.setWantsLayer(true);
            if let Some(l) = v.layer() { l.setMasksToBounds(true); }
            unsafe { Retained::cast_unchecked(v) }
        }) {
            Ok(v) => {
                eprintln!("[macos] Liquid Glass sidebar — NSGlassEffectView ✓");
                v
            }
            Err(_) => {
                eprintln!("[macos] NSGlassEffectView failed for sidebar, fallback to NSVisualEffectView");
                let v = NSVisualEffectView::new(mtm);
                v.setMaterial(NSVisualEffectMaterial::Sidebar);
                v.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
                v.setState(NSVisualEffectState::Active);
                v.setWantsLayer(true);
                if let Some(l) = v.layer() { l.setCornerRadius(22.0); l.setMasksToBounds(true); }
                unsafe { Retained::cast_unchecked(v) }
            }
        };
        let player: Retained<NSView> = match objc2::exception::catch(|| {
            let v = NSGlassEffectView::new(mtm);
            v.setStyle(NSGlassEffectViewStyle::Regular);
            v.setCornerRadius(32.0);
            v.setWantsLayer(true);
            if let Some(l) = v.layer() { l.setMasksToBounds(true); }
            unsafe { Retained::cast_unchecked(v) }
        }) {
            Ok(v) => {
                eprintln!("[macos] Liquid Glass player — NSGlassEffectView ✓");
                v
            }
            Err(_) => {
                eprintln!("[macos] NSGlassEffectView failed for player, fallback");
                let v = NSVisualEffectView::new(mtm);
                v.setMaterial(NSVisualEffectMaterial::HUDWindow);
                v.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
                v.setState(NSVisualEffectState::Active);
                v.setWantsLayer(true);
                if let Some(l) = v.layer() { l.setCornerRadius(32.0); l.setMasksToBounds(true); }
                unsafe { Retained::cast_unchecked(v) }
            }
        };
        let volume_popover: Retained<NSView> = match objc2::exception::catch(|| {
            let v = NSGlassEffectView::new(mtm);
            v.setStyle(NSGlassEffectViewStyle::Regular);
            v.setCornerRadius(16.0);
            v.setWantsLayer(true);
            if let Some(l) = v.layer() { l.setMasksToBounds(true); }
            unsafe { Retained::cast_unchecked(v) }
        }) {
            Ok(v) => {
                eprintln!("[macos] Liquid Glass popover — NSGlassEffectView ✓");
                v
            }
            Err(_) => {
                eprintln!("[macos] NSGlassEffectView failed for popover, fallback");
                let v = NSVisualEffectView::new(mtm);
                v.setMaterial(NSVisualEffectMaterial::HUDWindow);
                v.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
                v.setState(NSVisualEffectState::Active);
                v.setWantsLayer(true);
                if let Some(l) = v.layer() { l.setCornerRadius(16.0); l.setMasksToBounds(true); }
                unsafe { Retained::cast_unchecked(v) }
            }
        };
        volume_popover.setHidden(true);
        let player_cover = NSImageView::new(mtm);
        let player_title = objc2_app_kit::NSTextField::labelWithString(ns_string!("Not Playing"), mtm);
        let player_artist = objc2_app_kit::NSTextField::labelWithString(ns_string!("-"), mtm);
        let player_time_label = objc2_app_kit::NSTextField::labelWithString(ns_string!("0:00 / 0:00"), mtm);
        player_time_label.setFont(Some(&NSFont::systemFontOfSize(10.0)));
        player_time_label.setTextColor(Some(&objc2_app_kit::NSColor::secondaryLabelColor()));
        // Allow the label to be visible over glass material
        unsafe { let _: () = msg_send![&*player_time_label, setBezeled: false]; }
        unsafe { let _: () = msg_send![&*player_time_label, setDrawsBackground: false]; }
        unsafe { let _: () = msg_send![&*player_time_label, setEditable: false]; }
        unsafe { let _: () = msg_send![&*player_time_label, setSelectable: false]; }

        let controller_obj = NativeSidebarController::new(mtm);
        let controller_target = target(&controller_obj);

        let title_cover = NSString::from_str("");
        let player_cover_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_cover, Some(controller_target), Some(objc2::sel!(playerCoverClicked:)), mtm) };
        player_cover_btn.setBordered(false);

        let title_play = NSString::from_str("▶");
        let player_play_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_play, Some(controller_target), Some(objc2::sel!(playerToggle:)), mtm) };
        player_play_btn.setBordered(false);

        let title_like = NSString::from_str("♡");
        let player_like_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_like, Some(controller_target), Some(objc2::sel!(playerLike:)), mtm) };
        player_like_btn.setBordered(false);

        let title_shuffle = NSString::from_str("⇄");
        let player_shuffle_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_shuffle, Some(controller_target), Some(objc2::sel!(playerShuffle:)), mtm) };
        player_shuffle_btn.setBordered(false);

        let title_repeat = NSString::from_str("↺");
        let player_repeat_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_repeat, Some(controller_target), Some(objc2::sel!(playerRepeat:)), mtm) };
        player_repeat_btn.setBordered(false);

        // Apple Music pill — exact transport + utility cluster (SF-style glyphs)
        let title_prev = NSString::from_str("⏮");
        let player_prev_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_prev, Some(controller_target), Some(objc2::sel!(playerPrevious:)), mtm) };
        player_prev_btn.setBordered(false);
        let title_next = NSString::from_str("⏭");
        let player_next_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_next, Some(controller_target), Some(objc2::sel!(playerNext:)), mtm) };
        player_next_btn.setBordered(false);
        let title_wave = NSString::from_str("♫");
        let player_waveform_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_wave, Some(controller_target), Some(objc2::sel!(playerShuffle:)), mtm) };
        player_waveform_btn.setBordered(false);
        let title_more = NSString::from_str("⋯");
        let player_more_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_more, Some(controller_target), Some(objc2::sel!(playerLike:)), mtm) };
        player_more_btn.setBordered(false);
        let title_lyrics = NSString::from_str("◫");
        let player_lyrics_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_lyrics, Some(controller_target), Some(objc2::sel!(playerCoverClicked:)), mtm) };
        player_lyrics_btn.setBordered(false);
        let title_queue = NSString::from_str("☰");
        let player_queue_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_queue, Some(controller_target), Some(objc2::sel!(playerQueue:)), mtm) };
        player_queue_btn.setBordered(false);
        let title_vol = NSString::from_str("");
        let player_volume_btn = unsafe { NSButton::buttonWithTitle_target_action(&title_vol, Some(controller_target), Some(objc2::sel!(toggleVolume:)), mtm) };
        player_volume_btn.setBordered(false);
        if let Some(img) = NSImage::imageWithSystemSymbolName_accessibilityDescription(ns_string!("speaker.wave.2.fill"), None) {
            img.setTemplate(true);
            player_volume_btn.setImage(Some(&img));
            player_volume_btn.setImagePosition(objc2_app_kit::NSCellImagePosition::ImageOnly);
        } else {
            player_volume_btn.setTitle(&NSString::from_str("◯))"));
        }

        let player_progress_slider = unsafe { NSSlider::sliderWithValue_minValue_maxValue_target_action(0.0, 0.0, 100.0, Some(controller_target), Some(objc2::sel!(playerSeek:)), mtm) };
        let player_volume_slider = unsafe { NSSlider::sliderWithValue_minValue_maxValue_target_action(100.0, 0.0, 100.0, Some(controller_target), Some(objc2::sel!(playerVolume:)), mtm) };

        Ok(Self {
            _window: window,
            webview,
            sidebar,
            player,
            volume_popover,
            player_cover,
            player_cover_btn,
            player_title,
            player_artist,
            player_time_label,
            player_play_btn,
            player_like_btn,
            player_shuffle_btn,
            player_repeat_btn,
            player_prev_btn,
            player_next_btn,
            player_waveform_btn,
            player_more_btn,
            player_lyrics_btn,
            player_queue_btn,
            player_volume_btn,
            player_progress_slider,
            player_volume_slider,
            _controller: controller_obj,
            in_lyrics_mode: AtomicBool::new(false),
            is_attached: false,
            last_cover: Mutex::new(None),
            last_title: Mutex::new(None),
            last_artist: Mutex::new(None),
            last_playing: AtomicBool::new(false),
            last_playing_init: AtomicBool::new(false),
            last_progress_bits: AtomicU64::new(f64::NAN.to_bits()),
            last_volume_bits: AtomicU64::new(f64::NAN.to_bits()),
            last_time_label: Mutex::new(None),
            last_liked: Mutex::new(None),
            last_shuffle: Mutex::new(None),
            last_repeat: Mutex::new(None),
        })
    }

    pub fn attach_to_window(&mut self) -> Result<(), String> {
        if self.is_attached {
            return Ok(());
        }

        // Configure NSWindow for native chrome: hide title, make titlebar transparent,
        // and allow full-size content so traffic lights sit in the native titlebar.
        unsafe {
            let _: () = msg_send![&*self._window, setTitleVisibility: 1i64];
            let _: () = msg_send![&*self._window, setTitlebarAppearsTransparent: true];
            // styleMask |= NSWindowStyleMaskFullSizeContentView (1 << 15)
            let current_mask: usize = msg_send![&*self._window, styleMask];
            let full_size: usize = 1 << 15;
            let _: () = msg_send![&*self._window, setStyleMask: current_mask | full_size];
            // Keep the window movable and traffic lights standard
            let _: () = msg_send![&*self._window, setMovableByWindowBackground: false];
            let _: () = msg_send![&*self._window, setHasShadow: true];
        }

        // SAFETY: Wry has attached the WebView before Tauri setup runs.
        let parent = unsafe { self.webview.superview() }
            .ok_or_else(|| "[macos] WKWebView has no superview".to_string())?;
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| "[macos] Native sidebar must attach on the main thread".to_string())?;
        let content = NSView::new(mtm);

        // NSVisualEffectView has no setContentView -- add as subview
        self.sidebar.addSubview(&content);
        parent.addSubview_positioned_relativeTo(
            &self.sidebar,
            objc2_app_kit::NSWindowOrderingMode::Above,
            Some(&self.webview),
        );
        parent.addSubview_positioned_relativeTo(
            &self.player,
            objc2_app_kit::NSWindowOrderingMode::Above,
            Some(&self.webview),
        );
        // Detached volume bubble — floats above the pill so it never covers the pill's buttons
        parent.addSubview_positioned_relativeTo(
            &self.volume_popover,
            objc2_app_kit::NSWindowOrderingMode::Above,
            Some(&self.player),
        );

        self.layout(&parent);
        // Volume bubble content — a small glass capsule containing the horizontal slider
        // Keep the slider offscreen inside the pillow until it is shown above the pill.
        {
            let popover_content = NSView::new(mtm);
            self.volume_popover.addSubview(&popover_content);
            // Size the content view to popover bounds once layout runs
            popover_content.setFrame(self.volume_popover.bounds());
            popover_content.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);
            self.player_volume_slider.setFrame(NSRect::new(NSPoint::new(12.0, 10.0), NSSize::new(120.0, 16.0)));
            self.player_volume_slider.setControlSize(objc2_app_kit::NSControlSize::Mini);
            popover_content.addSubview(&self.player_volume_slider);
        }
        // NSGlassEffectView guarantees its content is embedded in the material,
        // but does not infer a frame for a programmatically-created NSView.
        // Give it the sidebar's local bounds so controls cannot extend into the
        // adjacent WKWebView.
        content.setFrame(self.sidebar.bounds());
        content.setAutoresizingMask(
            NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
        );
        self.build_controls(&content, mtm);
        self.build_player(mtm);
        self.is_attached = true;
        if let Some(app) = APP_HANDLE.get() {
            let _ = app.emit("native-sidebar-ready", ());
        }
        log::info!("[macos] Native Liquid Glass sidebar attached beside WKWebView");
        Ok(())
    }

    fn build_controls(&self, content: &NSView, mtm: MainThreadMarker) {
        let controller = target(&self._controller);
        let search = NSSearchField::new(mtm);
        search.setPlaceholderString(Some(ns_string!("Search")));
        search.setSendsSearchStringImmediately(true);
        // SAFETY: controller implements searchChanged: and is retained by manager.
        unsafe {
            search.setTarget(Some(controller));
            search.setAction(Some(objc2::sel!(searchChanged:)));
        }
        search.setFrame(NSRect::new(NSPoint::new(16.0, 0.0), NSSize::new(SIDEBAR_WIDTH - 56.0, 30.0)));
        search.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&search);

        let items = [
            ("♫  All Songs", objc2::sel!(showAllSongs:)),
            ("♡  Liked Songs", objc2::sel!(showLikedSongs:)),
            ("◷  Recently Played", objc2::sel!(showRecentlyPlayed:)),
            ("▷  Now Playing", objc2::sel!(showNowPlaying:)),
            ("♙  Artists", objc2::sel!(showArtists:)),
            ("▤  Albums", objc2::sel!(showAlbums:)),
            ("＋  Add Folder", objc2::sel!(addFolder:)),
        ];
        let mut y = 0.0;
        for (title, action) in items {
            let title = NSString::from_str(title);
            // SAFETY: every selector is implemented by NativeSidebarController.
            let button = unsafe {
                NSButton::buttonWithTitle_target_action(&title, Some(controller), Some(action), mtm)
            };
            button.setBordered(false);
            button.setAlignment(NSTextAlignment::Left);
            button.setFont(Some(&NSFont::systemFontOfSize(16.0)));
            button.setFrame(NSRect::new(NSPoint::new(16.0, y), NSSize::new(SIDEBAR_WIDTH - 48.0, 30.0)));
            button.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewMinYMargin);
            content.addSubview(&button);
            y += 36.0;
        }

        // AppKit coordinates start at the bottom. Move the search and controls to
        // the top after the sidebar receives its initial frame.
        self.position_controls();
    }

    fn build_player(&self, mtm: MainThreadMarker) {
        let content = NSView::new(mtm);
        self.player.addSubview(&content);
        content.setFrame(self.player.bounds());
        content.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);

        let p_w = self.player.bounds().size.width.max(560.0);
        let p_h = self.player.bounds().size.height.max(64.0);

        // ——— Apple Music pill topology ———
        // Left transport cluster: shuffle · prev · play (prominent) · next · repeat
        // Center-left: 42pt artwork + 2-line meta
        // Right utilities: waveform · ⋯ · lyrics · queue · volume
        // Bottom: inset hairline progress (seekable) across the capsule
        // All frames here are initial; layout() repositions on every resize.

        // Artwork — 44pt square, vertically centered ( (66-44)/2 = 11 )
        let art_size: f64 = 44.0;
        let art_x: f64 = 212.0; // after left transport
        let art_y: f64 = (p_h - art_size) / 2.0 + 4.0; // +4 lifts above hairline progress
        self.player_cover.setFrame(NSRect::new(NSPoint::new(art_x, art_y), NSSize::new(art_size, art_size)));
        self.player_cover.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMaxXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        self.player_cover.setWantsLayer(true);
        if let Some(layer) = self.player_cover.layer() {
            layer.setCornerRadius(7.0);
            layer.setMasksToBounds(true);
        }
        content.addSubview(&self.player_cover);

        self.player_cover_btn.setFrame(NSRect::new(NSPoint::new(art_x, art_y), NSSize::new(art_size, art_size)));
        self.player_cover_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMaxXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        self.player_cover_btn.setWantsLayer(true);
        if let Some(layer) = self.player_cover_btn.layer() {
            layer.setCornerRadius(7.0);
            layer.setMasksToBounds(true);
        }
        content.addSubview(&self.player_cover_btn);

        // Metadata — to the right of artwork, tighter stack for pill
        self.player_title.setFrame(NSRect::new(NSPoint::new(art_x + art_size + 10.0, art_y + 22.0), NSSize::new((p_w - art_x - art_size - 230.0).max(120.0), 15.0)));
        self.player_artist.setFrame(NSRect::new(NSPoint::new(art_x + art_size + 10.0, art_y + 8.0), NSSize::new((p_w - art_x - art_size - 230.0).max(120.0), 12.0)));
        self.player_title.setFont(Some(&NSFont::systemFontOfSize(12.5)));
        self.player_artist.setFont(Some(&NSFont::systemFontOfSize(11.0)));
        self.player_artist.setTextColor(Some(&objc2_app_kit::NSColor::secondaryLabelColor()));
        content.addSubview(&self.player_title);
        content.addSubview(&self.player_artist);

        // Time label — hidden in Apple pill (progress is hairline, time on hover only)
        self.player_time_label.setFrame(NSRect::new(NSPoint::new(art_x + art_size + 10.0, 5.0), NSSize::new(72.0, 11.0)));
        self.player_time_label.setHidden(true);
        content.addSubview(&self.player_time_label);

        // Left transport — compact, vertically centered above hairline
        let cy: f64 = (p_h / 2.0) + 5.0;
        self.player_shuffle_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        self.player_shuffle_btn.setFrame(NSRect::new(NSPoint::new(14.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_shuffle_btn);

        self.player_prev_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        self.player_prev_btn.setFrame(NSRect::new(NSPoint::new(46.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_prev_btn);

        self.player_play_btn.setFont(Some(&NSFont::systemFontOfSize(18.0)));
        self.player_play_btn.setFrame(NSRect::new(NSPoint::new(78.0, cy - 18.0), NSSize::new(36.0, 36.0)));
        self.player_play_btn.setWantsLayer(true);
        if let Some(layer) = self.player_play_btn.layer() {
            layer.setCornerRadius(18.0);
            layer.setMasksToBounds(false);
        }
        content.addSubview(&self.player_play_btn);

        self.player_next_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        self.player_next_btn.setFrame(NSRect::new(NSPoint::new(120.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_next_btn);

        self.player_repeat_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        self.player_repeat_btn.setFrame(NSRect::new(NSPoint::new(152.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_repeat_btn);

        // Right utility cluster — 28pt buttons, 8pt gaps, vertically centered
        // Order left→right: waveform · ⋯ · lyrics · queue · volume
        let right_x = p_w - 14.0;
        // Volume uses SF Symbol image, not font — keep frame only here
        self.player_volume_btn.setFrame(NSRect::new(NSPoint::new(right_x - 28.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_volume_btn);

        self.player_queue_btn.setFont(Some(&NSFont::systemFontOfSize(14.0)));
        self.player_queue_btn.setFrame(NSRect::new(NSPoint::new(right_x - 64.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_queue_btn);

        self.player_lyrics_btn.setFont(Some(&NSFont::systemFontOfSize(14.0)));
        self.player_lyrics_btn.setFrame(NSRect::new(NSPoint::new(right_x - 100.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_lyrics_btn);

        self.player_more_btn.setFont(Some(&NSFont::systemFontOfSize(14.0)));
        self.player_more_btn.setFrame(NSRect::new(NSPoint::new(right_x - 136.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_more_btn);

        self.player_waveform_btn.setFont(Some(&NSFont::systemFontOfSize(14.0)));
        self.player_waveform_btn.setFrame(NSRect::new(NSPoint::new(right_x - 172.0, cy - 14.0), NSSize::new(28.0, 28.0)));
        content.addSubview(&self.player_waveform_btn);

        // Keep legacy like button hidden (replaced by ⋯) — retain for state updates but offscreen
        self.player_like_btn.setFrame(NSRect::new(NSPoint::new(-100.0, -100.0), NSSize::new(0.0, 0.0)));
        self.player_like_btn.setHidden(true);
        content.addSubview(&self.player_like_btn);

        // Inset hairline progress — knobless, Apple-pill style
        // Inset 24pt each side so the 4pt line sits inside the capsule curve at y=4
        // (at y=4 with radius 33, inset 14 clips ~3pt into the corner; 24 stays fully inside)
        self.player_progress_slider.setFrame(NSRect::new(NSPoint::new(24.0, 4.0), NSSize::new((p_w - 48.0).max(80.0), 4.0)));
        self.player_progress_slider.setControlSize(objc2_app_kit::NSControlSize::Mini);
        self.player_progress_slider.setWantsLayer(true);
        if let Some(layer) = self.player_progress_slider.layer() {
            layer.setCornerRadius(2.0);
            layer.setMasksToBounds(true);
        }
        // Drop the knob — knobless line; keep it crash-safe (no empty image alloc)
        unsafe {
            let cell: *mut AnyObject = msg_send![&*self.player_progress_slider, cell];
            if !cell.is_null() {
                let _: () = msg_send![cell, setKnobThickness: 0.0];
            }
        }
        content.addSubview(&self.player_progress_slider);

        // Volume slider now lives in the detached popover — keep pill clean so buttons are never covered
    }

    fn position_traffic_lights(&self, _parent: &NSView) {
        // Move native traffic lights from the window chrome into the sidebar
        // glass capsule, like Finder/Music. Buttons live in the titlebar's
        // superview; their frameOrigin is in that superview's coordinates.
        // Finder places them ~20pt below the window top (8pt below the 12pt
        // outer inset), i.e. ~12pt inside a 32pt titlebar and 20pt spaced.
        unsafe {
            let close: Option<Retained<NSButton>> = msg_send![&*self._window, standardWindowButton: 0u64];
            let mini: Option<Retained<NSButton>> = msg_send![&*self._window, standardWindowButton: 1u64];
            let zoom: Option<Retained<NSButton>> = msg_send![&*self._window, standardWindowButton: 2u64];
            if let Some(ref btn) = close {
                if let Some(sv) = btn.superview() {
                    let sh = sv.bounds().size.height;
                    let ly = if (20.0..=40.0).contains(&sh) { sh - 34.0 } else { -2.0 };
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 16.0, ly));
                } else {
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 16.0, -2.0));
                }
                let _: () = msg_send![&**btn, setHidden: false];
            }
            if let Some(ref btn) = mini {
                if let Some(sv) = btn.superview() {
                    let sh = sv.bounds().size.height;
                    let ly = if (20.0..=40.0).contains(&sh) { sh - 34.0 } else { -2.0 };
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 36.0, ly));
                } else {
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 36.0, -2.0));
                }
                let _: () = msg_send![&**btn, setHidden: false];
            }
            if let Some(ref btn) = zoom {
                if let Some(sv) = btn.superview() {
                    let sh = sv.bounds().size.height;
                    let ly = if (20.0..=40.0).contains(&sh) { sh - 34.0 } else { -2.0 };
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 56.0, ly));
                } else {
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 56.0, -2.0));
                }
                let _: () = msg_send![&**btn, setHidden: false];
            }
        }
    }

    fn position_controls(&self) {
        // sidebar content is first subview (VisualEffect has no contentView)
        let Some(content) = self.sidebar.subviews().firstObject() else { return; };
        let height = content.bounds().size.height;
        let subviews = content.subviews();
        for (index, view) in subviews.iter().enumerate() {
            let mut frame = view.frame();
            // Keep the traffic-light zone inside the glass capsule but reserve
            // generous space above the first native control, like Finder.
            frame.origin.y = height - 100.0 - (index as f64 * 42.0);
            view.setFrame(frame);
        }
    }

    fn layout(&self, parent: &NSView) {
        let bounds = parent.bounds();
        let lyrics_mode = self.in_lyrics_mode.load(Ordering::Relaxed);

        if lyrics_mode {
            // LYRICS MODE:
            // Hide native sidebar and native mini-player completely.
            // WKWebView occupies 100% of the available content area!
            self.sidebar.setHidden(true);
            self.player.setHidden(true);
            self.webview.setFrame(NSRect::new(
                NSPoint::new(0.0, 0.0),
                NSSize::new(bounds.size.width, bounds.size.height),
            ));
            self.webview.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
            );
            self.volume_popover.setHidden(true);
        } else {
            // NORMAL MODE:
            // Native sidebar on left, WKWebView in main content area, Native mini-player at bottom.
            self.sidebar.setHidden(false);
            self.player.setHidden(false);

            let sidebar_height = (bounds.size.height - (SIDEBAR_INSET * 2.0)).max(0.0);
            self.sidebar.setFrame(NSRect::new(
                NSPoint::new(SIDEBAR_INSET, SIDEBAR_INSET),
                NSSize::new(SIDEBAR_WIDTH - SIDEBAR_INSET, sidebar_height),
            ));
            self.sidebar.setAutoresizingMask(NSAutoresizingMaskOptions::ViewHeightSizable);
            // Mitigate hard seam: remove glass border so sidebar blends into unified #1c1c20 surface
            if let Some(layer) = self.sidebar.layer() {
                layer.setBorderWidth(0.0);
            }

            self.webview.setFrame(NSRect::new(
                NSPoint::new(SIDEBAR_WIDTH, 0.0),
                NSSize::new((bounds.size.width - SIDEBAR_WIDTH).max(0.0), bounds.size.height),
            ));
            self.webview.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
            );
            let player_width = ((bounds.size.width - SIDEBAR_WIDTH - 32.0).min(860.0)).max(560.0);
            let p_h: f64 = 66.0;
            self.player.setFrame(NSRect::new(
                NSPoint::new(SIDEBAR_WIDTH + ((bounds.size.width - SIDEBAR_WIDTH - player_width) / 2.0), 14.0),
                NSSize::new(player_width, p_h),
            ));
            if let Some(l) = self.player.layer() { l.setCornerRadius(p_h / 2.0); l.setMasksToBounds(true); }
            self.player.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewMinXMargin
                    | NSAutoresizingMaskOptions::ViewMaxXMargin
                    | NSAutoresizingMaskOptions::ViewMaxYMargin,
            );
            self.position_controls();
            self.position_traffic_lights(&parent);
            // Apple pill reflow — keep transport/meta/right cluster + hairline in sync on resize
            let p_w = self.player.bounds().size.width;
            if p_w > 100.0 {
                if let Some(content) = self.player.subviews().firstObject().as_deref() {
                    content.setFrame(self.player.bounds());
                    let art_size: f64 = 44.0;
                    let art_x: f64 = 212.0;
                    let art_y: f64 = (p_h - art_size) / 2.0 + 4.0;
                    let cy: f64 = (p_h / 2.0) + 5.0;
                    self.player_cover.setFrame(NSRect::new(NSPoint::new(art_x, art_y), NSSize::new(art_size, art_size)));
                    self.player_cover_btn.setFrame(NSRect::new(NSPoint::new(art_x, art_y), NSSize::new(art_size, art_size)));
                    let meta_w = (p_w - art_x - art_size - 230.0).max(120.0);
                    self.player_title.setFrame(NSRect::new(NSPoint::new(art_x + art_size + 10.0, art_y + 22.0), NSSize::new(meta_w, 15.0)));
                    self.player_artist.setFrame(NSRect::new(NSPoint::new(art_x + art_size + 10.0, art_y + 8.0), NSSize::new(meta_w, 12.0)));
                    self.player_shuffle_btn.setFrame(NSRect::new(NSPoint::new(14.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_prev_btn.setFrame(NSRect::new(NSPoint::new(46.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_play_btn.setFrame(NSRect::new(NSPoint::new(78.0, cy - 18.0), NSSize::new(36.0, 36.0)));
                    self.player_next_btn.setFrame(NSRect::new(NSPoint::new(120.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_repeat_btn.setFrame(NSRect::new(NSPoint::new(152.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    let right_x = p_w - 14.0;
                    self.player_volume_btn.setFrame(NSRect::new(NSPoint::new(right_x - 28.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_queue_btn.setFrame(NSRect::new(NSPoint::new(right_x - 64.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_lyrics_btn.setFrame(NSRect::new(NSPoint::new(right_x - 100.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_more_btn.setFrame(NSRect::new(NSPoint::new(right_x - 136.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_waveform_btn.setFrame(NSRect::new(NSPoint::new(right_x - 172.0, cy - 14.0), NSSize::new(28.0, 28.0)));
                    self.player_progress_slider.setFrame(NSRect::new(NSPoint::new(24.0, 4.0), NSSize::new((p_w - 48.0).max(80.0), 4.0)));
                }
                // Float the detached volume bubble above the speaker — never inside the pill
                let popover_w: f64 = 144.0;
                let popover_h: f64 = 36.0;
                let player_frame = self.player.frame();
                let popover_x = player_frame.origin.x + player_frame.size.width - popover_w - 6.0;
                let popover_y = player_frame.origin.y + player_frame.size.height + 8.0;
                self.volume_popover.setFrame(NSRect::new(NSPoint::new(popover_x, popover_y), NSSize::new(popover_w, popover_h)));
                self.volume_popover.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
                if let Some(content) = self.volume_popover.subviews().firstObject() {
                    content.setFrame(self.volume_popover.bounds());
                    // keep slider centered inside bubble
                    self.player_volume_slider.setFrame(NSRect::new(NSPoint::new(12.0, 10.0), NSSize::new(popover_w - 24.0, 16.0)));
                }
            }
        }
    }

    pub fn set_lyrics_mode(&self, enabled: bool) {
        self.in_lyrics_mode.store(enabled, Ordering::Relaxed);
        self.sync_layout();
    }

    pub fn sync_layout(&self) {
        if !self.is_attached {
            return;
        }
        // SAFETY: the retained sidebar is attached to this parent on the main thread.
        if let Some(parent) = unsafe { self.sidebar.superview() } {
            self.layout(&parent);
        }
    }

    pub fn toggle_volume_popover(&self) {
        if !self.is_attached {
            return;
        }
        let hidden = self.volume_popover.isHidden();
        self.volume_popover.setHidden(!hidden);
    }

    pub fn update_player_state(&self, state: NativePlayerState) {
        if let Some(lyrics) = state.in_lyrics_mode {
            // Avoid redundant layout thrash if mode hasn't changed
            if lyrics != self.in_lyrics_mode.load(Ordering::Relaxed) {
                self.set_lyrics_mode(lyrics);
            }
        }

        // Title — only when changed
        {
            let mut last = self.last_title.lock().unwrap();
            if last.as_deref() != Some(&state.title) {
                self.player_title.setStringValue(&NSString::from_str(&state.title));
                *last = Some(state.title.clone());
            }
        }
        // Artist — only when changed
        {
            let mut last = self.last_artist.lock().unwrap();
            if last.as_deref() != Some(&state.artist) {
                self.player_artist.setStringValue(&NSString::from_str(&state.artist));
                *last = Some(state.artist.clone());
            }
        }
        // Playing state — dirty check (modern glyphs)
        {
            let init = self.last_playing_init.load(Ordering::Relaxed);
            let last = self.last_playing.load(Ordering::Relaxed);
            if !init || last != state.playing {
                self.player_play_btn
                    .setTitle(&NSString::from_str(if state.playing { "⏸" } else { "▶" }));
                self.last_playing.store(state.playing, Ordering::Relaxed);
                self.last_playing_init.store(true, Ordering::Relaxed);
            }
        }

        // Progress — coalesce tiny changes (<0.08%) to avoid slider thrash
        if let Some(progress) = state.progress {
            let last_bits = self.last_progress_bits.load(Ordering::Relaxed);
            let last = f64::from_bits(last_bits);
            let should_update = if last.is_nan() {
                true
            } else {
                (progress - last).abs() >= 0.08
            };
            if should_update {
                self.player_progress_slider.setDoubleValue(progress);
                self.last_progress_bits
                    .store(progress.to_bits(), Ordering::Relaxed);
            }
        }

        // Volume — coalesce <0.5 changes
        if let Some(volume) = state.volume {
            let last_bits = self.last_volume_bits.load(Ordering::Relaxed);
            let last = f64::from_bits(last_bits);
            let should_update = if last.is_nan() {
                true
            } else {
                (volume - last).abs() >= 0.5
            };
            if should_update {
                self.player_volume_slider.setDoubleValue(volume);
                self.last_volume_bits.store(volume.to_bits(), Ordering::Relaxed);
            }
        }

        // Cover — decode only when identifier changes; cache prevents re-decode on every tick
        // Note: None means no update (progress-only tick), not “clear”.
        if let Some(ref cover_str) = state.cover {
            let should_decode = {
                let last = self.last_cover.lock().unwrap();
                last.as_deref() != Some(cover_str.as_str())
            };
            if should_decode {
                if cover_str.trim().is_empty() {
                    self.player_cover.setImage(None);
                } else {
                    let bytes_opt = if cover_str.starts_with("data:") {
                        cover_str.split_once(',').and_then(|(_, b64)| {
                            base64::engine::general_purpose::STANDARD.decode(b64).ok()
                        })
                    } else if let Ok(data) = std::fs::read(cover_str) {
                        Some(data)
                    } else {
                        None
                    };

                    if let Some(bytes) = bytes_opt {
                        let ns_data = objc2_foundation::NSData::with_bytes(&bytes);
                        let ns_image = NSImage::initWithData(NSImage::alloc(), &ns_data);
                        self.player_cover.setImage(ns_image.as_deref());
                    } else {
                        self.player_cover.setImage(None);
                    }
                }
                *self.last_cover.lock().unwrap() = Some(cover_str.clone());
            }
        }

        if let Some(liked) = state.liked {
            let mut last = self.last_liked.lock().unwrap();
            if *last != Some(liked) {
                self.player_like_btn
                    .setTitle(&NSString::from_str(if liked { "♥" } else { "♡" }));
                *last = Some(liked);
            }
        }

        if let Some(shuffle) = state.shuffle {
            let mut last = self.last_shuffle.lock().unwrap();
            if *last != Some(shuffle) {
                self.player_shuffle_btn
                    .setTitle(&NSString::from_str(if shuffle { "🔀" } else { "⇄" }));
                *last = Some(shuffle);
            }
        }

        if let Some(ref repeat_mode) = state.repeat {
            let mut last = self.last_repeat.lock().unwrap();
            if last.as_deref() != Some(repeat_mode.as_str()) {
                let sym = match repeat_mode.as_str() {
                    "one" => "🔂",
                    "all" => "🔁",
                    _ => "↺",
                };
                self.player_repeat_btn.setTitle(&NSString::from_str(sym));
                *last = Some(repeat_mode.clone());
            }
        }

        // Update time label — only when string changes
        if state.elapsed.is_some() || state.total.is_some() {
            let elapsed = state.elapsed.as_deref().unwrap_or("0:00");
            let total = state.total.as_deref().unwrap_or("0:00");
            let combined = format!("{} / {}", elapsed, total);
            let mut last = self.last_time_label.lock().unwrap();
            if last.as_deref() != Some(&combined) {
                self.player_time_label
                    .setStringValue(&NSString::from_str(&combined));
                *last = Some(combined);
            }
        }
    }
}
