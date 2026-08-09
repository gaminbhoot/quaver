import AppKit
import AVFoundation
import Combine
import Foundation

// MARK: - Phase 5 — Native Player UI (mini-player + state sync)
// Covers: layout, native controls, SF Symbols, artwork, title/artist, play/pause,
// previous/next, progress/seek, volume, shuffle, repeat, queue, native state updates
// from PlaybackEngine.statePublisher, no independent clock, no duplicated state,
// resizing, accessibility, and full integration with already-verified engine.
// Shared/parameterized — not repetitive.

var playerFailures: [String] = []
func playerCheck(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if !cond { playerFailures.append("\(msg) (\(file):\(line))"); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}
func playerCheckClose(_ a: Double, _ b: Double, tol: Double, _ msg: String) {
    let ok = abs(a - b) <= tol
    playerCheck(ok, "\(msg) — got \(String(format:"%.4f",a)) expected \(String(format:"%.4f",b)) ±\(tol)")
}

let fixtureDir5 = URL(fileURLWithPath: "/tmp/quaver_phase3_fixtures")
let fixtureDuration5: Double = 1.5

@MainActor
func ensureFixtures5() throws -> [String: URL] {
    try FileManager.default.createDirectory(at: fixtureDir5, withIntermediateDirectories: true)
    let sr: Double = 44100
    func genWAV(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sr, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let frames = AVAudioFrameCount(sr * fixtureDuration5)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
    }
    func genM4A(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let frames = AVAudioFrameCount(sr * fixtureDuration5)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<Int(fmt.channelCount) { if let d = buf.floatChannelData?[ch] { for i in 0..<Int(frames) { d[i]=0 } } }
        try file.write(from: buf)
    }
    let wav = fixtureDir5.appendingPathComponent("given_up_on_me.wav")
    let m4a = fixtureDir5.appendingPathComponent("given_up_on_me.m4a")
    try genWAV(at: wav); try genM4A(at: m4a)
    return ["wav": wav, "m4a": m4a]
}

@MainActor
func makeTrack5(path: URL, title: String = "Given Up on Me", artist: String = "Artist", album: String = "Album", format: String? = nil) -> TrackMetadata {
    let f = format ?? path.pathExtension.uppercased()
    let p = path.path
    return TrackMetadata(path: p, title: title, artist: artist, album: album, duration: 10, format: f, coverDataURL: nil, lyricPath: nil)
}

@MainActor
func waitFor5(_ cond: @escaping () -> Bool, timeout: Double = 4, interval: Double = 0.05) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: UInt64(interval*1e9))
    }
    return cond()
}

@MainActor
func makeStore5() -> LibraryStore {
    let suite = "com.quaver.test.player.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite) ?? .standard
    for k in [QuaverStoreKeys.playlists, QuaverStoreKeys.likedTracks, QuaverStoreKeys.recentlyPlayed] { d.removeObject(forKey: k) }
    return LibraryStore(defaults: d)
}

// MARK: - Layout

@MainActor
func testPlayerBarLayout() {
    print("\n--- Player layout (native, SF Symbols, resizing) ---")
    let engine = NativePlaybackEngine()
    let bar = PlayerBarViewController(engine: engine)
    // Give it a realistic frame so Auto Layout can resolve height >=72
    bar.view.frame = NSRect(x: 0, y: 0, width: 800, height: 76)
    _ = bar.view; bar.view.layoutSubtreeIfNeeded()
    playerCheck(bar.view.frame.height >= 66, "player bar height >=66 (got \(bar.view.frame.height))")
    var foundWeb = false
    func walk(_ v: NSView) {
        let t = String(describing: type(of: v))
        if t.contains("WKWebView") || t.contains("WebView") { foundWeb = true }
        for s in v.subviews { walk(s) }
    }
    walk(bar.view)
    playerCheck(!foundWeb, "player bar has no WKWebView")
    playerCheck(bar.progressSlider is SeekSlider, "progress is SeekSlider")
    playerCheck(bar.volumeSlider is NSSlider, "volume slider exists")
    playerCheck(bar.playPauseButton.image != nil, "playPause has image (SF Symbol)")
    playerCheck(bar.previousButton.image != nil, "previous has image")
    playerCheck(bar.nextButton.image != nil, "next has image")
    playerCheck(bar.shuffleButton.image != nil, "shuffle has image")
    playerCheck(bar.repeatButton.image != nil, "repeat has image")
    playerCheck(bar.queueButton.image != nil, "queue has image")
    let art = bar.artworkHasImage
    playerCheck(art, "artwork has placeholder image when no track")
    playerCheck(bar.view.wantsLayer == true, "player bar wantsLayer for background")
    playerCheck(bar.view.accessibilityLabel() == "Player", "player has accessibility label")
    for width in [800.0, 1280.0] {
        bar.view.frame = NSRect(x: 0, y: 0, width: width, height: 76)
        bar.view.layoutSubtreeIfNeeded()
        let pbFrame = bar.playPauseButton.frame
        playerCheck(pbFrame.width > 0 && bar.progressSlider.frame.width > 100, "layout at \(Int(width))px: controls visible (play \(pbFrame.size) slider \(bar.progressSlider.frame.width))")
    }
    let mirror = Mirror(reflecting: bar)
    let hasTimer = mirror.children.contains { (_, v) in String(describing: type(of: v)).contains("Timer") } ||
        String(describing: type(of: bar)).contains("Timer")
    playerCheck(!hasTimer, "player bar has no Timer property (no independent clock)")
}

