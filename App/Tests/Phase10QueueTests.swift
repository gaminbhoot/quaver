import AppKit
import Combine
import Foundation

// MARK: - Phase 10 - Queue / Up Next (native NSPopover over single PlaybackEngine queue)
// No second clock, no Timer, no WebView. Queue is derived from engine.queueOrder (library indices).
// UI observes statePublisher only.

var phase10Failures: [String] = []
func p10Check(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if !cond { phase10Failures.append("\(msg) (\(file):\(line))"); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}

// MARK: - Fake engine for UI isolation (mirrors P9 fake but adds queueOrder)
@MainActor
final class P10FakeEngine: PlaybackEngine {
    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    var state: PlaybackState { subject.value }
    var statePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    var library: [TrackMetadata] = []
    var currentTrack: TrackMetadata? {
        let idx = subject.value.currentTrackIndex
        guard library.indices.contains(idx) else { return nil }
        return library[idx]
    }
    var queueOrder: [Int] { subject.value.queueOrder }
    func play(trackAt i: Int) { guard library.indices.contains(i) else { return }; var s = subject.value; s.currentTrackIndex = i; s.currentTime = 0; subject.send(s) }
    func togglePlay() { var s = subject.value; s.isPlaying.toggle(); subject.send(s) }
    func pause() { var s = subject.value; s.isPlaying = false; subject.send(s) }
    func next() {
        let cur = subject.value.currentTrackIndex
        guard !queueOrder.isEmpty, let pos = queueOrder.firstIndex(of: cur) else {
            if library.indices.contains(cur+1) { play(trackAt: cur+1) }; return
        }
        let nxt = pos + 1
        if nxt < queueOrder.count { play(trackAt: queueOrder[nxt]) }
        else if subject.value.repeatMode == .all, let first = queueOrder.first { play(trackAt: first) }
    }
    func previous() {
        let cur = subject.value.currentTrackIndex
        guard !queueOrder.isEmpty, let pos = queueOrder.firstIndex(of: cur) else { if cur>0 { play(trackAt: cur-1) }; return }
        if pos > 0 { play(trackAt: queueOrder[pos-1]) }
        else if subject.value.repeatMode == .all, let last = queueOrder.last { play(trackAt: last) }
    }
    func seek(to t: Double) { var s = subject.value; s.currentTime = max(0,t); subject.send(s) }
    func setVolume(_ v: Double) { var s = subject.value; s.volume = max(0,min(1,v)); subject.send(s) }
    func setShuffle(_ e: Bool) { var s = subject.value; s.isShuffle = e; subject.send(s) }
    func setRepeatMode(_ m: RepeatMode) { var s = subject.value; s.repeatMode = m; subject.send(s) }
    func moveQueueItem(from s: Int, to d: Int) {
        var q = subject.value.queueOrder
        guard q.indices.contains(s) else { return }
        guard d >= 0, d <= q.count else { return }
        let item = q.remove(at: s)
        let dest = min(d, q.count)
        q.insert(item, at: dest)
        var st = subject.value; st.queueOrder = q; subject.send(st)
    }
    // helpers
    func _setLibrary(_ tracks: [TrackMetadata]) { library = tracks; var s = subject.value; s.queueOrder = Array(tracks.indices); if s.currentTrackIndex >= tracks.count { s.currentTrackIndex = -1 }; subject.send(s) }
    func _setTrack(_ idx: Int) { var s = subject.value; s.currentTrackIndex = idx; subject.send(s) }
    func _setPlaying(_ p: Bool) { var s = subject.value; s.isPlaying = p; subject.send(s) }
    func _setShuffle(_ e: Bool) { var s = subject.value; s.isShuffle = e; subject.send(s) }
    func _setRepeat(_ m: RepeatMode) { var s = subject.value; s.repeatMode = m; subject.send(s) }
}

@MainActor
func p10MakeTrack(_ title: String, artist: String = "Artist", path: String? = nil) -> TrackMetadata {
    let p = path ?? "/tmp/\(title).mp3"
    return TrackMetadata(path: p, title: title, artist: artist, album: "Album", duration: 200, format: "MP3", coverDataURL: nil, lyricPath: nil)
}
@MainActor
func p10MakeVC(engine: P10FakeEngine? = nil, library: [TrackMetadata]? = nil) -> (P10FakeEngine, QueuePopoverViewController) {
    let e = engine ?? P10FakeEngine()
    if let lib = library { e._setLibrary(lib) }
    let vc = QueuePopoverViewController(engine: e, library: e.library)
    _ = vc.view; vc.loadViewIfNeeded()
    return (e, vc)
}

// MARK: - 1. Engine queue basics (real engine)
@MainActor
func testP10EngineQueueBasics() {
    print("\n--- P10: engine queue basics ---")
    let eng = NativePlaybackEngine()
    let tracks = (0..<5).map { p10MakeTrack("T\($0)") }
    eng.setLibrary(tracks)
    // queueOrder should be populated synchronously via rebuild
    p10Check(eng.queueOrder.count == 5, "queueOrder count 5 after setLibrary (got \(eng.queueOrder.count))")
    p10Check(eng.queueOrder == [0,1,2,3,4], "queueOrder sequential when shuffle off")
    p10Check(eng.state.queueOrder == eng.queueOrder, "state.queueOrder mirrors queueOrder")
    eng.setShuffle(true)
    p10Check(eng.state.isShuffle, "shuffle on")
    p10Check(eng.queueOrder.count == 5, "queueOrder still 5 after shuffle")
    p10Check(Set(eng.queueOrder) == Set(0..<5), "queueOrder is permutation after shuffle")
    eng.setShuffle(false)
    p10Check(!eng.state.isShuffle, "shuffle off")
    p10Check(eng.queueOrder == [0,1,2,3,4], "queueOrder back to sequential after shuffle off")
    // empty library
    eng.setLibrary([])
    p10Check(eng.queueOrder.isEmpty, "queueOrder empty after clear")
    p10Check(eng.state.queueOrder.isEmpty, "state queue empty")
}

@MainActor
func testP10EngineMove() {
    print("\n--- P10: engine moveQueueItem ---")
    let eng = NativePlaybackEngine()
    let tracks = (0..<5).map { p10MakeTrack("T\($0)") }
    eng.setLibrary(tracks)
    // move 0 -> 2: [0,1,2,3,4] => [1,2,0,3,4] when using our dest semantics?
    // Our implementation: remove at 0, insert at 2 => [1,2,0,3,4]
    eng.moveQueueItem(from: 0, to: 2)
    p10Check(eng.queueOrder == [1,2,0,3,4], "move 0->2 got \(eng.queueOrder)")
    p10Check(eng.state.queueOrder == eng.queueOrder, "state mirrors after move")
    // move last to front
    eng.moveQueueItem(from: 4, to: 0)
    p10Check(eng.queueOrder == [4,1,2,0,3], "move last->front got \(eng.queueOrder)")
    // invalid source ignored
    let before = eng.queueOrder
    eng.moveQueueItem(from: 99, to: 1)
    p10Check(eng.queueOrder == before, "invalid source ignored")
    // invalid dest ignored
    eng.moveQueueItem(from: 0, to: 99)
    p10Check(eng.queueOrder == before, "invalid dest ignored")
    // move to same position is no-op? source 1->1 removes and reinserts at 1 => same?
    eng.moveQueueItem(from: 1, to: 1)
    // after removal/insert at same index, order should be stable
    p10Check(eng.queueOrder.count == 5, "count stable after no-op move")
}

@MainActor
func testP10EngineNextRespectsQueue() {
    print("\n--- P10: next/previous respect reordered queue ---")
    let eng = NativePlaybackEngine()
    let tracks = (0..<4).map { p10MakeTrack("T\($0)") }
    eng.setLibrary(tracks)
    eng.play(trackAt: 0)
    p10Check(eng.state.currentTrackIndex == 0, "playing 0")
    // Reorder queue to [0,2,1,3]
    eng.moveQueueItem(from: 1, to: 2) // [0,2,1,3]? Let's do explicit: start [0,1,2,3], move 1 (value1) to 2 => [0,2,1,3]
    // Actually move index1 (value 1) to index2 => remove 1 => [0,2,3], insert at 2 => [0,2,1,3]? Wait 1 is value, not index. Let's compute.
    // Start [0,1,2,3], move from 1 (value 1) to 2 => remove at1 => [0,2,3], insert 1 at2 => [0,2,1,3]
    p10Check(eng.queueOrder == [0,2,1,3], "reordered to [0,2,1,3] got \(eng.queueOrder)")
    eng.next()
    // from 0, next in queue is 2
    // Need small delay for AVPlayer async? But native engine next is synchronous play()
    // Use short wait for state to settle
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 2, "next respects queue -> 2 got \(eng.state.currentTrackIndex)")
    eng.next()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 1, "next ->1 got \(eng.state.currentTrackIndex)")
    eng.previous()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 2, "previous ->2 got \(eng.state.currentTrackIndex)")
    // wrap with repeat all
    eng.setRepeatMode(.all)
    eng.moveQueueItem(from: 0, to: 0) // no-op
    // go to last in queue (3)
    eng.play(trackAt: 3)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 3, "at last 3")
    eng.next()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 0, "wrap to 0 with repeat all, got \(eng.state.currentTrackIndex)")
    eng.previous()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 3, "previous wrap to 3")
    // repeat off -> no wrap at end
    eng.setRepeatMode(.off)
    eng.play(trackAt: 3)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    eng.next()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    p10Check(eng.state.currentTrackIndex == 3, "no wrap when repeat off")
}

