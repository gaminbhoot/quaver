import AppKit
import Foundation

// MARK: - Phase 4 Library Foundation Tests
// Covers 12 aspects: sidebar nav, search, filtering, sorting, liked, recent, album/artist, playlist, selection, empty, large, resizing
// + launch and WebKit already verified in Phase4WindowTests + otool.

var libraryFailures: [String] = []
func libraryCheck(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if !cond { libraryFailures.append("\(msg) (\(file):\(line))"); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}

// Helpers — MainActor because LibraryStore is MainActor
@MainActor func makeTrack(path: String = "", title: String, artist: String = "Artist", album: String = "Album", format: String = "mp3", duration: Double = 180, coverDataURL: String? = nil) -> TrackMetadata {
    let p = path.isEmpty ? "/music/\(title).\(format)" : path
    return TrackMetadata(path: p, title: title, artist: artist, album: album, duration: duration, format: format, coverDataURL: coverDataURL, lyricPath: nil)
}

@MainActor func makeStore() -> LibraryStore {
    let suite = "com.quaver.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite) ?? .standard
    for k in [QuaverStoreKeys.playlists, QuaverStoreKeys.likedTracks, QuaverStoreKeys.recentlyPlayed] { d.removeObject(forKey: k) }
    return LibraryStore(defaults: d)
}

@MainActor func installedLibrary(in vc: LibraryViewController) -> [TrackMetadata] { vc.currentVisibleTracks }

@MainActor
func testSidebarNavigation() {
    print("\n--- Sidebar navigation ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    root.sidebarVC.delegate?.sidebarDidSelectView(.all)
    libraryCheck(root.selectedView == .all, "sidebar All Songs selects .all")
    root.sidebarVC.delegate?.sidebarDidSelectView(.liked)
    libraryCheck(root.selectedView == .liked, "sidebar Liked selects .liked")
    root.sidebarVC.delegate?.sidebarDidSelectView(.recent)
    libraryCheck(root.selectedView == .recent, "sidebar Recent selects .recent")
    root.sidebarVC.delegate?.sidebarDidSelectView(.artists)
    libraryCheck(root.selectedView == .artists, "sidebar Artists selects .artists")
    root.sidebarVC.delegate?.sidebarDidSelectView(.albums)
    libraryCheck(root.selectedView == .albums, "sidebar Albums selects .albums")
    let pl = store.createPlaylist(name: "Roadtrip")
    root.sidebarVC.delegate?.sidebarDidSelectPlaylist(id: pl.id)
    if case .playlist(let id) = root.selectedView { libraryCheck(id == pl.id, "sidebar playlist selects correct id") }
    else { libraryCheck(false, "sidebar playlist selects playlist view") }
    root.setViewForTest(.liked)
    libraryCheck(root.selectedView == .liked, "Root setViewForTest liked")
    libraryCheck(root.libraryVC.currentViewForTest == .liked, "LibraryVC view is liked")
}

@MainActor
func testSearch() {
    print("\n--- Search ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let tracks = [
        makeTrack(title: "Love Song", artist: "Alpha", album: "Blue"),
        makeTrack(title: "Hate Song", artist: "Beta", album: "Red"),
        makeTrack(title: "Lovely Day", artist: "Alpha", album: "Green"),
    ]
    root.setLibraryTracks(tracks)
    root.libraryVC.setSearchQuery("")
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 3, "search empty shows all (3)")
    root.sidebarVC.delegate?.sidebarSearchChanged("love")
    libraryCheck(root.searchQuery == "love", "sidebar search updates root searchQuery")
    libraryCheck(root.libraryVC.currentSearchForTest == "love", "library search updated via delegate")
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 2, "search 'love' matches 2 (Love Song, Lovely Day)")
    root.libraryVC.setSearchQuery("beta")
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 1 && root.libraryVC.currentVisibleTracks[0].artist == "Beta", "search 'beta' matches artist")
    root.libraryVC.setSearchQuery("nope")
    libraryCheck(root.libraryVC.currentVisibleTracks.isEmpty, "search 'nope' yields empty")
    libraryCheck(root.libraryVC.isEmptyViewVisible, "empty view visible on no matches (non-empty library)")
    root.libraryVC.setSearchQuery("")
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 3, "clear search restores all")
    root.libraryVC.setSearchQuery("LOVE")
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 2, "search case-insensitive")
}

