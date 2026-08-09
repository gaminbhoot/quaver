# Phase 1 — Architecture Audit & Migration Map

> Pure AppKit from day one. No WKWebView in the final architecture.
> `NSApplication → NSWindow (hidden title, real traffic lights) → AppKit UI → AVPlayer → Rust core (FFI)`

---

## 1. What exists today (WebView architecture to be removed)

### 1.1 Frontend (all HTML/CSS/JS UI — deleted in Phase 11)

| File | Lines | Role |
|------|-------|------|
| `src/index.html` | ~307 | `mac-window`, fake `window-titlebar` (`data-tauri-drag-region`), `sidebar`, `main-view` (8-step CSS blur header), `pane-tracks` table, `pane-albums` grid, `pane-artists` grid, `mini-player`, `queue-panel`, `fullscreen-overlay` (lyrics) |
| `src/main.js` | 1398 | ALL app state + rendering + `new Audio()` playback + lyrics sync + search/filter/sort + playlists + queue |
| `src/styles.css` | 1271 | Theme tokens + layout + every component style + CSS glass |
| `src/styles/glass.css` | 15 | `backdrop-filter: blur(45px)` fake glass |
| `src/styles/layout.css` | 15 | `.mac-window` flex scaffold |
| `src/styles/macos.css` | 23 | macOS tokens |
| `src/styles/typography.css` | 19 | `-apple-system` fonts |
| `src/audioUtils.js` | 72 | Pure: `formatTime`, `parseLRC`, `getNext/PrevTrackIndex` — portable to Swift, not deleted until ported |
| `src/lyricsEngine.js` | 76 | Pure: `getActiveLyricIndex`, `getLyricLineDuration`, `getWordProgresses`, `independentActiveLyric` — portable |
| `src/audioUtils.test.js` | 68 | `formatTime` / `parseLRC` / `getNext/PrevTrackIndex` |
| `src/lyrics-sync.test.js` | 363 | 12 suites: boundaries, seeks, rapid race, out-of-order, stale loads, mid-song open, word progress, track-change, rAF, listeners, property-based |
| `vitest.config.js` | ~20 | jsdom harness — replaced by XCTest / cargo test |

### 1.2 JavaScript state inventory (`src/main.js` — every owner that moves to native state)

```js
let playlist = []                         // Track[] — the library
let currentTrackIndex = -1
let isPlaying = false
let isShuffle = false
let repeatMode = 'off'                    // 'off' | 'all' | 'one'
let playbackQueue = []                    // number[] — queue order
let queueDragIndex = null
let lyrics = []                           // {time,text}[]
let activeLyricIndex = -1
let lastPlaybackErrorSource = ''
let songSearchQuery = ''
let libraryView = { type: 'all', value: null } // all|liked|recent|artists|albums|artist|album|playlist|now-playing
let librarySort = 'title'                 // title|artist|album|recent
let libraryFilter = 'all'                 // all|flac|lossless
let customPlaylists                       // ← localStorage quaver-playlists
let likedTrackKeys                        // ← localStorage quaver-liked-tracks (Set<string>)
let recentlyPlayed                        // ← localStorage quaver-recently-played
let lyricsManualScrollUntil = 0           // grace period ms
let lyricsDragState = null
let wasLyricsDragged = false
let lyricsScrollAnimationId = null
const audio = new Audio()                 // ← HTMLAudioElement — replaced by AVPlayer
const nextTrackPreloader = new Audio()    // preloader — replaced by AVQueuePlayer / pre-enqueue
let preloadedTrackIndex = -1
```

DOM handles (25+ `getElementById`) are not state — they are the view layer and are deleted with the HTML.

### 1.3 Persistence — schemas to migrate (do not silently drop)

**localStorage (JS):**

| Key | JSON shape | Default | Notes |
|-----|------------|---------|-------|
| `quaver-playlists` | `{id: string, name: string, trackKeys: string[]}[]` | `[]` | `id` via `crypto.randomUUID()` or `Date.now()` fallback |
| `quaver-liked-tracks` | `string[]` (array of `trackKey`) | `[]` | Stored as `Set` in memory, persisted as array |
| `quaver-recently-played` | `{key: string, playedAt: number}[]` | `[]` | Capped at 50, MRU-ordered; sorted desc by `playedAt` |
| `quaver-icon-style` | `"auto" | "default" | "dark" | "clear-dark" | "clear-light" | "tinted-dark" | "tinted-light"` | `"auto"` | Theme/icon variant selector |

**Rust file (`~/Library/Application Support/com.quaver.app/library.json`):**

```json
{ "music_folder": "/absolute/path/to/Music or /Volumes/..." }
```