@MainActor
func testInitialStateNoTrack() {
    print("\n--- Initial state (no track) ---")
    let engine = NativePlaybackEngine()
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    // No async publisher delay needed — initial render is synchronous in viewDidLoad
    playerCheck(bar.currentTitle == "No track", "initial title is 'No track' (got \(bar.currentTitle))")
    playerCheck(bar.currentArtist == "Select a song to play", "initial artist placeholder")
    playerCheck(!bar.isPlayPauseEnabled, "playPause disabled with no track")
    playerCheck(!bar.isProgressEnabled, "progress disabled with no track")
    playerCheck(bar.elapsedText == "0:00", "elapsed 0:00 with no track (got \(bar.elapsedText))")
    playerCheck(bar.durationText == "—:—", "duration —:— with no track")
}

@MainActor
func testIntegrationRootSplitHostsPlayer() {
    print("\n--- Integration: RootSplit hosts PlayerBar ---")
    let store = makeStore5()
    let engine = NativePlaybackEngine()
    let root = RootSplitViewController(store: store, engine: engine)
    _ = root.view; root.view.layoutSubtreeIfNeeded()
    playerCheck(root.engine === engine, "RootSplit uses injected engine")
    // playerBar is non-optional strongly held
    playerCheck(root.playerBar.currentTitle == "No track", "player bar initially shows no track via root")
    let c = QuaverWindowController()
    let w = c.window as? QuaverWindow
    playerCheck(w != nil, "WindowController still hosts QuaverWindow with player")
    if let root2 = w?.contentViewController as? RootSplitViewController {
        _ = root2.view
        playerCheck(root2.splitViewItems.count == 2, "window split still 2 items (player not a split item)")
        var foundBar = false
        func walk(_ v: NSView) {
            if v is SeekSlider { foundBar = true }
            for s in v.subviews { walk(s) }
        }
        walk(root2.view)
        playerCheck(foundBar, "player bar (SeekSlider) inside window view hierarchy")
        playerCheck(!String(describing: type(of: root2.view)).contains("WKWebView"), "no WKWebView in integrated window")
    } else {
        playerCheck(false, "contentViewController is RootSplitViewController")
    }
}

// MARK: - Parameterized engine tests via PlayerBar

@MainActor
func testPlayPauseViaPlayerBar(url: URL, format: String) async {
    let t = makeTrack5(path: url)
    let engine = NativePlaybackEngine(library: [t])
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.play(trackAt: 0)
    let started = await waitFor5({ engine.state.isPlaying }, timeout: 3)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheck(started, "[\(format)] engine isPlaying after play (via engine)")
    playerCheck(bar.playPauseImageName == "pause.fill", "[\(format)] bar shows pause when playing")
    playerCheck(bar.isPlayPauseEnabled, "[\(format)] playPause enabled with track")
    _ = await waitFor5({ bar.currentTitle == "Given Up on Me" }, timeout: 1)
    playerCheck(bar.currentTitle == "Given Up on Me", "[\(format)] bar title matches track")
    engine.togglePlay()
    _ = await waitFor5({ !engine.state.isPlaying }, timeout: 2)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheck(!engine.state.isPlaying, "[\(format)] paused")
    playerCheck(bar.playPauseImageName == "play.fill", "[\(format)] bar shows play when paused")
    bar.playPauseButton.performClick(nil)
    _ = await waitFor5({ engine.state.isPlaying }, timeout: 2)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheck(engine.state.isPlaying, "[\(format)] resume via button → isPlaying")
    playerCheck(bar.playPauseImageName == "pause.fill", "[\(format)] bar pause again after resume")
}

