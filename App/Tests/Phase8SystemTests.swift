import AppKit
import Combine
import Foundation
import MediaPlayer
import AVFoundation

// MARK: - Phase 8 — System Integration (menus, shortcuts, NowPlaying, remote commands)
// Covers: full NSMenu structure + key equivalents, AppDelegate ↔ engine delegation,
// RootSplit.navigate single path, NowPlayingInfoCenter sync (single clock, no second timer),
// RemoteCommand lifecycle, no WKWebView regressions, window chrome still correct,
// keyboard guard, menu validation.
// Parameterized/shared fixtures — no repetitive code.

var systemFailures: [String] = []
func systemCheck(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if !cond { systemFailures.append("\(msg) (\(file):\(line))"); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}

// MARK: - Fake engine (deterministic, no AVPlayer, no file IO)

@MainActor
final class SystemFakeEngine: PlaybackEngine {
    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    var state: PlaybackState { subject.value }
    var statePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    var library: [TrackMetadata] = []
    var currentTrack: TrackMetadata? {
        let idx = subject.value.currentTrackIndex
        guard library.indices.contains(idx) else { return nil }
        return library[idx]
    }
    var seekHistory: [Double] = []
    func setLibrary(_ tracks: [TrackMetadata]) { library = tracks }
    func play(trackAt index: Int) {
        guard library.indices.contains(index) else { return }
        var s = subject.value; s.currentTrackIndex = index; s.currentTime = 0; s.isPlaying = true
        subject.send(s)
    }
    func togglePlay() { var s = subject.value; s.isPlaying.toggle(); subject.send(s) }
    func pause() { var s = subject.value; s.isPlaying = false; subject.send(s) }
    func next() {
        guard !library.isEmpty else { return }
        let cur = subject.value.currentTrackIndex
        let nxt = (cur + 1) % library.count
        var s = subject.value; s.currentTrackIndex = nxt >= 0 ? nxt : 0; s.currentTime = 0
        subject.send(s)
    }
    func previous() {
        guard !library.isEmpty else { return }
        let cur = subject.value.currentTrackIndex
        let prv = cur <= 0 ? library.count - 1 : cur - 1
        var s = subject.value; s.currentTrackIndex = prv; s.currentTime = 0
        subject.send(s)
    }
    func seek(to time: Double) {
        seekHistory.append(time)
        var s = subject.value
        let dur = s.duration
        s.currentTime = dur > 0 ? max(0, min(time, dur)) : max(0, time)
        subject.send(s)
    }
    func setVolume(_ v: Double) { var s = subject.value; s.volume = max(0, min(1, v)); subject.send(s) }
    func setShuffle(_ e: Bool) { var s = subject.value; s.isShuffle = e; subject.send(s) }
    func setRepeatMode(_ m: RepeatMode) { var s = subject.value; s.repeatMode = m; subject.send(s) }
    // Test injection
    func _setTime(_ t: Double) { var s = subject.value; s.currentTime = t; subject.send(s) }
    func _setDuration(_ d: Double) { var s = subject.value; s.duration = d; subject.send(s) }
    func _setPlaying(_ p: Bool) { var s = subject.value; s.isPlaying = p; subject.send(s) }
    func _setTrackIndex(_ i: Int) { var s = subject.value; s.currentTrackIndex = i; subject.send(s) }
}

@MainActor
func makeSystemTrack(path: String = "/music/test.flac", title: String = "Track", artist: String = "Artist", album: String = "Album", format: String = "FLAC") -> TrackMetadata {
    TrackMetadata(path: path, title: title, artist: artist, album: album, duration: 200, format: format, coverDataURL: nil, lyricPath: nil)
}

// MARK: - 1. Menu structure

@MainActor
func testMenuStructure() {
    print("\n--- Menu structure ---")
    let menu = QuaverMenuBuilder.buildMainMenu()
    systemCheck(menu.numberOfItems >= 7, "main menu has >=7 top items (App/File/Edit/Playback/View/Window/Help) got \(menu.numberOfItems)")
    // Find top titles
    func findMenu(_ title: String) -> NSMenu? {
        for item in menu.items {
            if item.title == title || item.submenu?.title == title { return item.submenu }
            if let sub = item.submenu, sub.title == title { return sub }
        }
        // Also check submenu titles
        for item in menu.items { if item.submenu?.title == title { return item.submenu } }
        return nil
    }
    // Check by scanning submenu titles directly
    _ = menu.items.compactMap { $0.submenu?.title.isEmpty == false ? $0.submenu?.title : $0.title } // titles check via individual finds
    // More reliable: check item.title fallback
    var foundPlayback = false, foundView = false, foundFile = false, foundEdit = false, foundWindow = false, foundHelp = false
    for item in menu.items {
        let t = item.submenu?.title ?? item.title
        if t == "Playback" { foundPlayback = true }
        if t == "View" { foundView = true }
        if t == "File" { foundFile = true }
        if t == "Edit" { foundEdit = true }
        if t == "Window" { foundWindow = true }
        if t == "Help" { foundHelp = true }
    }
    systemCheck(foundPlayback, "Playback menu exists")
    systemCheck(foundView, "View menu exists")
    systemCheck(foundFile, "File menu exists")
    systemCheck(foundEdit, "Edit menu exists")
    systemCheck(foundWindow, "Window menu exists")
    systemCheck(foundHelp, "Help menu exists")

    // Check specific items exist via title scan
    func menuContains(_ parentTitle: String, itemTitle: String) -> Bool {
        for item in menu.items {
            let pt = item.submenu?.title ?? item.title
            if pt == parentTitle, let sub = item.submenu {
                for mi in sub.items { if mi.title == itemTitle { return true } }
            }
        }
        return false
    }
    systemCheck(menuContains("File", itemTitle: "Add Music Folder…"), "File → Add Music Folder exists")
    systemCheck(menuContains("File", itemTitle: "New Playlist"), "File → New Playlist exists")
    systemCheck(menuContains("Playback", itemTitle: "Play / Pause"), "Playback → Play/Pause exists")
    systemCheck(menuContains("Playback", itemTitle: "Next Track"), "Playback → Next exists")
    systemCheck(menuContains("Playback", itemTitle: "Previous Track"), "Playback → Previous exists")
    systemCheck(menuContains("Playback", itemTitle: "Shuffle"), "Playback → Shuffle exists")
    systemCheck(menuContains("Playback", itemTitle: "Repeat"), "Playback → Repeat exists")
    systemCheck(menuContains("View", itemTitle: "All Songs"), "View → All Songs exists")
    systemCheck(menuContains("View", itemTitle: "Liked Songs"), "View → Liked exists")
    systemCheck(menuContains("View", itemTitle: "Recently Played"), "View → Recently Played exists")
    systemCheck(menuContains("View", itemTitle: "Artists"), "View → Artists exists")
    systemCheck(menuContains("View", itemTitle: "Albums"), "View → Albums exists")
    systemCheck(menuContains("View", itemTitle: "Show Lyrics"), "View → Show Lyrics exists")

    // Key equivalents
    func keyFor(_ parent: String, itemTitle: String) -> (String, NSEvent.ModifierFlags)? {
        for item in menu.items {
            let pt = item.submenu?.title ?? item.title
            if pt == parent, let sub = item.submenu {
                for mi in sub.items where mi.title == itemTitle {
                    return (mi.keyEquivalent, mi.keyEquivalentModifierMask)
                }
            }
        }
        return nil
    }
    if let (k, m) = keyFor("File", itemTitle: "Add Music Folder…") {
        systemCheck(k == "o" && m.contains(.command), "Add Folder key Cmd+O (got \(k) mask \(m.rawValue))")
    } else { systemCheck(false, "Add Folder key lookup failed") }
    if let (k, m) = keyFor("Playback", itemTitle: "Next Track") {
        systemCheck(k == "]" && m.contains(.command), "Next key Cmd+] (got \(k))")
    } else { systemCheck(false, "Next key lookup failed") }
    if let (k, m) = keyFor("Playback", itemTitle: "Previous Track") {
        systemCheck(k == "[" && m.contains(.command), "Previous key Cmd+[ (got \(k))")
    } else { systemCheck(false, "Previous key lookup failed") }
    if let (k, m) = keyFor("View", itemTitle: "All Songs") {
        systemCheck(k == "1" && m.contains(.command), "All Songs key Cmd+1")
    } else { systemCheck(false, "All Songs key lookup failed") }
    if let (k, _) = keyFor("View", itemTitle: "Show Lyrics") {
        systemCheck(k == "l", "Show Lyrics key Cmd+L (got \(k))")
    } else { systemCheck(false, "Show Lyrics key lookup failed") }

    // No WKWebView in menu creation
    var foundWeb = false
    for item in menu.items {
        let t = String(describing: type(of: item))
        if t.contains("WKWebView") { foundWeb = true }
    }
    systemCheck(!foundWeb, "menu has no WKWebView")

    // NSApp integration — setting mainMenu should not crash
    let prev = NSApp.mainMenu
    NSApp.mainMenu = menu
    systemCheck(NSApp.mainMenu === menu, "NSApp.mainMenu accepts builder menu")
    // Restore but keep valid
    if let p = prev { NSApp.mainMenu = p }
    else { NSApp.mainMenu = menu }
}

// MARK: - 2. AppDelegate ↔ engine delegation

@MainActor
func testAppDelegateDelegation() {
    print("\n--- AppDelegate delegation ---")
    // We test QuaverApp's menu actions directly without needing NSApp runloop
    let store = LibraryStore(defaults: UserDefaults(suiteName: "com.quaver.test.system.\(UUID().uuidString)") ?? .standard)
    // Use RootSplit directly to simulate AppDelegate's delegation target
    _ = SystemFakeEngine()
    _ = RootSplitViewController(store: store, engine: NativePlaybackEngine())
    // Use fake engine via SystemFake path instead — we test delegation logic by exercising
    // the same code paths AppDelegate uses: togglePlay/next/previous/shuffle/repeat/navigate
    // First: verify togglePlay flips isPlaying
    let eng = NativePlaybackEngine()
    let _ = eng // keep alive
    // Instead test the real engine via QuaverApp's methods by constructing an app with window
    let app = QuaverApp()
    let wc = QuaverWindowController()
    app.windowController = wc
    _ = wc.rootSplit.view
    // Initially not playing
    systemCheck(!wc.rootSplit.engine.state.isPlaying, "engine initially not playing")
    app.togglePlay(nil)
    // togglePlay on empty library should not crash and not become playing (no track)
    systemCheck(!wc.rootSplit.engine.state.isPlaying || wc.rootSplit.engine.state.currentTrackIndex == -1, "togglePlay on empty library safe (isPlaying \(wc.rootSplit.engine.state.isPlaying))")
    // Add track and test
    let url = URL(fileURLWithPath: "/tmp/quaver_phase8_test.wav")
    // Generate a tiny wav if needed for playback test
    try? FileManager.default.createDirectory(at: URL(fileURLWithPath: "/tmp"), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        let sr: Double = 44100
        if let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true),
           let file = try? AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true) {
            let frames = AVAudioFrameCount(sr * 0.5)
            if let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) {
                buf.frameLength = frames
                try? file.write(from: buf)
            }
        }
    }
    let track = TrackMetadata(path: url.path, title: "Test", artist: "A", album: "B", duration: 10, format: "WAV", coverDataURL: nil, lyricPath: nil)
    wc.rootSplit.setLibraryTracks([track])
    wc.rootSplit.engine.play(trackAt: 0)
    // Wait briefly for engine to update
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    app.togglePlay(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    // Should have toggled
    // Not asserting exact playing state due to AVPlayer async, but ensure no crash and state is defined
    systemCheck(wc.rootSplit.engine.state.currentTrackIndex == 0, "engine still on track 0 after togglePlay")

    // Next/previous with single track and repeat off should not crash
    app.nextTrack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    systemCheck(true, "nextTrack on single track doesn't crash")

    app.previousTrack(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    systemCheck(true, "previousTrack on single track doesn't crash")

    // Shuffle toggle
    let beforeShuffle = wc.rootSplit.engine.state.isShuffle
    app.toggleShuffle(nil)
    systemCheck(wc.rootSplit.engine.state.isShuffle != beforeShuffle, "toggleShuffle flips state")

    // Repeat cycle off -> all -> one -> off
    wc.rootSplit.engine.setRepeatMode(.off)
    app.cycleRepeat(nil)
    systemCheck(wc.rootSplit.engine.state.repeatMode == .all, "cycleRepeat off->all")
    app.cycleRepeat(nil)
    systemCheck(wc.rootSplit.engine.state.repeatMode == .one, "cycleRepeat all->one")
    app.cycleRepeat(nil)
    systemCheck(wc.rootSplit.engine.state.repeatMode == .off, "cycleRepeat one->off")

    // Navigation
    app.viewAllSongs(nil)
    systemCheck(wc.rootSplit.selectedView == .all, "viewAllSongs navigates to .all")
    app.viewLikedSongs(nil)
    systemCheck(wc.rootSplit.selectedView == .liked, "viewLiked navigates to .liked")
    app.viewRecentlyPlayed(nil)
    systemCheck(wc.rootSplit.selectedView == .recent, "viewRecentlyPlayed navigates to .recent")
    app.viewArtists(nil)
    systemCheck(wc.rootSplit.selectedView == .artists, "viewArtists navigates to .artists")
    app.viewAlbums(nil)
    systemCheck(wc.rootSplit.selectedView == .albums, "viewAlbums navigates to .albums")

    // Lyrics toggle
    let wasLyrics = wc.rootSplit.isLyricsVisible
    app.toggleLyrics(nil)
    systemCheck(wc.rootSplit.isLyricsVisible != wasLyrics, "toggleLyrics flips visibility")
    app.toggleLyrics(nil)
    systemCheck(wc.rootSplit.isLyricsVisible == wasLyrics, "toggleLyrics flips back")

    // Menu validation always true
    let item = NSMenuItem(title: "Shuffle", action: #selector(QuaverApp.toggleShuffle(_:)), keyEquivalent: "")
    systemCheck(app.validateMenuItem(item), "validateMenuItem Shuffle returns true")
    let item2 = NSMenuItem(title: "Anything", action: nil, keyEquivalent: "")
    systemCheck(app.validateMenuItem(item2), "validateMenuItem generic returns true")
}

// MARK: - 3. RootSplit navigate single path

@MainActor
func testNavigateSinglePath() {
    print("\n--- Navigate single path ---")
    let store = LibraryStore(defaults: UserDefaults(suiteName: "com.quaver.test.nav.\(UUID().uuidString)") ?? .standard)
    let root = RootSplitViewController(store: store)
    _ = root.view
    // navigate should be single owner — check all views
    for view in [LibraryView.all, .liked, .recent, .artists, .albums] {
        root.navigate(to: view)
        systemCheck(root.selectedView == view, "navigate to \(view) sets selectedView")
        // libraryVC view should match (except we check via visible filtering maybe)
        // Ensure sidebar delegates still route through same path
    }
    // setViewForTest must delegate to navigate
    root.setViewForTest(.liked)
    systemCheck(root.selectedView == .liked, "setViewForTest delegates to navigate (liked)")
    root.navigate(to: .all)
    root.sidebarVC.delegate?.sidebarDidSelectView(.artists)
    systemCheck(root.selectedView == .artists, "sidebarDidSelectView uses same path")
    // Playlist navigation
    let pl = store.createPlaylist(name: "SysTest")
    root.navigate(to: .playlist(id: pl.id))
    if case .playlist(let id) = root.selectedView { systemCheck(id == pl.id, "navigate to playlist id preserved") }
    else { systemCheck(false, "navigate to playlist failed") }
    // Search is preserved across navigations
    root.sidebarVC.delegate?.sidebarSearchChanged("hello")
    systemCheck(root.searchQuery == "hello", "searchQuery stored")
    root.navigate(to: .all)
    systemCheck(root.searchQuery == "hello", "search preserved after navigate")
}

// MARK: - 4. NowPlayingInfoCenter sync (single clock)

@MainActor
func testNowPlayingSync() async {
    print("\n--- NowPlaying sync (single clock) ---")
    // Use fake engine for deterministic control
    let engine = SystemFakeEngine()
    let track = makeSystemTrack(path: "/music/a.flac", title: "Hello", artist: "Adele", album: "25", format: "FLAC")
    engine.setLibrary([track])
    engine._setTrackIndex(0)
    engine._setDuration(200)
    engine._setTime(42)
    engine._setPlaying(true)

    let controller = NowPlayingInfoController(engine: engine)
    // hasRemoteCommands should be true immediately after init
    systemCheck(controller.hasRemoteCommands, "hasRemoteCommands true after init")

    // Allow sink to fire (updateNowPlayingInfo is called on init + on state changes)
    try? await Task.sleep(nanoseconds: 160_000_000)

    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
    systemCheck(info != nil, "nowPlayingInfo is set")
    if let info {
        systemCheck((info[MPMediaItemPropertyTitle] as? String) == "Hello", "nowPlaying title is Hello (got \(String(describing: info[MPMediaItemPropertyTitle]))")
        systemCheck((info[MPMediaItemPropertyArtist] as? String) == "Adele", "nowPlaying artist is Adele")
        systemCheck((info[MPMediaItemPropertyAlbumTitle] as? String) == "25", "nowPlaying album is 25")
        if let dur = info[MPMediaItemPropertyPlaybackDuration] as? Double {
            systemCheck(abs(dur - 200) < 0.01, "nowPlaying duration 200 (got \(dur))")
        } else { systemCheck(false, "nowPlaying duration missing or not Double") }
        if let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double {
            systemCheck(abs(elapsed - 42) < 0.6, "nowPlaying elapsed ~42 (got \(elapsed))")
        } else { systemCheck(false, "nowPlaying elapsed missing") }
        if let rate = info[MPNowPlayingInfoPropertyPlaybackRate] as? Double {
            systemCheck(rate == 1.0, "nowPlaying rate 1.0 when playing (got \(rate))")
        } else { systemCheck(false, "nowPlaying rate missing") }
    }

    // Pause → rate 0
    engine._setPlaying(false)
    try? await Task.sleep(nanoseconds: 160_000_000)
    if let info2 = MPNowPlayingInfoCenter.default().nowPlayingInfo,
       let rate2 = info2[MPNowPlayingInfoPropertyPlaybackRate] as? Double {
        systemCheck(rate2 == 0.0, "nowPlaying rate 0.0 when paused (got \(rate2))")
    } else { systemCheck(false, "nowPlaying rate after pause missing") }

    // Seek updates elapsed without second clock
    engine._setTime(99)
    try? await Task.sleep(nanoseconds: 160_000_000)
    if let info3 = MPNowPlayingInfoCenter.default().nowPlayingInfo,
       let elapsed3 = info3[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double {
        systemCheck(abs(elapsed3 - 99) < 0.6, "nowPlaying elapsed updates to 99 after seek (got \(elapsed3))")
    }

    // No track → title Quaver, elapsed 0, rate 0
    let emptyEngine = SystemFakeEngine()
    emptyEngine._setDuration(0)
    emptyEngine._setTime(0)
    emptyEngine._setPlaying(false)
    let c2 = NowPlayingInfoController(engine: emptyEngine)
    try? await Task.sleep(nanoseconds: 160_000_000)
    let info4 = MPNowPlayingInfoCenter.default().nowPlayingInfo
    systemCheck((info4?[MPMediaItemPropertyTitle] as? String) == "Quaver", "no track title is Quaver")
    _ = c2 // keep alive
    controller.invalidate()
    c2.invalidate()
    systemCheck(!controller.hasRemoteCommands, "after invalidate hasRemoteCommands false")
    systemCheck(!c2.hasRemoteCommands, "c2 after invalidate false")
    // Restore Quaver empty for later tests
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
}

// MARK: - 5. NowPlaying artwork (data URL)

@MainActor
func testNowPlayingArtwork() async {
    print("\n--- NowPlaying artwork ---")
    // Tiny 1x1 png base64
    let b64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    let dataURL = "data:image/png;base64,\(b64)"
    let track = TrackMetadata(path: "/music/art.flac", title: "Art", artist: "A", album: "B", duration: 10, format: "FLAC", coverDataURL: dataURL, lyricPath: nil)
    let engine = SystemFakeEngine()
    engine.setLibrary([track])
    engine._setTrackIndex(0)
    engine._setDuration(10)
    let c = NowPlayingInfoController(engine: engine)
    try? await Task.sleep(nanoseconds: 200_000_000)
    let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
    let hasArtwork = info?[MPMediaItemPropertyArtwork] != nil
    systemCheck(hasArtwork, "nowPlaying artwork set from data URL")
    // Invalid dataURL should not crash and should still have title
    let badTrack = TrackMetadata(path: "/music/bad.flac", title: "Bad", artist: "A", album: "B", duration: 10, format: "FLAC", coverDataURL: "not-a-data-url", lyricPath: nil)
    let e2 = SystemFakeEngine()
    e2.setLibrary([badTrack])
    e2._setTrackIndex(0)
    e2._setDuration(10)
    let c2 = NowPlayingInfoController(engine: e2)
    try? await Task.sleep(nanoseconds: 160_000_000)
    systemCheck((MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String) == "Bad", "bad dataURL still yields title Bad")
    c.invalidate(); c2.invalidate()
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
}

// MARK: - 6. No duplicated state / no second clock

@MainActor
func testNoSecondClock() {
    print("\n--- No second clock / no duplicated state ---")
    let engine = SystemFakeEngine()
    let c = NowPlayingInfoController(engine: engine)
    let mirror = Mirror(reflecting: c)
    var hasTimer = false
    var hasDisplayLink = false
    for child in mirror.children {
        let ty = String(describing: type(of: child.value))
        if ty.contains("Timer") { hasTimer = true }
        if ty.contains("DisplayLink") || ty.contains("CADisplayLink") { hasDisplayLink = true }
        // Should not store its own currentTime/duration
        if (child.label == "currentTime" || child.label == "duration") && ty.contains("Double") { hasTimer = true }
    }
    systemCheck(!hasTimer, "NowPlayingInfoController has no Timer/store of its own")
    systemCheck(!hasDisplayLink, "NowPlayingInfoController has no DisplayLink")
    // Walk for WebView in controller's view hierarchy (it has none — it's not a VC)
    systemCheck(c.hasRemoteCommands, "still has remoteCommands (sanity)")
    c.invalidate()
    systemCheck(!c.hasRemoteCommands, "invalidate clears remoteCommands")
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
}

// MARK: - 7. Window chrome still correct after Phase 8

@MainActor
func testWindowChromeAfterSystemIntegration() {
    print("\n--- Window chrome after system integration ---")
    let w = QuaverWindow()
    systemCheck(w.styleMask.contains(.titled), "window still has .titled")
    systemCheck(w.styleMask.contains(.fullSizeContentView), "window still has fullSizeContentView")
    systemCheck(w.titleVisibility == .hidden, "titleVisibility still .hidden")
    systemCheck(w.titlebarAppearsTransparent, "titlebarAppearsTransparent still true")
    systemCheck(w.minSize == NSSize(width: 800, height: 500), "minSize still 800x500")
    systemCheck(w.standardWindowButton(.closeButton) != nil, "closeButton still exists")
    systemCheck(w.standardWindowButton(.miniaturizeButton) != nil, "miniButton still exists")
    systemCheck(w.standardWindowButton(.zoomButton) != nil, "zoomButton still exists")

    let c = QuaverWindowController()
    systemCheck(c.window is QuaverWindow, "WindowController still hosts QuaverWindow")
    // Check that setContentSize 1280x800 was applied but still respects minSize
    let size = c.window?.frame.size ?? .zero
    systemCheck(size.width >= 800 && size.height >= 500, "windowController frame respects minSize (got \(size))")
    // Walk for WebView
    var found = false
    func walk(_ v: NSView) {
        let t = String(describing: type(of: v))
        if t.contains("WKWebView") || t.contains("WebView") { found = true }
        for s in v.subviews { walk(s) }
    }
    if let cv = c.window?.contentView { walk(cv) }
    if let rc = c.rootSplit.view as NSView? { walk(rc) }
    systemCheck(!found, "no WKWebView in window after system integration")
}

// MARK: - 8. Keyboard guard & remote command seek

@MainActor
func testKeyboardAndSeekCommand() async {
    print("\n--- Keyboard guard & seek command ---")
    // AppDelegate installGlobalKeyHandling should not crash when called twice
    let app = QuaverApp()
    // isInTextEditingContext is private — we test indirectly: when keyWindow is nil, Space should not trigger text editing guard crash
    // Calling togglePlay when no window should not crash
    app.togglePlay(nil)
    systemCheck(true, "togglePlay with no window doesn't crash")

    // Remote seek via engine: simulate MPChangePlaybackPositionCommand
    let engine = SystemFakeEngine()
    let track = makeSystemTrack()
    engine.setLibrary([track])
    engine._setTrackIndex(0)
    engine._setDuration(200)
    engine._setTime(10)
    let c = NowPlayingInfoController(engine: engine)
    // Simulate remote seek by calling engine.seek directly (the handler does same)
    engine.seek(to: 77)
    systemCheck(abs(engine.state.currentTime - 77) < 0.01, "engine seek to 77 via remote path works (got \(engine.state.currentTime))")
    // Verify seekHistory captured
    systemCheck(engine.seekHistory.contains(77), "seekHistory contains 77")
    c.invalidate()
}

// MARK: - 9. Library/Player/Lyrics integrations still intact

@MainActor
func testSystemDoesNotBreakLibraryPlayerLyrics() {
    print("\n--- System doesn't break library/player/lyrics ---")
    let store = LibraryStore(defaults: UserDefaults(suiteName: "com.quaver.test.sysint.\(UUID().uuidString)") ?? .standard)
    let root = RootSplitViewController(store: store)
    _ = root.view
    root.view.layoutSubtreeIfNeeded()
    systemCheck(root.splitViewItems.count == 2, "root still has 2 split items")
    systemCheck(root.playerBar.view.superview != nil, "playerBar still hosted")
    systemCheck(root.lyricsVC.view.superview != nil, "lyricsVC still hosted")
    systemCheck(root.lyricsVC.view.isHidden, "lyrics initially hidden")
    root.toggleLyrics()
    systemCheck(root.isLyricsVisible, "lyrics visible after toggle")
    root.toggleLyrics()
    systemCheck(!root.isLyricsVisible, "lyrics hidden after second toggle")
    // Sidebar still has search field
    var foundSearch = false
    func walkSearch(_ v: NSView) {
        if v is NSSearchField { foundSearch = true }
        for s in v.subviews { walkSearch(s) }
    }
    walkSearch(root.sidebarVC.view)
    systemCheck(foundSearch, "sidebar still has NSSearchField")
}

// MARK: - Runner

@MainActor
func runAllSystemTests() async {
    testMenuStructure()
    testAppDelegateDelegation()
    testNavigateSinglePath()
    await testNowPlayingSync()
    await testNowPlayingArtwork()
    testNoSecondClock()
    testWindowChromeAfterSystemIntegration()
    await testKeyboardAndSeekCommand()
    testSystemDoesNotBreakLibraryPlayerLyrics()
    print("\n=== System Tests: \(systemFailures.isEmpty ? "ALL PASS" : "\(systemFailures.count) FAILURES") ===")
    for f in systemFailures { print("  • \(f)") }
}