// MARK: - 2. Popover creation / empty state
@MainActor
func testP10PopoverCreation() {
    print("\n--- P10: popover creation ---")
    let (eng, vc) = p10MakeVC(library: [])
    p10Check(vc.view.frame.width == 360, "popover width 360")
    p10Check(vc.view.frame.height == 380, "popover height 380")
    p10Check(vc.isEmpty, "empty when no library")
    // After setting library, not empty
    let tracks = (0..<3).map { p10MakeTrack("S\($0)") }
    eng._setLibrary(tracks)
    vc.updateLibrary(tracks)
    p10Check(!vc.isEmpty, "not empty after library set")
    p10Check(vc.numberOfRows == 3, "rows 3")
    p10Check(eng.queueOrder.count == 3, "engine queue 3")
}

@MainActor
func testP10PopoverEmptyState() {
    print("\n--- P10: empty state transitions ---")
    let tracks = [p10MakeTrack("A")]
    let (eng, vc) = p10MakeVC(library: tracks)
    p10Check(!vc.isEmpty, "has rows")
    // Clear library -> empty
    eng._setLibrary([])
    vc.updateLibrary([])
    p10Check(vc.isEmpty, "empty after clear")
    p10Check(vc.numberOfRows == 0, "0 rows when empty")
    // Re-add
    let two = (0..<2).map { p10MakeTrack("B\($0)") }
    eng._setLibrary(two)
    vc.updateLibrary(two)
    p10Check(vc.numberOfRows == 2, "2 rows after re-add")
}