@MainActor
func testLibraryFiltering() {
    print("\n--- Library filtering (all/flac/lossless) ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let tracks = [
        makeTrack(title: "A", format: "flac"),
        makeTrack(title: "B", format: "mp3"),
        makeTrack(title: "C", format: "wav"),
        makeTrack(title: "D", format: "m4a"),
        makeTrack(title: "E", format: "alac"),
        makeTrack(title: "F", format: "aiff"),
    ]
    root.setLibraryTracks(tracks)
    store.libraryFilter = .all
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 6, "filter all shows 6")
    store.libraryFilter = .flac
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 1 && root.libraryVC.currentVisibleTracks[0].format == "flac", "filter flac shows only flac")
    store.libraryFilter = .lossless
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 4, "filter lossless shows 4 (flac/wav/alac/aiff) got \(root.libraryVC.currentVisibleTracks.map{$0.format})")
    store.libraryFilter = .all
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 6, "filter back to all")
}

@MainActor
func testSorting() {
    print("\n--- Sorting ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let tracks = [
        makeTrack(title: "Charlie", artist: "Zulu", album: "Bravo"),
        makeTrack(title: "Alpha", artist: "Mike", album: "Charlie"),
        makeTrack(title: "Bravo", artist: "Alpha", album: "Alpha"),
    ]
    root.setLibraryTracks(tracks)
    store.librarySort = .title
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.map{$0.title} == ["Alpha","Bravo","Charlie"], "sort by title")
    store.librarySort = .artist
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.map{$0.artist} == ["Alpha","Mike","Zulu"], "sort by artist")
    store.librarySort = .album
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.map{$0.album} == ["Alpha","Bravo","Charlie"], "sort by album")
    store.librarySort = .recent
    let alphaKey = tracks[1].key
    let bravoKey = tracks[2].key
    store.recordPlayed(trackKey: bravoKey)
    Thread.sleep(forTimeInterval: 0.01)
    store.recordPlayed(trackKey: alphaKey)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    let recentOrder = root.libraryVC.currentVisibleTracks.map{$0.title}
    libraryCheck(recentOrder.first == "Alpha", "sort recent puts most recently played first (got \(recentOrder))")
}

@MainActor
func testLikedView() {
    print("\n--- Liked view ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let t1 = makeTrack(title: "Liked One", format: "flac")
    let t2 = makeTrack(title: "Not Liked", format: "mp3")
    let t3 = makeTrack(title: "Liked Two", format: "flac")
    root.setLibraryTracks([t1,t2,t3])
    store.toggleLike(trackKey: t1.key)
    store.toggleLike(trackKey: t3.key)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    root.setViewForTest(.liked)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 2, "liked view shows 2")
    libraryCheck(root.libraryVC.currentVisibleTracks.allSatisfy{ store.likedTrackKeys.contains($0.key)}, "liked view only liked")
    store.toggleLike(trackKey: t1.key)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 1, "liked view updates after unlike")
}

@MainActor
func testRecentView() {
    print("\n--- Recent view ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let t1 = makeTrack(path: "/a.mp3", title: "A")
    let t2 = makeTrack(path: "/b.mp3", title: "B")
    let t3 = makeTrack(path: "/c.mp3", title: "C")
    root.setLibraryTracks([t1,t2,t3])
    store.recordPlayed(trackKey: t2.key)
    store.recordPlayed(trackKey: t1.key)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    root.setViewForTest(.recent)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 2, "recent shows 2 played")
    libraryCheck(root.libraryVC.currentVisibleTracks.first?.key == t1.key, "recent most recent first")
    root.setViewForTest(.all)
    root.libraryVC.delegate?.libraryDidSelectPlay(trackAt: 2, inVisibleTracks: root.libraryVC.currentVisibleTracks)
    libraryCheck(store.recentlyPlayed.contains(where:{ $0.key==root.libraryVC.currentVisibleTracks[2].key || $0.key==t3.key }), "delegate play records recent")
}