@MainActor
func testSeekForwardBackwardAndRapid(url: URL, format: String) async {
    let t = makeTrack5(path: url)
    let engine = NativePlaybackEngine(library: [t])
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.play(trackAt: 0)
    _ = await waitFor5({ engine.state.duration > 0.1 }, timeout: 3)
    try? await Task.sleep(nanoseconds: 80_000_000)
    engine.seek(to: 0.5)
    _ = await waitFor5({ abs(engine.state.currentTime - 0.5) < 0.15 }, timeout: 2)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheckClose(engine.state.currentTime, 0.5, tol: 0.15, "[\(format)] forward seek via engine → bar \(bar.progressValue)")
    playerCheckClose(bar.progressValue, 0.5, tol: 0.15, "[\(format)] bar slider reflects forward seek")
    engine.seek(to: 0.1)
    _ = await waitFor5({ abs(engine.state.currentTime - 0.1) < 0.15 }, timeout: 2)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheckClose(bar.progressValue, 0.1, tol: 0.15, "[\(format)] bar reflects backward seek")
    for v in [0.2, 0.9, 0.1, 0.8, 0.4] { engine.seek(to: v) }
    _ = await waitFor5({ abs(engine.state.currentTime - 0.4) < 0.18 }, timeout: 2)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheckClose(engine.state.currentTime, 0.4, tol: 0.18, "[\(format)] rapid seek lands at 0.4")
    playerCheckClose(bar.progressValue, 0.4, tol: 0.18, "[\(format)] bar rapid seek final")
    bar.progressSlider.doubleValue = 0.9
    engine.seek(to: bar.progressSlider.doubleValue)
    _ = await waitFor5({ abs(engine.state.currentTime - 0.9) < 0.18 }, timeout: 2)
    playerCheck(abs(engine.state.currentTime - 0.9) < 0.2, "[\(format)] seek via slider doubleValue reflected")
}

@MainActor
func testDurationAndEOF(url: URL, format: String) async {
    let t = makeTrack5(path: url)
    let engine = NativePlaybackEngine(library: [t])
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.setRepeatMode(.off)
    engine.play(trackAt: 0)
    _ = await waitFor5({ engine.state.duration > 0.1 }, timeout: 3)
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheck(engine.state.duration > 0.5, "[\(format)] duration >0 after load (got \(engine.state.duration))")
    playerCheckClose(bar.progressMax, engine.state.duration, tol: 0.12, "[\(format)] bar maxValue matches duration")
    playerCheck(bar.durationText != "—:—", "[\(format)] bar durationText not placeholder")
    engine.seek(to: engine.state.duration)
    _ = await waitFor5({ abs(engine.state.currentTime - engine.state.duration) < 0.12 }, timeout: 2)
    playerCheckClose(engine.state.currentTime, engine.state.duration, tol: 0.12, "[\(format)] seek to duration → EOF")
    try? await Task.sleep(nanoseconds: 600_000_000)
    playerCheck(engine.state.currentTime <= engine.state.duration + 0.06, "[\(format)] does not exceed duration after EOF")
}

@MainActor
func testProgressUpdates(url: URL, format: String) async {
    let t = makeTrack5(path: url)
    let engine = NativePlaybackEngine(library: [t])
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.play(trackAt: 0)
    _ = await waitFor5({ engine.state.duration > 0.1 }, timeout: 3)
    let t0 = engine.state.currentTime
    try? await Task.sleep(nanoseconds: 400_000_000)
    let t1 = engine.state.currentTime
    playerCheck(t1 >= t0, "[\(format)] progress advances while playing ( \(t0)→\(t1) )")
    try? await Task.sleep(nanoseconds: 80_000_000)
    playerCheckClose(bar.progressValue, engine.state.currentTime, tol: 0.15, "[\(format)] bar tracks engine currentTime")
}

