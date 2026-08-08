// Native AppKit sidebar for the hybrid macOS shell.

use objc2::{define_class, msg_send, rc::Retained, runtime::AnyObject, MainThreadMarker, MainThreadOnly};
use objc2_app_kit::{
    NSAutoresizingMaskOptions, NSButton, NSGlassEffectView, NSGlassEffectViewStyle,
    NSFont, NSSearchField, NSTextAlignment, NSView, NSWindow,
};
use objc2_foundation::{ns_string, NSPoint, NSRect, NSSize, NSString};
use serde::Deserialize;
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

        #[unsafe(method(playerPrevious:))]
        fn player_previous(&self, _sender: &AnyObject) { emit_sidebar_action("player-previous", None); }
        #[unsafe(method(playerToggle:))]
        fn player_toggle(&self, _sender: &AnyObject) { emit_sidebar_action("player-toggle", None); }
        #[unsafe(method(playerNext:))]
        fn player_next(&self, _sender: &AnyObject) { emit_sidebar_action("player-next", None); }
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
    player_title: Retained<objc2_app_kit::NSTextField>,
    player_artist: Retained<objc2_app_kit::NSTextField>,
    _controller: Retained<NativeSidebarController>,
    is_attached: bool,
}

#[derive(Deserialize)]
pub struct NativePlayerState { pub title: String, pub artist: String, pub playing: bool }

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
        let player_title = objc2_app_kit::NSTextField::labelWithString(ns_string!("Not Playing"), mtm);
        let player_artist = objc2_app_kit::NSTextField::labelWithString(ns_string!("-"), mtm);

        Ok(Self {
            _window: window,
            webview,
            sidebar,
            player,
            player_title,
            player_artist,
            _controller: NativeSidebarController::new(mtm),
            is_attached: false,
        })
    }

    pub fn attach_to_window(&mut self) -> Result<(), String> {
        if self.is_attached {
            return Ok(());
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
        self.player_title.setFrame(NSRect::new(NSPoint::new(76.0, 44.0), NSSize::new(220.0, 20.0)));
        self.player_artist.setFrame(NSRect::new(NSPoint::new(76.0, 24.0), NSSize::new(220.0, 16.0)));
        content.addSubview(&self.player_title);
        content.addSubview(&self.player_artist);
        let controller = target(&self._controller);
        for (i, (title, action)) in [("◀", objc2::sel!(playerPrevious:)), ("▶", objc2::sel!(playerToggle:)), ("▶▶", objc2::sel!(playerNext:))].into_iter().enumerate() {
            let title = NSString::from_str(title);
            let button = unsafe { NSButton::buttonWithTitle_target_action(&title, Some(controller), Some(action), mtm) };
            button.setBordered(false);
            button.setFrame(NSRect::new(NSPoint::new(self.player.bounds().size.width - 190.0 + (i as f64 * 54.0), 24.0), NSSize::new(46.0, 34.0)));
            button.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMinYMargin);
            content.addSubview(&button);
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
        let sidebar_height = (bounds.size.height - (SIDEBAR_INSET * 2.0)).max(0.0);
        self.sidebar.setFrame(NSRect::new(
            NSPoint::new(SIDEBAR_INSET, SIDEBAR_INSET),
            NSSize::new(SIDEBAR_WIDTH - SIDEBAR_INSET, sidebar_height),
        ));
        self.sidebar.setAutoresizingMask(NSAutoresizingMaskOptions::ViewHeightSizable);

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
        self.player.setAutoresizingMask(NSAutoresizingMaskOptions::ViewMinXMargin | NSAutoresizingMaskOptions::ViewMaxXMargin | NSAutoresizingMaskOptions::ViewMaxYMargin);
        self.position_controls();
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
        self.player_title.setStringValue(&NSString::from_str(&state.title));
        self.player_artist.setStringValue(&NSString::from_str(&state.artist));
    }
}