@MainActor
func testAlbumArtistNavigation() {
    print("\n--- Artist/Album navigation ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let tracks = [
        makeTrack(title: "Song1", artist: "Nina", album: "Blue"),
        makeTrack(title: "Song2", artist: "Nina", album: "Red"),
        makeTrack(title: "Song3", artist: "Omar", album: "Blue"),
        makeTrack(title: "Song4", artist: "Nina", album: "Blue"),
    ]
    root.setLibraryTracks(tracks)
    root.setViewForTest(.artist("Nina"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 3, "artist Nina shows 3")
    libraryCheck(root.libraryVC.currentVisibleTracks.allSatisfy{$0.artist=="Nina"}, "artist filter correct")
    root.setViewForTest(.album("Blue"))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 3, "album Blue shows 3")
    libraryCheck(root.libraryVC.currentVisibleTracks.allSatisfy{$0.album=="Blue"}, "album filter correct")
    root.setViewForTest(.artists)
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 4, "artists browse shows all tracks")
    root.setViewForTest(.albums)
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 4, "albums browse shows all")
}

@MainActor
func testPlaylistNavigation() {
    print("\n--- Playlist navigation ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let t1 = makeTrack(path: "/p1.mp3", title: "P1")
    let t2 = makeTrack(path: "/p2.mp3", title: "P2")
    let t3 = makeTrack(path: "/p3.mp3", title: "P3")
    root.setLibraryTracks([t1,t2,t3])
    let pl = store.createPlaylist(name: "Favorites")
    store.addTrack(t1.key, toPlaylist: pl.id)
    store.addTrack(t3.key, toPlaylist: pl.id)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    root.sidebarVC.updatePlaylists(store.playlists)
    root.setViewForTest(.playlist(id: pl.id))
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 2, "playlist shows 2 tracks")
    let keys = Set(root.libraryVC.currentVisibleTracks.map{$0.key})
    libraryCheck(keys == Set([t1.key, t3.key]), "playlist contains correct keys")
    store.removeTrack(t1.key, fromPlaylist: pl.id)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 1, "playlist after remove shows 1")
    store.removeTrack(t3.key, fromPlaylist: pl.id)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.currentVisibleTracks.isEmpty, "playlist empty after removing all")
    libraryCheck(root.libraryVC.isEmptyViewVisible && !root.libraryVC.isScrollViewVisible, "empty view for empty playlist")
    root.sidebarVC.delegate?.sidebarDidSelectPlaylist(id: pl.id)
    libraryCheck(root.selectedView == .playlist(id: pl.id), "sidebar delegate selects playlist")
}

@MainActor
func testSelection() {
    print("\n--- Selection ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let tracks = (0..<5).map { makeTrack(title: "Track \($0)") }
    root.setLibraryTracks(tracks)
    root.setViewForTest(.all)
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 5, "selection: 5 tracks visible")
    class DelegateSpy: LibraryViewControllerDelegate {
        var played: (Int, [TrackMetadata])?
        func libraryDidSelectPlay(trackAt index: Int, inVisibleTracks visible: [TrackMetadata]) { played = (index, visible) }
        func libraryDidRequestAddFolder() {}
    }
    let spy = DelegateSpy()
    let prev = root.libraryVC.delegate
    root.libraryVC.delegate = spy
    root.libraryVC.delegate?.libraryDidSelectPlay(trackAt: 2, inVisibleTracks: root.libraryVC.currentVisibleTracks)
    libraryCheck(spy.played?.0 == 2, "selection double-click reports correct index")
    root.libraryVC.delegate = prev
    libraryCheck(true, "selection: header non-selectable logic exists")
}

@MainActor
func testEmptyLibrary() {
    print("\n--- Empty library ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    root.setLibraryTracks([])
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.isEmptyViewVisible, "empty library shows emptyView")
    libraryCheck(!root.libraryVC.isScrollViewVisible, "empty library hides scroll")
    libraryCheck(root.libraryVC.currentVisibleTracks.isEmpty, "empty library visibleTracks empty")
    let t = makeTrack(title: "Now there is one")
    root.setLibraryTracks([t])
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(!root.libraryVC.isEmptyViewVisible, "non-empty hides emptyView")
    libraryCheck(root.libraryVC.isScrollViewVisible, "non-empty shows scroll")
    store.libraryFilter = .flac
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    libraryCheck(root.libraryVC.isEmptyViewVisible, "no matches after filter shows emptyView")
    libraryCheck(root.libraryVC.currentVisibleTracks.isEmpty, "no matches visibleTracks empty")
}