@MainActor
func testP10PopoverShowsQueue() {
    print("\n--- P10: shows queue order ---")
    let tracks = (0..<4).map { p10MakeTrack("Q\($0)", artist: "Art\($0)") }
    let (eng, vc) = p10MakeVC(library: tracks)
    p10Check(vc.numberOfRows == 4, "4 rows")
    // Move queue and check VC reflects
    eng.moveQueueItem(from: 0, to: 3)
    // VC observes statePublisher asynchronously — pump runloop
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    p10Check(eng.queueOrder == [1,2,3,0], "engine reordered to [1,2,3,0]")
    p10Check(vc.numberOfRows == 4, "vc rows still 4 after reorder")
}

@MainActor
func testP10PopoverDrag() {
    print("\n--- P10: drag reorder via VC ---")
    let tracks = (0..<5).map { p10MakeTrack("D\($0)") }
    let (eng, vc) = p10MakeVC(library: tracks)
    vc.simulateMove(from: 0, to: 4)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    p10Check(eng.queueOrder.first == 1 && eng.queueOrder.last == 0, "drag 0->4 moved first to last: \(eng.queueOrder)")
    // Invalid via VC also ignored
    let before = eng.queueOrder
    vc.simulateMove(from: 99, to: 0)
    p10Check(eng.queueOrder == before, "invalid drag ignored")
    // Rapid random moves preserve permutation
    for _ in 0..<20 {
        let a = Int.random(in: 0..<5)
        let b = Int.random(in: 0..<5)
        vc.simulateMove(from: a, to: b)
    }
    p10Check(Set(eng.queueOrder) == Set(0..<5), "permutation preserved after random moves")
    p10Check(eng.queueOrder.count == 5, "count 5 after random")
}

@MainActor
func testP10PopoverDoubleClick() {
    print("\n--- P10: double-click / simulatePlay ---")
    let tracks = (0..<3).map { p10MakeTrack("P\($0)") }
    let (eng, vc) = p10MakeVC(library: tracks)
    eng._setTrack(0)
    vc.updateLibrary(tracks)
    vc.simulatePlay(row: 2)
    p10Check(eng.state.currentTrackIndex == 2, "play row 2 -> index 2 (got \(eng.state.currentTrackIndex))")
    vc.simulatePlay(row: 1)
    p10Check(eng.state.currentTrackIndex == 1, "play row 1 ->1")
    // out of bounds ignored
    let cur = eng.state.currentTrackIndex
    vc.simulatePlay(row: 99)
    p10Check(eng.state.currentTrackIndex == cur, "oob play ignored")
}