**Identity:**

```js
function trackKey(track) {
  return String(track?.path || `${track?.title}|${track?.artist}|${track?.album}`);
}
```

Ports to Swift as `TrackMetadata.key`. This is the join key for playlists, liked, and recently-played. Must be preserved exactly.

### 1.4 Tauri IPC surface (to be deleted — no `invoke`/`listen` in pure AppKit)

| Kind | Name | Purpose |
|------|------|---------|
| `invoke` | `select_folder` | rfd folder picker → `save_music_folder` |
| `invoke` | `scan_directory` | WalkDir + lofty scan |
| `invoke` | `read_lyrics_file` | `fs::read_to_string` for `.lrc` |
| `invoke` | `get_saved_music_folder` | Read `library.json` |
| `invoke` | `set_app_icon_variant` | Icon theme (referenced in JS; verify before wiring) |
| `invoke` | `start_drag` | `window.start_dragging()` — replaced by AppKit titlebar drag |
| `invoke` | `sync_native_sidebar` | Reposition WebView/native frames — deleted |
| `invoke` | `update_native_player` | Mirror player state to `NativeGlassManager` — deleted (AppKit owns it directly) |
| `invoke` | `update_lyrics_mode` | Toggle lyrics mode — deleted |
| `invoke` | `toggle_native_volume` | Volume popover — deleted |
| `listen` | `native-sidebar-ready` | Gate `html.native-sidebar-active` — deleted |
| `listen` | `trigger-add-folder` | Menu → JS — replaced by NSMenu action |
| `listen` | `native-sidebar-action` | 13 actions (`all/liked/recent/now-playing/artists/albums/add-folder/search/player-*`) — replaced by target/action |
| helper | `convertFileSrc` | `assetProtocol` file URL helper for `audio.src` — replaced by `AVURLAsset(fileURL:)` |
| event | `window.resize` / `fullscreenchange` → `sync_native_sidebar` | WebView frame sync — deleted |

### 1.5 Rust backend — what stays vs what goes

**Keep (pure core, no Tauri):** `TrackMetadata`, `LibraryConfig`, `find_folder_cover`, `scan_directory`, `read_lyrics_file`, `save/get_music_folder`, `walkdir`, `lofty`, `base64`, `rfd` (or replace with `NSOpenPanel` on Swift side).

**Delete:** `#[tauri::command]`, `tauri::AppHandle`, `tauri::Emitter/Manager`, `tauri::Wry`, `tauri::menu`, `build_menu`, `with_webview`, `ns_window`/`wk_webview_ptr`, `start_drag`, `sync_native_sidebar`, `update_native_player`, `update_lyrics_mode`, `toggle_native_volume`, `tauri-plugin-*`, `objc2*` (replaced by Swift AppKit), `tauri-build`.

Extracted to `quaver-core` (`quaver-core/src/lib.rs`) — `cargo check` passes. C FFI in `App/Sources/Quaver/Bridge/QuaverCoreFFI.h`.

### 1.6 CSS / WebView chrome to delete

`backdrop-filter` / `-webkit-backdrop-filter` (`glass.css` + `styles.css` 8-step `blur-step-*`), `native-sidebar-active` gating, fake `window-titlebar` + `titlebar-blur-backdrop`, `data-tauri-drag-region`, `html.native-sidebar-active .sidebar/.mini-player` hiding rules, `PassthroughGlassOverlay` / `update_glass_geometry` / `sync_glass_container` (if present), all `frontendDist` / `withGlobalTauri` / `hiddenTitle` / `titleBarStyle: Overlay` tauri.conf.

---

## 2. Format capability spike (macOS 26.6, AVFoundation)

Probe: `UTType(filenameExtension:)` + `AVURLAsset.audiovisualTypes()` on this machine.

| Ext | UTI | `conforms(to: .audio)` | AVFoundation decode | Action |
|-----|-----|------------------------|---------------------|--------|
| `mp3` | `public.mp3` | ✅ | Native | AVPlayer |
| `aac` | `public.aac-audio` | ✅ | Native | AVPlayer |
| `m4a` | `com.apple.m4a-audio` | ✅ | Native | AVPlayer |
| `alac` | `dyn.*` | ❌ (dyn) | Native inside `m4a` container | AVPlayer (container is `m4a`) |
| `wav` | `com.microsoft.waveform-audio` | ✅ | Native | AVPlayer |
| `aiff`/`aif` | `public.aiff-audio` | ✅ | Native | AVPlayer |
| `flac` | `org.xiph.flac` | ✅ | ✅ on macOS 14+ (Tahoe/26 still has it) — verify with real file in Phase 3 | AVPlayer; fallback if probe fails |
| `ogg` | `org.xiph.ogg-audio` | ✅ | ❌ | Fallback decoder (Vorbis) |
| `opus` | `org.xiph.ogg-audio` (same UTI) | ✅ | ❌ | Fallback decoder (Opus) |
| `wma` | `com.microsoft.windows-media-wma` | ✅ | ❌ | Fallback decoder or transcode-on-import |
| `ape` | `dyn.*` | ❌ | ❌ | Fallback decoder |
| `ac3` | `public.ac3-audio` | ✅ | Partial (passthrough) | Fallback or AVAudioEngine with AC3 parser |
| `mka` | `dyn.*` | ❌ | ❌ | Fallback (Matroska container) |