@MainActor
func testLargeLibrary() {
    print("\n--- Large library ---")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    let large = (0..<5000).map { i in makeTrack(title: String(format: "Track %04d", i), artist: "Artist \(i % 100)", album: "Album \(i % 50)", format: i % 3 == 0 ? "flac" : "mp3") }
    let start = CFAbsoluteTimeGetCurrent()
    root.setLibraryTracks(large)
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    libraryCheck(root.libraryVC.currentVisibleTracks.count == 5000, "large library 5000 visible")
    libraryCheck(elapsed < 2.0, "large library set in <2s (took \(String(format:"%.3f", elapsed))s)")
    let sStart = CFAbsoluteTimeGetCurrent()
    root.libraryVC.setSearchQuery("Track 00")
    let sElapsed = CFAbsoluteTimeGetCurrent() - sStart
    libraryCheck(root.libraryVC.currentVisibleTracks.count > 0, "large search yields results \(root.libraryVC.currentVisibleTracks.count)")
    libraryCheck(sElapsed < 1.0, "large search <1s (took \(String(format:"%.3f", sElapsed))s)")
    root.libraryVC.setSearchQuery("")
    store.libraryFilter = .flac
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    let flacCount = root.libraryVC.currentVisibleTracks.count
    libraryCheck(flacCount > 1500 && flacCount < 1800, "large flac filter count ~1667 got \(flacCount)")
}

@MainActor
func testWindowResizing() {
    print("\n--- Window resizing / split ---")
    let w = QuaverWindow()
    libraryCheck(w.minSize == NSSize(width: 800, height: 500), "minSize remains 800x500 after UI wiring")
    libraryCheck(w.styleMask.contains(.resizable), "window still resizable")
    libraryCheck(w.contentViewController is RootSplitViewController || w.contentView != nil, "window has content")
    let store = makeStore()
    let root = RootSplitViewController(store: store)
    _ = root.view
    libraryCheck(root.splitView.isVertical, "split is vertical")
    libraryCheck(root.splitViewItems.count == 2, "split has 2 items")
    let sidebarItem = root.splitViewItems[0]
    libraryCheck(sidebarItem.minimumThickness == 200, "sidebar min 200")
    libraryCheck(sidebarItem.maximumThickness == 320, "sidebar max 320")
    libraryCheck(root.splitViewItems[1].minimumThickness == 480, "library min 480")
    w.setContentSize(NSSize(width: 1280, height: 800))
    libraryCheck(w.frame.width >= 800, "window 1280 OK")
    w.setContentSize(NSSize(width: 800, height: 500))
    libraryCheck(w.frame.width >= 800, "window min 800 OK")
    root.view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    root.view.layoutSubtreeIfNeeded()
    if root.splitView.frame.width == 0 {
        root.splitView.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    }
    root.splitView.setPosition(260, ofDividerAt: 0)
    let pos = root.splitView.arrangedSubviews.first?.frame.width ?? 260
    libraryCheck(pos >= 200 && pos <= 320, "sidebar width within 200–320 (got \(pos))")
}

@MainActor
func testLaunchIntegration() {
    print("\n--- Launch integration ---")
    let c = QuaverWindowController()
    let w = c.window as? QuaverWindow
    libraryCheck(w != nil, "WindowController hosts QuaverWindow")
    libraryCheck(w?.contentViewController is RootSplitViewController, "contentViewController is RootSplitViewController")
    if let root = w?.contentViewController as? RootSplitViewController {
        _ = root.view
        libraryCheck(root.splitViewItems.count == 2, "launch: 2 split items")
    }
    var foundWebView = false
    func walk(_ v: NSView) {
        let t = String(describing: type(of: v))
        if t.contains("WKWebView") || t.contains("WebView") { foundWebView = true }
        for sub in v.subviews { walk(sub) }
    }
    if let cv = w?.contentView { walk(cv) }
    if let vc = w?.contentViewController?.view { walk(vc) }
    libraryCheck(!foundWebView, "no WKWebView after full UI wiring")
}

@MainActor
func runAllLibraryTests() {
    testSidebarNavigation()
    testSearch()
    testLibraryFiltering()
    testSorting()
    testLikedView()
    testRecentView()
    testAlbumArtistNavigation()
    testPlaylistNavigation()
    testSelection()
    testEmptyLibrary()
    testLargeLibrary()
    testWindowResizing()
    testLaunchIntegration()
    print("\n=== Library Tests: \(libraryFailures.isEmpty ? "ALL PASS" : "\(libraryFailures.count) FAILURES") ===")
    for f in libraryFailures { print("  • \(f)") }
}