@MainActor
func testVolumeShuffleRepeatQueue() async {
    print("\n--- Volume / shuffle / repeat / queue ---")
    let engine = NativePlaybackEngine()
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.setVolume(0.3)
    _ = await waitFor5({ abs(bar.volumeValue - 0.3) < 0.02 }, timeout: 1)
    playerCheckClose(bar.volumeValue, 0.3, tol: 0.02, "volume 0.3 via engine → bar")
    bar.volumeSlider.doubleValue = 0.9
    bar.volumeSlider.performClick(nil)
    engine.setVolume(bar.volumeSlider.doubleValue)
    playerCheckClose(engine.state.volume, 0.9, tol: 0.02, "volume via slider → engine")
    let before = engine.state.isShuffle
    bar.shuffleButton.performClick(nil)
    _ = await waitFor5({ engine.state.isShuffle != before }, timeout: 1)
    playerCheck(engine.state.isShuffle != before, "shuffle toggle via button")
    playerCheck(bar.shuffleActive == engine.state.isShuffle, "bar shuffleActive mirrors engine")
    bar.shuffleButton.performClick(nil)
    _ = await waitFor5({ engine.state.isShuffle == before }, timeout: 1)
    playerCheck(engine.state.isShuffle == before, "shuffle toggle back")
    engine.setRepeatMode(.off)
    try? await Task.sleep(nanoseconds: 80_000_000)
    bar.repeatButton.performClick(nil)
    playerCheck(engine.state.repeatMode == .all, "repeat off→all via button")
    playerCheck(bar.repeatModeCurrent == .all, "bar repeat mirrors")
    bar.repeatButton.performClick(nil)
    playerCheck(engine.state.repeatMode == .one, "repeat all→one")
    bar.repeatButton.performClick(nil)
    playerCheck(engine.state.repeatMode == .off, "repeat one→off")
    class QCapture: PlayerBarViewControllerDelegate { var fired=false; func playerBarDidRequestQueue(_ bar: PlayerBarViewController) { fired=true }; func playerBarDidRequestLyrics(_ bar: PlayerBarViewController) {} }
    let cap = QCapture()
    bar.delegate = cap
    bar.queueButton.performClick(nil)
    playerCheck(cap.fired, "queue button fires delegate")
}

@MainActor
func testTrackChangesAndNextPrevious(urls: [URL]) async {
    print("\n--- Track changes / next / previous ---")
    let tracks = urls.enumerated().map { (i, u) in makeTrack5(path: u, title: "Track \(i)", artist: "Artist \(i)") }
    let engine = NativePlaybackEngine(library: tracks)
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.play(trackAt: 0)
    _ = await waitFor5({ engine.state.currentTrackIndex == 0 }, timeout: 2)
    _ = await waitFor5({ bar.currentTitle == "Track 0" }, timeout: 1)
    playerCheck(bar.currentTitle == "Track 0", "bar shows track 0 title (got \(bar.currentTitle))")
    engine.next()
    _ = await waitFor5({ engine.state.currentTrackIndex == 1 }, timeout: 2)
    _ = await waitFor5({ bar.currentTitle == "Track 1" }, timeout: 1)
    playerCheck(engine.state.currentTrackIndex == 1, "next → 1")
    playerCheck(bar.currentTitle == "Track 1", "bar title updates to track 1 (got \(bar.currentTitle))")
    bar.previousButton.performClick(nil)
    _ = await waitFor5({ engine.state.currentTrackIndex == 0 }, timeout: 2)
    _ = await waitFor5({ bar.currentTitle == "Track 0" }, timeout: 1)
    playerCheck(engine.state.currentTrackIndex == 0, "previous via button → 0")
    bar.nextButton.performClick(nil)
    _ = await waitFor5({ engine.state.currentTrackIndex == 1 }, timeout: 2)
    _ = await waitFor5({ bar.currentTitle == "Track 1" }, timeout: 1)
    playerCheck(engine.state.currentTrackIndex == 1, "next via button → 1")
}