`audiovisualTypes` count: 104 — many are video. Audio-only allowlist above is the contract.

**Decision for Phase 3:** AVPlayer is the default engine for the native set (`mp3/aac/m4a/wav/aiff/flac`). For the fallback set (`ogg/opus/wma/ape/ac3/mka`), the smallest reliable native solution is **Symphonia** (Rust, already close to `lofty`'s decoder family) → PCM → `AVAudioEngine`/`AVAudioPlayerNode`. Document the choice in Phase 3 and add one fixture file per fallback format to CI. Do not silently skip tracks; do not silently transcode the user's library.

`alac` note: the raw `alac` extension probe is `dyn` (no registered UTI), but ALAC inside `m4a` is fully supported — the scanner's `m4a` branch covers it. No separate handling needed unless a user has bare `.alac` files.

---

## 3. Pure AppKit bootstrap (verified Phase 1)

**Target architecture (final):**

```
NSApplication
  → QuaverWindow (NSWindow, styleMask: fullSizeContentView, titleVisibility: .hidden,
                  titlebarAppearsTransparent: true, real traffic lights)
    → AppKit UI (sidebar, library, mini-player, full player, lyrics — Swift)
      → PlaybackEngine (AVPlayer, single clock: AVPlayer.currentTime() + AVPlayerItem.duration)
        → Rust core via C FFI (quaver-core staticlib, JSON boundary)
          → lofty / walkdir / base64 (no Tauri)
```

**Verification in this phase:**

- `App/Sources/Quaver/App/AppDelegate.swift` — `@main NSApplicationDelegate`, creates `QuaverWindowController`, `activate(ignoringOtherApps:)`; `applicationShouldTerminateAfterLastWindowClosed`.
- `App/Sources/Quaver/Window/QuaverWindow.swift` — `NSWindow` with `fullSizeContentView`, hidden title, transparent titlebar, `minSize 800×500`, placeholder `contentView`. No `WKWebView` import; `assert` guards.
- `App/Sources/Quaver/Window/QuaverWindowController.swift` — `NSWindowController` convenience init + `makeKeyAndOrderFront`.
- `swiftc` build: `swiftc -target arm64-apple-macosx15.0 -sdk ... -framework AppKit -framework AVFoundation App/... -o /tmp/quaver_bootstrap_check` ✅
- Link check: `otool -L` shows `AppKit`, `AVFoundation`, `Combine`, `Foundation` only. `nm | grep WKWebView|WebKit|Tauri` → 0 symbols. ✅
- `NSWindow` API probe: `titleVisibility=.hidden` + `titlebarAppearsTransparent` + `fullSizeContentView` compile and run. ✅
- `AVPlayer` probe: `AVPlayer()` + `rate/volume/currentTime` + `AVPlayerItemDidPlayToEndTime` notification center exist. ✅
- `quaver-core` crate: `cargo check` ✅ (`serde`, `serde_json`, `lofty`, `base64`, `walkdir` only).

No Tauri. No WebView. No HTML.

---

## 4. Swift ↔ Rust boundary (small, explicit, strongly typed)

```
Swift                          C FFI (QuaverCoreFFI.h)              Rust (quaver-core)
─────────────────              ─────────────────────────              ──────────────────
QuaverCore.scanDirectory  →    quaver_scan_directory_json      →    scan_directory() → JSON Vec<TrackMetadata>
QuaverCore.readLyricsFile →    quaver_read_lyrics_file         →    read_lyrics_file()
QuaverCore.savedMusicFolder →  quaver_get_saved_music_folder   →    get_saved_music_folder()
QuaverCore.saveMusicFolder→    quaver_save_music_folder        →    save_music_folder()
                           ←  quaver_free_string              ←    CString::from_raw
QuaverCore.pickMusicFolder     NSOpenPanel (pure Swift, no Rust)
```

JSON boundary: `TrackMetadata` `Codable` on Swift, `Serialize/Deserialize` on Rust — same keys (`cover_data_url`, `lyric_path`). No binary protocol. Caller frees returned `*mut c_char` with `quaver_free_string`.

File picker: `NSOpenPanel` in Swift replaces `rfd` + `select_folder` Tauri command. `rfd` is removed; folder persistence goes through `quaver_save_music_folder` which writes `~/Library/Application Support/com.quaver.app/library.json` directly (no `tauri::AppHandle`).

---

## 5. Migration map (WebView → native)

| WebView owner | Native owner | Phase |
|---------------|--------------|-------|
| `HTMLAudioElement` (`new Audio()`, `timeupdate`, `loadedmetadata`, `currentTime/duration/volume/ended`) | `AVPlayer` + `AVPlayerItem` + `periodicTimeObserver` (single clock) | 3 |
| `audio.preload` / `nextTrackPreloader` | `AVQueuePlayer` or pre-enqueued `AVPlayerItem` | 3 |
| `playlist: Track[]` + `TrackMetadata` mapping | `LibraryModel.tracks: [TrackMetadata]` (Swift) backed by `quaver-core::scan_directory` | 2 |
| `localStorage quaver-*` + `library.json` | `UserDefaults` / `Application Support` JSON + migration reader on first native launch | 2 |
| `trackKey` (`path || title\|artist\|album`) | `TrackMetadata.key` (Swift extension) | 2 |
| Sidebar HTML + `song-search-input` + filter/sort selects | `NSVisualEffectView` sidebar + `NSSearchField` + `NSPopUpButton` | 5 |
| `pane-tracks` `<table>` + `renderPlaylist` | `NSTableView` in `NSScrollView` + `NSCache` artwork | 6 |
| `pane-albums` / `pane-artists` grids + `renderBrowseGroups` | `NSCollectionView` (compositional layout, album + artist cells) | 6 |
| `mini-player` bar | `NSVisualEffectView` pill + `NSImageView` + `NSTextField` + SF Symbols + `NSSlider` | 7 |
| `progress-bar` / `volume-bar` drag + keyboard seek | `NSSlider` target/action + `keyDown` | 3/7 |
| `fullscreen-overlay` + `syncLyrics`/`smoothlyCenterLyric` | Native lyrics scroll view observing `PlaybackEngine.currentTime` | 9 |
| `queue-panel` + `ensureQueue` + drag reorder | `NSPopover` + `NSTableView` drag reordering | 7 |
| Fake titlebar + `start_drag` / `data-tauri-drag-region` | Real `NSWindow` titlebar + `isMovableByWindowBackground` | 4 |
| CSS `backdrop-filter` glass + 8-step header blur | `NSVisualEffectView` / `NSGlassEffectView` materials (`sidebar`, `HUDWindow`) | 10 |
| `navigator.mediaSession` + `setPositionState` | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` | 3 |
| `matchMedia(prefers-color-scheme)` + `updateAppIconStyle` | `NSAppearance` / `effectiveAppearance` KVO | 10 |
| `window.resize/fullscreenchange` → `sync_native_sidebar` | Auto Layout / `NSWindowDelegate` | 4 |

---

## 6. What is NOT torn out in Phase 1

- `src/` (HTML/CSS/JS) stays on disk and remains the shippable Tauri app until Phase 11 deletes it. No user-facing regression in Phase 1.
- `src-tauri/` stays buildable (`cargo check` still passes on the Tauri crate). `quaver-core` is additive, not a replacement yet.
- Tests (`vitest`) stay green — native XCTest ports land in later phases, not now.

---

## 7. Phase 1 exit criteria (all must be true before Phase 2)

- [x] Audit of every JS state var, `localStorage` key, `invoke`/`listen`, Rust command, CSS glass site, and HTML view.
- [x] Format matrix probed on this macOS (UTI + `audiovisualTypes`) with native vs fallback split documented.
- [x] Pure AppKit window boots with hidden title + real traffic lights + no WebView (swiftc + otool + nm verified).
- [x] `quaver-core` crate extracts the Tauri-free scanning/metadata core (`cargo check` passes, no `tauri` dep).
- [x] Swift ↔ Rust FFI boundary defined (`QuaverCoreFFI.h` + `QuaverCore.swift` `Codable` shape + `TrackMetadata.key`).
- [x] `PlaybackEngine` protocol + `LyricSynchronizer` pure logic (1:1 with `lyricsEngine.js`) compile.
- [ ] `docs/MIGRATION.md` for `localStorage → native` schema migration (deferred to Phase 2 — schemas captured above, migration impl is Phase 2).
- [ ] No WebView code deleted — intentionally. Deletion is Phase 11, not Phase 1.