@MainActor
func testP10PopoverLifecycle() {
    print("\n--- P10: lifecycle / teardown / repeated ---")
    let tracks = (0..<2).map { p10MakeTrack("L\($0)") }
    var vc: QueuePopoverViewController? = nil
    autoreleasepool {
        let (eng, v) = p10MakeVC(library: tracks)
        vc = v
        _ = eng
        v.updateLibrary(tracks)
        p10Check(v.numberOfRows == 2, "2 rows before teardown")
        v.updateLibrary([])
        p10Check(v.isEmpty, "empty after teardown clear")
        // repeated invocation
        v.updateLibrary(tracks)
        p10Check(!v.isEmpty, "not empty after re-add")
        v.updateLibrary(tracks)
        p10Check(v.numberOfRows == 2, "stable after repeat")
    }
    vc = nil
    p10Check(true, "deinit without crash")
}

@MainActor
func testP10RootSplitIntegration() {
    print("\n--- P10: RootSplit integration ---")
    let store = LibraryStore(defaults: UserDefaults(suiteName: "test.quaver.p10.\(UUID().uuidString)")!)
    let eng = NativePlaybackEngine()
    let root = RootSplitViewController(store: store, engine: eng)
    _ = root.view; root.loadViewIfNeeded()
    // Initially not visible (no window, headless)
    p10Check(!root.isQueueVisible, "queue not visible initially")
    // toggle with no window -> should not crash, remain not visible
    root.toggleQueue(anchoredTo: nil)
    p10Check(!root.isQueueVisible, "still not visible headless")
    // Set library and verify queueVC sync
    let tracks = (0..<3).map { p10MakeTrack("R\($0)", path: "/tmp/r\($0).mp3") }
    root.setLibraryTracks(tracks)
    // Root's queueVC should have library
    p10Check(root.queueVC.numberOfRows == 3, "root queue rows 3 after setLibrary")
    p10Check(root.queueVC.isEmpty == false, "queue not empty")
    // Move via engine, verify root queue reflects
    eng.moveQueueItem(from: 0, to: 2)
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    p10Check(root.queueVC.numberOfRows == 3, "still 3 after move")
    // Second toggle -> still headless guard not crash
    root.toggleQueue(anchoredTo: nil)
    p10Check(!root.isQueueVisible, "headless second toggle not visible")
    p10Check(root.playerBar.queueButton.image != nil, "queue button has image")
}

// MARK: - 3. No second clock / no Timer / no WebView
func testP10NoSecondClockNoTimerNoWebView() {
    print("\n--- P10: no second clock ---")
    // Grep source for forbidden patterns in Queue file
    let forbidden = ["Timer(", "CADisplayLink", "WKWebView", "HTMLAudioElement", "addPeriodicTimeObserver"]
    let fm = FileManager.default
    let url = URL(fileURLWithPath: "App/Sources/Quaver/UI/QueuePopoverViewController.swift")
    guard let src = try? String(contentsOf: url) else {
        p10Check(false, "could not read QueuePopoverViewController.swift")
        return
    }
    for pat in forbidden {
        let has = src.contains(pat)
        p10Check(!has, "QueuePopover must not contain \(pat)")
    }
    // PlaybackEngine still sole clock, queue mutation does not create timer
    p10Check(!src.contains("DispatchSourceTimer"), "no DispatchSourceTimer")
    // Verify only NativePlaybackEngine has periodic observer
    if let engSrc = try? String(contentsOf: URL(fileURLWithPath: "App/Sources/Quaver/Playback/NativePlaybackEngine.swift")) {
        let cnt = engSrc.components(separatedBy: "addPeriodicTimeObserver").count - 1
        p10Check(cnt == 1, "exactly one periodic observer in NativePlaybackEngine (got \(cnt))")
    }
    if let qSrc = try? String(contentsOf: URL(fileURLWithPath: "App/Sources/Quaver/UI/QueuePopoverViewController.swift")) {
        p10Check(!qSrc.contains("AVPlayer"), "Queue must not create AVPlayer")
    }
    _ = fm // suppress warning
}

// MARK: - Runner (call from harness)
@MainActor
func runAllQueueTests() {
    testP10EngineQueueBasics()
    testP10EngineMove()
    testP10EngineNextRespectsQueue()
    testP10PopoverCreation()
    testP10PopoverEmptyState()
    testP10PopoverShowsQueue()
    testP10PopoverDrag()
    testP10PopoverDoubleClick()
    testP10PopoverLifecycle()
    testP10RootSplitIntegration()
    testP10NoSecondClockNoTimerNoWebView()
    print("\n--- P10 SUMMARY ---")
    if phase10Failures.isEmpty { print("P10: ALL_PASS (\(11) suites)") }
    else { print("P10: \(phase10Failures.count) FAILURES"); for f in phase10Failures { print("  - \(f)") } }
}