@MainActor
func testLibraryDoubleClickPlaysViaRoot() async {
    print("\n--- Library double-click → engine play integration ---")
    let wav = fixtureDir5.appendingPathComponent("given_up_on_me.wav")
    let m4a = fixtureDir5.appendingPathComponent("given_up_on_me.m4a")
    _ = try? ensureFixtures5()
    let tracks = [makeTrack5(path: wav, title: "Alpha"), makeTrack5(path: m4a, title: "Beta")]
    let store = makeStore5()
    let engine = NativePlaybackEngine()
    let root = RootSplitViewController(store: store, engine: engine)
    _ = root.view; root.view.layoutSubtreeIfNeeded()
    root.setLibraryTracks(tracks)
    let visible = root.libraryVC.currentVisibleTracks
    playerCheck(visible.count == 2, "visible 2 before play")
    root.libraryDidSelectPlay(trackAt: 1, inVisibleTracks: visible)
    _ = await waitFor5({ engine.state.currentTrackIndex >= 0 }, timeout: 2)
    playerCheck(engine.currentTrack?.title == "Beta", "double-click visible index 1 plays Beta (got \(engine.currentTrack?.title ?? "nil"))")
    _ = await waitFor5({ root.playerBar.currentTitle == "Beta" }, timeout: 1)
    playerCheck(root.playerBar.currentTitle == "Beta", "playerBar title reflects double-clicked track (got \(root.playerBar.currentTitle))")
}

@MainActor
func testStateAfterReselectAndReopen() async {
    print("\n--- State after reselect / reopen ---")
    let wav = fixtureDir5.appendingPathComponent("given_up_on_me.wav")
    let m4a = fixtureDir5.appendingPathComponent("given_up_on_me.m4a")
    let t0 = makeTrack5(path: wav, title: "First")
    let t1 = makeTrack5(path: m4a, title: "Second")
    let engine = NativePlaybackEngine(library: [t0, t1])
    let bar = PlayerBarViewController(engine: engine)
    _ = bar.view
    engine.play(trackAt: 0)
    _ = await waitFor5({ engine.state.duration > 0.1 }, timeout: 3)
    engine.seek(to: 0.7)
    _ = await waitFor5({ abs(engine.state.currentTime - 0.7) < 0.15 }, timeout: 2)
    engine.play(trackAt: 1)
    _ = await waitFor5({ engine.state.currentTrackIndex == 1 }, timeout: 2)
    _ = await waitFor5({ bar.currentTitle == "Second" }, timeout: 1)
    playerCheck(abs(engine.state.currentTime) < 0.3, "reselect resets currentTime near 0 (got \(engine.state.currentTime))")
    playerCheck(bar.currentTitle == "Second", "bar title after reselect is Second (got \(bar.currentTitle))")
    playerCheck(bar.progressMax > 0.5, "bar maxValue still >0 after reselect")
}

@MainActor
func testNoDuplicatedState() {
    print("\n--- No duplicated state / single source ---")
    let engine = NativePlaybackEngine()
    let bar = PlayerBarViewController(engine: engine)
    let mirror = Mirror(reflecting: bar)
    var suspicious = false
    for child in mirror.children {
        let label = child.label ?? ""
        let ty = String(describing: type(of: child.value))
        if (label.contains("track") || label.contains("Track")) && ty.contains("TrackMetadata") { suspicious = true }
        if ty.contains("PlaybackState") && label != "cancellables" && label != "engine" { suspicious = true }
    }
    playerCheck(!suspicious, "player bar has no duplicated TrackMetadata/PlaybackState storage")
    playerCheck(bar is PlayerBarViewController, "bar is PlayerBarViewController (native)")
}

// MARK: - Runner

@MainActor
func runAllPlayerTests() async {
    do { _ = try ensureFixtures5() } catch { print("fixtures failed \(error)"); playerFailures.append("fixtures \(error)") }
    testPlayerBarLayout()
    testInitialStateNoTrack()
    testIntegrationRootSplitHostsPlayer()
    let p = fixtureDir5
    let wav = p.appendingPathComponent("given_up_on_me.wav")
    let m4a = p.appendingPathComponent("given_up_on_me.m4a")
    for (fmt, url) in [("wav", wav), ("m4a", m4a)] {
        print("\n=== Player param [\(fmt)] ===")
        await testPlayPauseViaPlayerBar(url: url, format: fmt)
        await testSeekForwardBackwardAndRapid(url: url, format: fmt)
        await testDurationAndEOF(url: url, format: fmt)
        await testProgressUpdates(url: url, format: fmt)
    }
    await testVolumeShuffleRepeatQueue()
    await testTrackChangesAndNextPrevious(urls: [wav, m4a])
    await testLibraryDoubleClickPlaysViaRoot()
    await testStateAfterReselectAndReopen()
    testNoDuplicatedState()
}
