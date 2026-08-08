use base64::Engine;
use objc2::{define_class, msg_send, rc::Retained, runtime::AnyObject, AnyThread, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSButton, NSGlassEffectView, NSGlassEffectViewStyle,
    NSFont, NSImage, NSImageView, NSSearchField, NSSlider, NSTextAlignment, NSView, NSWindow,
};
use objc2_foundation::{ns_string, NSPoint, NSRect, NSSize, NSString};
use serde::Deserialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;
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
    sidebar: Retained<NSGlassEffectView>,
    player: Retained<NSGlassEffectView>,
    player_cover: Retained<NSImageView>,
    player_cover_btn: Retained<NSButton>,
    player_title: Retained<objc2_app_kit::NSTextField>,
    player_artist: Retained<objc2_app_kit::NSTextField>,
    player_time_label: Retained<objc2_app_kit::NSTextField>,
    player_play_btn: Retained<NSButton>,
    player_like_btn: Retained<NSButton>,
    player_shuffle_btn: Retained<NSButton>,
    player_repeat_btn: Retained<NSButton>,
    player_progress_slider: Retained<NSSlider>,
    player_volume_slider: Retained<NSSlider>,
    _controller: Retained<NativeSidebarController>,
    in_lyrics_mode: AtomicBool,
    is_attached: bool,
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

        let sidebar = NSGlassEffectView::new(mtm);
        sidebar.setStyle(NSGlassEffectViewStyle::Regular);
        sidebar.setCornerRadius(22.0);
        let player = NSGlassEffectView::new(mtm);
        player.setStyle(NSGlassEffectViewStyle::Regular);
        player.setCornerRadius(26.0);
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

        let player_progress_slider = unsafe { NSSlider::sliderWithValue_minValue_maxValue_target_action(0.0, 0.0, 100.0, Some(controller_target), Some(objc2::sel!(playerSeek:)), mtm) };
        let player_volume_slider = unsafe { NSSlider::sliderWithValue_minValue_maxValue_target_action(100.0, 0.0, 100.0, Some(controller_target), Some(objc2::sel!(playerVolume:)), mtm) };

        Ok(Self {
            _window: window,
            webview,
            sidebar,
            player,
            player_cover,
            player_cover_btn,
            player_title,
            player_artist,
            player_time_label,
            player_play_btn,
            player_like_btn,
            player_shuffle_btn,
            player_repeat_btn,
            player_progress_slider,
            player_volume_slider,
            _controller: controller_obj,
            in_lyrics_mode: AtomicBool::new(false),
            is_attached: false,
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

        self.sidebar.setContentView(Some(&content));
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

        self.layout(&parent);
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
        self.player.setContentView(Some(&content));
        content.setFrame(self.player.bounds());
        content.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable);

        // Artwork View & Clickable Button on Left
        self.player_cover.setFrame(NSRect::new(NSPoint::new(16.0, 16.0), NSSize::new(48.0, 48.0)));
        self.player_cover.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMaxXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        self.player_cover.setWantsLayer(true);
        if let Some(layer) = self.player_cover.layer() {
            layer.setCornerRadius(10.0);
            layer.setMasksToBounds(true);
        }
        content.addSubview(&self.player_cover);

        self.player_cover_btn.setFrame(NSRect::new(NSPoint::new(16.0, 16.0), NSSize::new(48.0, 48.0)));
        self.player_cover_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMaxXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        self.player_cover_btn.setWantsLayer(true);
        if let Some(layer) = self.player_cover_btn.layer() {
            layer.setCornerRadius(10.0);
            layer.setMasksToBounds(true);
        }
        content.addSubview(&self.player_cover_btn);

        // Metadata Labels — shifted up to clear progress bar
        self.player_title.setFrame(NSRect::new(NSPoint::new(74.0, 46.0), NSSize::new(200.0, 18.0)));
        self.player_artist.setFrame(NSRect::new(NSPoint::new(74.0, 30.0), NSSize::new(200.0, 14.0)));
        self.player_title.setFont(Some(&NSFont::systemFontOfSize(13.0)));
        self.player_artist.setFont(Some(&NSFont::systemFontOfSize(11.0)));
        self.player_artist.setTextColor(Some(&objc2_app_kit::NSColor::secondaryLabelColor()));
        content.addSubview(&self.player_title);
        content.addSubview(&self.player_artist);

        // Time label (elapsed / total) — sits inline with progress, left of slider
        self.player_time_label.setFrame(NSRect::new(NSPoint::new(74.0, 8.0), NSSize::new(80.0, 14.0)));
        self.player_time_label.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMaxXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_time_label);

        let controller = target(&self._controller);

        // Playback Controls (Shuffle, Prev, Play/Pause, Next, Repeat)
        self.player_shuffle_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        self.player_shuffle_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 290.0, 24.0), NSSize::new(34.0, 34.0)));
        self.player_shuffle_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_shuffle_btn);

        let prev_title = NSString::from_str("◀");
        let prev_btn = unsafe { NSButton::buttonWithTitle_target_action(&prev_title, Some(controller), Some(objc2::sel!(playerPrevious:)), mtm) };
        prev_btn.setBordered(false);
        prev_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        prev_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 252.0, 24.0), NSSize::new(34.0, 34.0)));
        prev_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&prev_btn);

        self.player_play_btn.setFont(Some(&NSFont::systemFontOfSize(16.0)));
        self.player_play_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 214.0, 24.0), NSSize::new(36.0, 34.0)));
        self.player_play_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_play_btn);

        let next_title = NSString::from_str("▶▶");
        let next_btn = unsafe { NSButton::buttonWithTitle_target_action(&next_title, Some(controller), Some(objc2::sel!(playerNext:)), mtm) };
        next_btn.setBordered(false);
        next_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        next_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 174.0, 24.0), NSSize::new(38.0, 34.0)));
        next_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&next_btn);

        self.player_repeat_btn.setFont(Some(&NSFont::systemFontOfSize(15.0)));
        self.player_repeat_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 132.0, 24.0), NSSize::new(34.0, 34.0)));
        self.player_repeat_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_repeat_btn);

        // Secondary Action Controls (Like, Queue)
        self.player_like_btn.setFont(Some(&NSFont::systemFontOfSize(16.0)));
        self.player_like_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 86.0, 24.0), NSSize::new(34.0, 34.0)));
        self.player_like_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_like_btn);

        let queue_title = NSString::from_str("≡");
        let queue_btn = unsafe { NSButton::buttonWithTitle_target_action(&queue_title, Some(controller), Some(objc2::sel!(playerQueue:)), mtm) };
        queue_btn.setBordered(false);
        queue_btn.setFont(Some(&NSFont::systemFontOfSize(16.0)));
        queue_btn.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 48.0, 24.0), NSSize::new(34.0, 34.0)));
        queue_btn.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&queue_btn);

        // Progress slider (seek) — shifted down to clear artist label, now starts after time label
        self.player_progress_slider.setFrame(NSRect::new(NSPoint::new(160.0, 8.0), NSSize::new((self.player.bounds().size.width - 346.0).max(80.0), 14.0)));
        self.player_progress_slider.setAutoresizingMask(NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_progress_slider);

        // Volume slider - right side small slider
        self.player_volume_slider.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 118.0, 8.0), NSSize::new(70.0, 14.0)));
        self.player_volume_slider.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
        content.addSubview(&self.player_volume_slider);
    }

    fn position_traffic_lights(&self, parent: &NSView) {
        // Move native traffic lights from the window chrome into the sidebar
        // glass capsule, like Finder/Music. Buttons live in the titlebar's
        // superview; their frameOrigin is in that superview's coordinates.
        // Finder places them ~20pt below the window top (8pt below the 12pt
        // outer inset), i.e. ~12pt inside a 32pt titlebar and 20pt spaced.
        let win_frame = self._window.frame();
        let win_h = win_frame.size.height;
        let parent_h = parent.bounds().size.height;
        eprintln!("[traffic] win_h={:.1} parent_h={:.1}", win_h, parent_h);
        unsafe {
            let close: Option<Retained<NSButton>> = msg_send![&*self._window, standardWindowButton: 0u64];
            let mini: Option<Retained<NSButton>> = msg_send![&*self._window, standardWindowButton: 1u64];
            let zoom: Option<Retained<NSButton>> = msg_send![&*self._window, standardWindowButton: 2u64];
            eprintln!("[traffic] buttons close={} mini={} zoom={}", close.is_some(), mini.is_some(), zoom.is_some());
            if let Some(ref btn) = close {
                if let Some(sv) = btn.superview() {
                    let sh = sv.bounds().size.height;
                    eprintln!("[traffic] close superview h={:.1} frame={:?}", sh, btn.frame());
                    let ly = if (20.0..=40.0).contains(&sh) { sh - 24.0 } else { 8.0 };
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 16.0, ly));
                } else {
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 16.0, 8.0));
                }
                let _: () = msg_send![&**btn, setHidden: false];
            }
            if let Some(ref btn) = mini {
                if let Some(sv) = btn.superview() {
                    let sh = sv.bounds().size.height;
                    let ly = if (20.0..=40.0).contains(&sh) { sh - 24.0 } else { 8.0 };
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 36.0, ly));
                } else {
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 36.0, 8.0));
                }
                let _: () = msg_send![&**btn, setHidden: false];
            }
            if let Some(ref btn) = zoom {
                if let Some(sv) = btn.superview() {
                    let sh = sv.bounds().size.height;
                    let ly = if (20.0..=40.0).contains(&sh) { sh - 24.0 } else { 8.0 };
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 56.0, ly));
                } else {
                    btn.setFrameOrigin(NSPoint::new(SIDEBAR_INSET + 56.0, 8.0));
                }
                let _: () = msg_send![&**btn, setHidden: false];
            }
        }
    }

    fn position_controls(&self) {
        let Some(content) = self.sidebar.contentView() else { return; };
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
            let player_width = ((bounds.size.width - SIDEBAR_WIDTH - 120.0).min(820.0)).max(460.0);
            self.player.setFrame(NSRect::new(
                NSPoint::new(SIDEBAR_WIDTH + ((bounds.size.width - SIDEBAR_WIDTH - player_width) / 2.0), 18.0),
                NSSize::new(player_width, 82.0),
            ));
            self.player.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewMinXMargin
                    | NSAutoresizingMaskOptions::ViewMaxXMargin
                    | NSAutoresizingMaskOptions::ViewMaxYMargin,
            );
            self.position_controls();
            self.position_traffic_lights(&parent);
            // Keep time/progress aligned after player width changes
            let p_w = self.player.bounds().size.width;
            if p_w > 100.0 {
                // time left, progress centered, volume right
                self.player_time_label.setFrame(NSRect::new(NSPoint::new(74.0, 8.0), NSSize::new(80.0, 14.0)));
                self.player_progress_slider.setFrame(NSRect::new(NSPoint::new(160.0, 8.0), NSSize::new((p_w - 346.0).max(80.0), 14.0)));
                self.player_volume_slider.setFrame(NSRect::new(NSPoint::new(p_w - 118.0, 8.0), NSSize::new(70.0, 14.0)));
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

    pub fn update_player_state(&self, state: NativePlayerState) {
        if let Some(lyrics) = state.in_lyrics_mode {
            self.set_lyrics_mode(lyrics);
        }

        self.player_title.setStringValue(&NSString::from_str(&state.title));
        self.player_artist.setStringValue(&NSString::from_str(&state.artist));
        self.player_play_btn.setTitle(&NSString::from_str(if state.playing { "❚❚" } else { "▶" }));

        if let Some(progress) = state.progress {
            self.player_progress_slider.setDoubleValue(progress);
        }

        if let Some(volume) = state.volume {
            self.player_volume_slider.setDoubleValue(volume);
        }

        if let Some(ref cover_str) = state.cover {
            if !cover_str.trim().is_empty() {
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
            } else {
                self.player_cover.setImage(None);
            }
        } else {
            self.player_cover.setImage(None);
        }

        if let Some(liked) = state.liked {
            self.player_like_btn.setTitle(&NSString::from_str(if liked { "♥" } else { "♡" }));
        }

        if let Some(shuffle) = state.shuffle {
            self.player_shuffle_btn.setTitle(&NSString::from_str(if shuffle { "🔀" } else { "⇄" }));
        }

        if let Some(repeat_mode) = state.repeat {
            let sym = match repeat_mode.as_str() {
                "one" => "🔂",
                "all" => "🔁",
                _ => "↺",
            };
            self.player_repeat_btn.setTitle(&NSString::from_str(sym));
        }

        // Update time label — show elapsed / total like 1:34 / 2:50
        if state.elapsed.is_some() || state.total.is_some() {
            let elapsed = state.elapsed.as_deref().unwrap_or("0:00");
            let total = state.total.as_deref().unwrap_or("0:00");
            let combined = format!("{} / {}", elapsed, total);
            self.player_time_label.setStringValue(&NSString::from_str(&combined));
        }
    }
}
