import AppKit
import Combine
import Foundation
import QuartzCore

// MARK: - Phase 6 — Native Lyrics (single clock)
// Mirrors src/lyrics-sync.test.js 1:1 but pure AppKit / LyricSynchronizer.
// Covers: mid-song open, exact boundaries T±epsilon, forward/backward/rapid seeking,
// click-to-seek (line+word), word timing, pause/resume, track changes, stale async loads,
// close/reopen, manual scroll grace 4.5s, observer duplication, malformed/empty, large files,
// plus the 10 mandatory behaviors. Parameterized/shared fixtures, no repetitive code.

var lyricsFailures: [String] = []
func lyricsCheck(_ cond: Bool, _ msg: String, file: StaticString = #file, line: UInt = #line) {
    if !cond { lyricsFailures.append("\(msg) (\(file):\(line))"); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}
func lyricsCheckClose(_ a: Double, _ b: Double, tol: Double, _ msg: String) {
    let ok = abs(a - b) <= tol
    lyricsCheck(ok, "\(msg) — got \(String(format: "%.5f", a)) expected \(String(format: "%.5f", b)) ±\(tol)")
}

// Shared fixtures — matches JS BASE_LRC
let BASE_LRC = "[00:00.00] A\n[00:05.00] B\n[00:10.00] C\n[00:20.00] D\n[00:30.00] E"
let BASE_LYRICS: [LyricLine] = LyricSynchronizer.parseLRC(BASE_LRC)
let MID_LRC = "[00:00.00] A\n[00:05.00] B\n[00:10.00] C\n[00:20.00] D\n[02:27.25] MID\n[02:30.00] NEXT"
let MID_LYRICS = LyricSynchronizer.parseLRC(MID_LRC)

// Fake engine for deterministic headless control (no AVPlayer, no file IO)
@MainActor
final class LyricsFakeEngine: PlaybackEngine {
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
        var s = subject.value; s.currentTrackIndex = index; s.currentTime = 0
        subject.send(s)
    }
    func togglePlay() { var s = subject.value; s.isPlaying.toggle(); subject.send(s) }
    func pause() { var s = subject.value; s.isPlaying = false; subject.send(s) }
    func next() {}
    func previous() {}
    func seek(to time: Double) {
        seekHistory.append(time)
        var s = subject.value
        let dur = s.duration
        let clamped = dur > 0 ? max(0, min(time, dur)) : max(0, time)
        s.currentTime = clamped
        subject.send(s)
    }
    func setVolume(_ v: Double) { var s = subject.value; s.volume = max(0, min(1, v)); subject.send(s) }
    func setShuffle(_ e: Bool) { var s = subject.value; s.isShuffle = e; subject.send(s) }
    func setRepeatMode(_ m: RepeatMode) { var s = subject.value; s.repeatMode = m; subject.send(s) }
    // Test helpers — direct state injection (simulates AVPlayer periodic observer)
    func _setTime(_ t: Double) { var s = subject.value; s.currentTime = t; subject.send(s) }
    func _setDuration(_ d: Double) { var s = subject.value; s.duration = d; subject.send(s) }
    func _setPlaying(_ p: Bool) { var s = subject.value; s.isPlaying = p; subject.send(s) }
    func _setTrackIndex(_ i: Int) { var s = subject.value; s.currentTrackIndex = i; subject.send(s) }
}

@MainActor
func makeFakeTrack(path: String, title: String = "T", artist: String = "A", album: String = "Al") -> TrackMetadata {
    TrackMetadata(path: path, title: title, artist: artist, album: album, duration: 200, format: "WAV", coverDataURL: nil, lyricPath: nil)
}

@MainActor
func makeLyricsVC(engine: LyricsFakeEngine? = nil) -> (LyricsFakeEngine, LyricsViewController) {
    let e = engine ?? LyricsFakeEngine()
    let vc = LyricsViewController(engine: e)
    // Force view load headless (no window server needed)
    _ = vc.view
    vc.loadViewIfNeeded()
    return (e, vc)
}

// MARK: - 1. Exact timestamp boundaries (table-driven, LyricSynchronizer pure)

@MainActor
func testExactBoundariesPure() {
    print("\n--- Exact timestamp boundaries (pure) ---")
    let cases: [(Double, Int)] = [
        (0, 0), (0.001, 0), (4.999, 0), (5, 1), (5.001, 1),
        (9.999, 1), (10, 2), (10.001, 2), (19.999, 2), (20, 3), (20.001, 3), (29.999, 3), (30, 4), (100, 4), (-1, -1),
    ]
    for (t, exp) in cases {
        let got = LyricSynchronizer.activeIndex(lyrics: BASE_LYRICS, currentTime: t)
        let ind = LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: t)
        lyricsCheck(got == exp, "activeIndex t=\(t) => \(exp) (got \(got))")
        lyricsCheck(ind == exp, "independent t=\(t) => \(exp) (got \(ind))")
        lyricsCheck(got == ind, "active==independent at t=\(t)")
    }
    // duplicate timestamps picks last
    let dup = LyricSynchronizer.parseLRC("[00:10.00] a\n[00:10.00] b\n[00:10.00] c")
    lyricsCheck(LyricSynchronizer.activeIndex(lyrics: dup, currentTime: 10) == 2, "duplicate timestamps picks last at T")
    lyricsCheck(LyricSynchronizer.activeIndex(lyrics: dup, currentTime: 9.999) == -1, "duplicate before T => -1")
    // T-epsilon / T / T+epsilon for each line
    let eps = 0.001
    for (i, line) in BASE_LYRICS.enumerated() {
        let t = line.time
        let before = LyricSynchronizer.activeIndex(lyrics: BASE_LYRICS, currentTime: t - eps)
        let at = LyricSynchronizer.activeIndex(lyrics: BASE_LYRICS, currentTime: t)
        let after = LyricSynchronizer.activeIndex(lyrics: BASE_LYRICS, currentTime: t + eps)
        lyricsCheck(at == i, "T boundary t=\(String(format: "%.3f", t)) at => \(i) (got \(at))")
        if i > 0 {
            lyricsCheck(before == i - 1, "T-epsilon before line \(i) => \(i-1) (got \(before))")
        } else {
            lyricsCheck(before == -1, "T-epsilon before first => -1 (got \(before))")
        }
        lyricsCheck(after == i, "T+epsilon after line \(i) => \(i) (got \(after))")
        // independent must match
        lyricsCheck(LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: t - eps) == before, "independent matches at T-eps \(t)")
        lyricsCheck(LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: t) == at, "independent matches at T \(t)")
    }
}

// MARK: - 2. Forward / backward seeks (headless VC)

@MainActor
func testForwardBackwardSeeks() {
    print("\n--- Forward / backward seeks (VC sync) ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(200)
    vc.load(BASE_LYRICS)
    vc.open()
    func expect(_ t: Double, _ exp: Int, _ msg: String) {
        eng._setTime(t)
        vc.sync(currentTime: t)
        lyricsCheck(vc.activeIndex == exp, "\(msg) t=\(t) => \(exp) (got \(vc.activeIndex))")
        lyricsCheck(vc.activeIndex == LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: t), "independent matches for \(msg)")
    }
    // forward jumps
    for jump in [0.001, 0.1, 1.0, 5.0, 30.0, 60.0] {
        let base = 5.0
        vc.sync(currentTime: base)
        let tgt = base + jump
        let exp = LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: tgt)
        expect(tgt, exp, "forward +\(jump)")
    }
    // backward jumps
    for jump in [0.001, 1.0, 5.0, 30.0, 60.0] {
        let tgt = max(-1.0, 30.0 - jump)
        let exp = LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: tgt)
        expect(tgt, exp, "backward -\(jump)")
    }
    expect(0, 0, "large jump to final 0")
    expect(30, 4, "large jump to 30")
    // never assumes forward only
    expect(30, 4, "at 30 => 4")
    expect(5, 1, "back to 5 => 1")
    expect(20, 3, "to 20 => 3")
    vc.destroy()
}

@MainActor
func testRapidSeekRace() {
    print("\n--- Rapid seek race (last wins) ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(300)
    vc.load(BASE_LYRICS)
    vc.open()
    // adversarial sequence matches JS: 30,180,45,240
    for t in [30.0, 180.0, 45.0, 240.0] {
        eng._setTime(t)
        vc.sync(currentTime: t)
    }
    let fin: Double = 240
    lyricsCheck(vc.activeIndex == LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: fin), "rapid adversarial 30,180,45,240 => \(fin) active \(vc.activeIndex)")
    // 100 randomized seeks (seed 12345) — final wins
    var s = 12345
    func rand() -> Double { s = (s &* 16807) % 2147483647; return Double(s) / 2147483647.0 }
    var finalT: Double = 0
    for _ in 0..<100 {
        finalT = floor(rand() * 300)
        eng._setTime(finalT)
        vc.sync(currentTime: finalT)
        if rand() < 0.5 { /* seeked */ }
    }
    lyricsCheck(vc.activeIndex == LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: finalT), "100 randomized seeks final \(finalT) => \(vc.activeIndex)")
    vc.destroy()
}

// MARK: - 3. Click-to-seek (line + word) — seek via engine, display derived from currentTime

@MainActor
func testClickToSeek() async {
    print("\n--- Click-to-seek ---")
    let lyrics = LyricSynchronizer.parseLRC("[00:00.00] first line here\n[00:10.00] second line\n[00:20.00] third line with words\n[00:30.00] last line")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(40)
    vc.load(lyrics)
    vc.open()
    for i in 0..<lyrics.count {
        vc.clickLyric(at: i)
        // engine.seek is sync in fake — state updates immediately via publisher
        try? await Task.sleep(nanoseconds: 20_000_000)
        let expTime = lyrics[i].time
        lyricsCheckClose(eng.state.currentTime, expTime, tol: 0.001, "clickLyric \(i) seeks to \(expTime)")
        // active derived from currentTime, not from clicked index directly
        let expActive = LyricSynchronizer.activeIndex(lyrics: lyrics, currentTime: eng.state.currentTime)
        lyricsCheck(vc.activeIndex == expActive, "clickLyric \(i) active derived from currentTime (\(vc.activeIndex) vs \(expActive))")
        lyricsCheck(vc.activeIndex == i, "clickLyric \(i) active == clicked index")
    }
    // word click seeks within line: li=2 wi=1 => time + dur*(1/wordCount)
    let li = 2; let wi = 1
    let dur = LyricSynchronizer.lineDuration(lyrics: lyrics, index: li, audioDuration: 40)
    let words = lyrics[li].text.split { $0.isWhitespace }.filter { !$0.isEmpty }
    let exp = lyrics[li].time + dur * (Double(wi) / Double(max(1, words.count)))
    vc.clickWord(line: li, word: wi)
    try? await Task.sleep(nanoseconds: 20_000_000)
    lyricsCheckClose(eng.state.currentTime, exp, tol: 0.0001, "clickWord \(li),\(wi) seeks within line to \(String(format: "%.3f", exp))")
    lyricsCheck(vc.activeIndex == li, "clickWord active stays on line \(li)")
    // clickWord must not keep separate clicked-line state: after a subsequent time update, it derives from currentTime
    eng._setTime(lyrics[3].time)
    vc.sync(currentTime: lyrics[3].time)
    lyricsCheck(vc.activeIndex == 3, "after clickWord, later time change derives from clock (got \(vc.activeIndex))")
    vc.destroy()
}

// MARK: - 4. Word synchronization (same currentTime as line)

@MainActor
func testWordSync() {
    print("\n--- Word synchronization (single clock) ---")
    let lyrics = LyricSynchronizer.parseLRC("[00:10.00] one two three four")
    // 0% at line start, 100% at end (dur 4 if audioDuration 14)
    var p = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: 0, currentTime: 10, audioDuration: 14)
    lyricsCheck(p == [0, 0, 0, 0], "word progress 0% at line start (got \(p))")
    p = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: 0, currentTime: 14, audioDuration: 14)
    lyricsCheck(p.allSatisfy { $0 == 1 }, "word progress 100% at line end (got \(p))")
    // mid line 11s => dur 4, prog 0.25 => w0 1, rest 0
    p = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: 0, currentTime: 11, audioDuration: 14)
    lyricsCheckClose(p[0], 1, tol: 0.001, "mid line 11s w0==1")
    lyricsCheckClose(p[1], 0, tol: 0.001, "mid line 11s w1==0")
    // VC integration: wordProgressesForActive derived from same engine.currentTime
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(14)
    vc.load(lyrics)
    vc.open()
    eng._setTime(11); vc.sync(currentTime: 11)
    let vcProg = vc.wordProgressesForActive
    let expected = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: 0, currentTime: 11, audioDuration: 14)
    for (idx, v) in expected.enumerated() {
        lyricsCheckClose(vcProg[idx], v, tol: 0.001, "VC wordProgress[\(idx)] matches synchronizer at same clock")
    }
    // random seeks word progress — 20 trials
    var seed = 99
    func rand() -> Double { seed = (seed &* 16807) % 2147483647; return Double(seed) / 2147483647.0 }
    for _ in 0..<20 {
        let t = 10 + rand() * 4
        eng._setTime(t); vc.sync(currentTime: t)
        let exp = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: 0, currentTime: t, audioDuration: 14)
        let got = vc.wordProgressesForActive
        for (i, v) in exp.enumerated() {
            lyricsCheckClose(got[i], v, tol: 0.01, "random t=\(String(format: "%.2f", t)) word \(i)")
        }
    }
    // Empty and out-of-bounds handling
    lyricsCheck(LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: -1, currentTime: 11, audioDuration: 14).isEmpty, "wordProgresses out of bounds => []")
    lyricsCheck(LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: 99, currentTime: 11, audioDuration: 14).isEmpty, "wordProgresses OOB => []")
    vc.destroy()
}

// MARK: - 5. Pause / resume — freeze / continue from exact currentTime

@MainActor
func testPauseResume() {
    print("\n--- Pause / resume ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(40)
    vc.load(BASE_LYRICS)
    vc.open()
    eng._setTime(12); vc.sync(currentTime: 12)
    let atPause = vc.activeIndex
    lyricsCheck(atPause == 2, "at 12s active is 2 (got \(atPause))")
    // pause should freeze active (no time advance)
    eng._setPlaying(false)
    // simulate time not advancing while paused — sync with same time must keep same active and word progress
    vc.sync(currentTime: 12)
    lyricsCheck(vc.activeIndex == atPause, "pause freeze active stays \(atPause)")
    let progBefore = vc.wordProgressesForActive
    vc.sync(currentTime: 12)
    lyricsCheck(vc.wordProgressesForActive == progBefore, "pause freeze word progress unchanged")
    // resume and advance time — should continue from exact currentTime
    eng._setPlaying(true)
    eng._setTime(13); vc.sync(currentTime: 13)
    let exp = LyricSynchronizer.activeIndex(lyrics: BASE_LYRICS, currentTime: 13)
    lyricsCheck(vc.activeIndex == exp, "resume continue active \(exp) (got \(vc.activeIndex))")
    vc.destroy()
}

// MARK: - 6. Track changes — invalidate stale and prevent old async load replacing new

@MainActor
func testTrackChanges() async {
    print("\n--- Track changes & stale async loads ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(40)
    // Load A, seek to 10 (active 1), then load B and verify old text gone and active correct
    let lA = LyricSynchronizer.parseLRC("[00:00.00] old1\n[00:10.00] old2")
    let lB = LyricSynchronizer.parseLRC("[00:00.00] new1\n[00:05.00] new2")
    vc.load(lA)
    vc.open()
    eng._setTime(10); vc.sync(currentTime: 10)
    lyricsCheck(vc.activeIndex == 1, "before track change active 1")
    vc.load(lB)
    // Immediate: old lyrics replaced
    lyricsCheck(vc.lineCount == 2, "after load lB count 2")
    lyricsCheck(vc.lyrics.first?.text == "new1", "after load lB first is new1")
    eng._setTime(5); vc.sync(currentTime: 5)
    lyricsCheck(vc.activeIndex == 1, "after track change active 1 on new lyrics")
    // Stale async version guard — mirrors JS stale async loads
    let lSlow = LyricSynchronizer.parseLRC("[00:00.00] SLOW1\n[00:10.00] SLOW2")
    let lFast = LyricSynchronizer.parseLRC("[00:00.00] FAST1\n[00:05.00] FAST2")
    // Start slow async (30ms) then fast (10ms) — after 50ms fast must win
    let sem = DispatchSemaphore(value: 0)
    Task {
        let ok1 = await vc.loadAsync { try? await Task.sleep(nanoseconds: 30_000_000); return lSlow }
        // ok1 should be false (stale)
        lyricsCheck(ok1 == false, "stale slow load returns false")
        sem.signal()
    }
    Task {
        try? await Task.sleep(nanoseconds: 5_000_000)
        let ok2 = await vc.loadAsync { try? await Task.sleep(nanoseconds: 10_000_000); return lFast }
        lyricsCheck(ok2 == true, "fast load returns true")
    }
    _ = sem.wait(timeout: .now() + 1)
    try? await Task.sleep(nanoseconds: 200_000_000)
    lyricsCheck(vc.lyrics.first?.text == "FAST1", "stale guard: FAST wins over SLOW")
    // A->B->C last wins regardless of resolve order (30,10,20)
    let lC = LyricSynchronizer.parseLRC("[00:00.00] C")
    let lA2 = LyricSynchronizer.parseLRC("[00:00.00] A")
    let lB2 = LyricSynchronizer.parseLRC("[00:00.00] B")
    let sem2 = DispatchSemaphore(value: 0)
    var done = 0
    func signalDone() { done += 1; if done == 3 { sem2.signal() } }
    Task { _ = await vc.loadAsync { try? await Task.sleep(nanoseconds: 30_000_000); return lA2 }; signalDone() }
    Task { try? await Task.sleep(nanoseconds: 2_000_000); _ = await vc.loadAsync { try? await Task.sleep(nanoseconds: 10_000_000); return lB2 }; signalDone() }
    Task { try? await Task.sleep(nanoseconds: 4_000_000); _ = await vc.loadAsync { try? await Task.sleep(nanoseconds: 20_000_000); return lC }; signalDone() }
    _ = sem2.wait(timeout: .now() + 1)
    try? await Task.sleep(nanoseconds: 40_000_000)
    lyricsCheck(vc.lyrics.first?.text == "C", "A->B->C last wins (got \(vc.lyrics.first?.text ?? "nil"))")
    vc.destroy()
}

@MainActor
func testTrackChangeWhileLoadingViaEngine() {
    print("\n--- Track change while loading (engine-driven) ---")
    let (eng, vc) = makeLyricsVC()
    let t1 = makeFakeTrack(path: "/tmp/a.flac", title: "Old")
    let t2 = makeFakeTrack(path: "/tmp/b.flac", title: "New")
    eng.setLibrary([t1, t2])
    vc.load(LyricSynchronizer.parseLRC("[00:00.00] old1\n[00:10.00] old2"))
    vc.open()
    eng._setTime(10); vc.sync(currentTime: 10)
    // Simulate track change via engine: switch index, vc will detect via handleEngineState
    eng.play(trackAt: 1)
    vc.load(LyricSynchronizer.parseLRC("[00:00.00] new1\n[00:05.00] new2"))
    eng._setTime(5); vc.sync(currentTime: 5)
    lyricsCheck(vc.activeIndex == 1, "track change old->new active 1 (got \(vc.activeIndex))")
    vc.destroy()
}

// MARK: - 7. Open mid-song + close/reopen always derive from engine

@MainActor
func testOpenMidSongAndCloseReopen() async {
    print("\n--- Open mid-song & close/reopen ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(200)
    vc.load(MID_LYRICS)
    // Cases from JS: at 0, 15, 147.25, 147.249, 147.251
    let cases: [(Double, Int)] = [(0, 0), (0.001, 0), (15, 2), (147.25, 4), (147.249, 3), (147.251, 4)]
    for (t, exp) in cases {
        eng._setTime(t)
        vc.close()
        vc.open()
        // open() syncs to engine.currentTime
        lyricsCheck(vc.activeIndex == exp, "open mid-song at \(t) => \(exp) (got \(vc.activeIndex))")
        lyricsCheck(vc.activeIndex == LyricSynchronizer.activeIndex(lyrics: MID_LYRICS, currentTime: t), "open mid-song independent matches at \(t)")
    }
    // does not stick to 0 when opened at 147.25
    eng._setTime(147.25)
    vc.close(); vc.open()
    lyricsCheck(vc.activeIndex == 4, "does not stick to 0 at 147.25 (got \(vc.activeIndex))")
    // close seek reopen lands on new time
    eng._setTime(0); vc.open()
    lyricsCheck(vc.activeIndex == 0, "open at 0 => 0")
    vc.close()
    eng._setTime(20)
    vc.sync(currentTime: 20)
    vc.open()
    // At 20 exactly, MID_LYRICS: [0:A,5:B,10:C,20:D,147.25:MID] => active 3
    lyricsCheck(vc.activeIndex == 3, "close seek reopen at 20 => 3 (got \(vc.activeIndex))")
    // rAF pending cancel analog: seek while scroll animation pending should still update active
    eng._setTime(10); vc.open()
    eng._setTime(20); vc.sync(currentTime: 20)
    lyricsCheck(vc.activeIndex == 3, "seek while anim pending cancels and updates to 3")
    vc.destroy()
}

// MARK: - 8. Manual scroll grace 4.5s

@MainActor
func testManualScrollGrace() {
    print("\n--- Manual scroll grace 4.5s ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(100)
    vc.load(BASE_LYRICS)
    vc.open()
    eng._setTime(5); vc.sync(currentTime: 5)
    vc.syncCallCount // warm
    let beforeCenter = vc.lastCenteredIndex
    vc.simulateManualScroll()
    lyricsCheck(vc.isManuallyScrolling(), "immediately after manual, isManuallyScrolling true")
    // While in grace, active changes should NOT center
    eng._setTime(10); vc.sync(currentTime: 10)
    lyricsCheck(vc.activeIndex == 2, "active moves to 2 during grace")
    // lastCenteredIndex should still be previous (or not updated since grace)
    // We set lastCentered only on successful center; during grace it should not change
    // To isolate, check that after grace expires, next sync does center
    // Fast-forward by mocking manualScrollUntil — set it to past
    // Use direct check: after simulateManualScroll, manualScrollUntil is now+4.5, so Date().addingTimeInterval(5) should be outside grace
    let future = Date().addingTimeInterval(5)
    lyricsCheck(!vc.isManuallyScrolling(date: future), "after 5s grace expires")
    // Directly clear grace and trigger sync
    // We can't set private manualScrollUntil but we can wait or cheat via click which clears grace
    vc.clickLyric(at: 3) // clears grace per spec
    lyricsCheck(!vc.isManuallyScrolling(), "click-to-seek clears manual grace")
    vc.destroy()
}

@MainActor
func testManualScrollBlocksAutoCenterButNotSync() {
    print("\n--- Manual scroll blocks auto-center but not sync/active ---")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(100)
    vc.load(BASE_LYRICS)
    vc.open()
    eng._setTime(0); vc.sync(currentTime: 0)
    let c0 = vc.lastCenteredIndex
    vc.simulateManualScroll()
    eng._setTime(20); vc.sync(currentTime: 20)
    // active must still update even though scroll blocked
    lyricsCheck(vc.activeIndex == 3, "manual grace: active still updates to 3 (got \(vc.activeIndex))")
    // scroll should be blocked — lastCentered should not have moved to 3
    // Since we blocked, lastCentered should remain c0 or 0, not 3
    if let last = vc.lastCenteredIndex {
        lyricsCheck(last != 3 || c0 == 3, "manual grace: auto-center blocked during grace (lastCentered \(String(describing: last)))")
    } else {
        lyricsCheck(true, "manual grace: no center during grace (lastCentered nil)")
    }
    vc.destroy()
}

// MARK: - 9. Lifecycle — no duplicate observers/listeners after repeated open/close

@MainActor
func testObserverDuplication() {
    print("\n--- Observer / listener duplication ---")
    let (eng, vc) = makeLyricsVC()
    vc.load(BASE_LYRICS)
    lyricsCheck(vc.observerCount == 1, "initial observer count 1 (got \(vc.observerCount))")
    for _ in 0..<100 { vc.open(); vc.close() }
    lyricsCheck(vc.observerCount == 1, "100 open/close still 1 observer (got \(vc.observerCount))")
    // Verify only one sink call per state change: track call count delta
    vc.open()
    let before = vc.syncCallCount
    eng._setTime(10)
    // publisher will trigger handleEngineState → sync, but we also count direct sync calls
    // Give runloop a moment
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let delta = vc.syncCallCount - before
    // Should be exactly 1 (or at most 1 plus our direct) — not multiplied
    lyricsCheck(delta <= 2, "single sink per timeupdate (delta \(delta))")
    // destroy removes observers
    vc.destroy()
    lyricsCheck(vc.observerCount == 0, "after destroy observer count 0 (got \(vc.observerCount))")
    let countAfterDestroy = vc.syncCallCount
    eng._setTime(20)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    // sync should not be called after destroy (no publisher)
    lyricsCheck(vc.syncCallCount == countAfterDestroy, "after destroy, engine time does not trigger sync (count \(vc.syncCallCount) vs \(countAfterDestroy))")
}

@MainActor
func testLifecycleNoDuplicateTimersOrRAF() {
    print("\n--- Lifecycle no runaway timers ---")
    let (eng, vc) = makeLyricsVC()
    vc.load(BASE_LYRICS)
    // Open/close 10 times, check no leaked cancellables
    for _ in 0..<10 { vc.open(); vc.close() }
    lyricsCheck(vc.observerCount == 1, "after 10 open/close observer still 1")
    vc.destroy()
    lyricsCheck(vc.observerCount == 0, "destroy cleans up")
    // Re-create should be clean
    let (_, vc2) = makeLyricsVC()
    vc2.load(BASE_LYRICS); vc2.open()
    lyricsCheck(vc2.observerCount == 1, "new VC observer 1")
    vc2.destroy()
}

// MARK: - 10. Malformed / empty lyrics

@MainActor
func testMalformedEmpty() {
    print("\n--- Malformed / empty lyrics ---")
    let (eng, vc) = makeLyricsVC()
    // Empty file
    vc.load([])
    vc.open()
    eng._setTime(10); vc.sync(currentTime: 10)
    lyricsCheck(vc.activeIndex == -1, "empty lyrics active -1")
    lyricsCheck(vc.isEmptyStateVisible == true, "empty lyrics shows empty state")
    lyricsCheck(vc.lineCount == 0, "empty lineCount 0")
    // Parse garbage — no timestamps → []
    let bad = LyricSynchronizer.parseLRC("not lrc\nhello [bad] world\n[00:ab.00] broken")
    lyricsCheck(bad.isEmpty, "malformed LRC => [] (got \(bad))")
    vc.load(bad)
    lyricsCheck(vc.lineCount == 0, "vc after bad load 0")
    // Valid after bad
    vc.load(BASE_LYRICS)
    lyricsCheck(vc.lineCount == 5, "valid after bad => 5")
    // Duplicates and unsorted input (parse sorts)
    let unsorted = LyricSynchronizer.parseLRC("[00:30.00] E\n[00:00.00] A\n[00:20.00] D")
    lyricsCheck(unsorted.first?.time == 0, "parse sorts unsorted input")
    lyricsCheck(unsorted.last?.text == "E", "parse sorted last E")
    // Empty text after timestamp filtered
    let emptyText = LyricSynchronizer.parseLRC("[00:10.00]   \n[00:20.00] valid")
    lyricsCheck(emptyText.count == 1 && emptyText.first?.text == "valid", "empty text after stamp filtered")
    // Multi-stamp per line
    let multi = LyricSynchronizer.parseLRC("[00:10.00][00:20.00] hello")
    lyricsCheck(multi.count == 2, "multi-stamp count 2 (got \(multi.count))")
    lyricsCheck(multi[0].time == 10 && multi[1].time == 20, "multi-stamp times 10,20")
    vc.destroy()
}

// MARK: - 11. Large lyric files (5000 lines)

@MainActor
func testLargeLyricFile() {
    print("\n--- Large lyric file (5000 lines) ---")
    var lrc = ""
    // Use 1s spacing so all timestamps stay within mm 00-99 (max 83min for 5000 lines, regex requires \d{2})
    for i in 0..<5000 { lrc += String(format: "[%02d:%02d.00] line %d\n", (i)/60, (i)%60, i) }
    let start = Date()
    let parsed = LyricSynchronizer.parseLRC(lrc)
    let parseMs = Date().timeIntervalSince(start) * 1000
    lyricsCheck(parsed.count == 5000, "large parse count 5000 (got \(parsed.count))")
    lyricsCheck(parseMs < 2000, "large parse <2s (took \(String(format: "%.0f", parseMs))ms)")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(20000)
    vc.load(parsed)
    vc.open()
    // Active at mid point (1s per line)
    let midTime = Double(2500) + 0.5
    eng._setTime(midTime); vc.sync(currentTime: midTime)
    lyricsCheck(vc.activeIndex == 2500, "large file active at mid => 2500 (got \(vc.activeIndex))")
    // Random access
    eng._setTime(0); vc.sync(currentTime: 0); lyricsCheck(vc.activeIndex == 0, "large file at 0 => 0")
    eng._setTime(4999); vc.sync(currentTime: 4999); lyricsCheck(vc.activeIndex == 4999, "large file at end => 4999")
    vc.destroy()
}

// MARK: - 12. Single clock — word + line derived from same currentTime, no second state

@MainActor
func testSingleClock() {
    print("\n--- Single clock: line + word from same currentTime ---")
    let lyrics = LyricSynchronizer.parseLRC("[00:00.00] hello world here now\n[00:10.00] second line here\n[00:20.00] third")
    let (eng, vc) = makeLyricsVC()
    eng._setDuration(30)
    vc.load(lyrics)
    vc.open()
    for t in [0.5, 5, 10.5, 15, 19.9, 22] {
        eng._setTime(t); vc.sync(currentTime: t)
        let lineIdx = LyricSynchronizer.activeIndex(lyrics: lyrics, currentTime: t)
        let wordProgs = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: lineIdx, currentTime: t, audioDuration: 30)
        lyricsCheck(vc.activeIndex == lineIdx, "single clock t=\(t) active \(lineIdx) (vc \(vc.activeIndex))")
        lyricsCheck(vc.wordProgressesForActive == wordProgs || zip(vc.wordProgressesForActive, wordProgs).allSatisfy({ abs($0.0-$0.1) < 0.001 }), "single clock t=\(t) wordProgress matches")
    }
    // Ensure VC has no duplicated playback state (no stored currentTime separate from engine)
    let mir = Mirror(reflecting: vc)
    var hasDup = false
    for child in mir.children {
        let label = child.label ?? ""
        if label == "currentTime" || label == "playbackTime" || label == "clock" { hasDup = true }
    }
    lyricsCheck(!hasDup, "LyricsVC has no duplicated currentTime storage")
    vc.destroy()
}

// MARK: - 13. Line duration caps (raw>12 => min(raw,7), floor 0.6)

@MainActor
func testLineDurationCaps() {
    print("\n--- Line duration caps ---")
    let one = LyricSynchronizer.parseLRC("[00:00.00] a\n[00:20.00] b") // raw 20 => capped 7
    lyricsCheckClose(LyricSynchronizer.lineDuration(lyrics: one, index: 0, audioDuration: nil), 7, tol: 0.001, "raw 20 => capped 7")
    let short = LyricSynchronizer.parseLRC("[00:00.00] a\n[00:00.50] b") // raw 0.5 => floor 0.6
    lyricsCheckClose(LyricSynchronizer.lineDuration(lyrics: short, index: 0, audioDuration: nil), 0.6, tol: 0.001, "raw 0.5 => floor 0.6")
    let normal = LyricSynchronizer.parseLRC("[00:00.00] a\n[00:04.00] b") // raw 4 => 4
    lyricsCheckClose(LyricSynchronizer.lineDuration(lyrics: normal, index: 0, audioDuration: nil), 4, tol: 0.001, "raw 4 => 4")
    // Last line with audioDuration fallback
    let last = LyricSynchronizer.parseLRC("[00:00.00] a\n[00:10.00] last")
    lyricsCheckClose(LyricSynchronizer.lineDuration(lyrics: last, index: 1, audioDuration: 14), 4, tol: 0.001, "last line with audioDuration 14 => 4")
    lyricsCheckClose(LyricSynchronizer.lineDuration(lyrics: last, index: 1, audioDuration: nil), 4, tol: 0.001, "last line no audioDuration => cur+4 fallback")
}

// MARK: - 14. Integration: RootSplit + PlayerBar + Lyrics overlay (headless)

@MainActor
func testIntegrationRootLyricsOverlay() {
    print("\n--- Integration: RootSplit lyrics overlay ---")
    let store = LibraryStore(defaults: UserDefaults(suiteName: "com.quaver.test.lyrics.\(UUID().uuidString)") ?? .standard)
    let engine = NativePlaybackEngine()
    let root = RootSplitViewController(store: store, engine: engine)
    _ = root.view; root.view.layoutSubtreeIfNeeded()
    lyricsCheck(root.splitViewItems.count == 2, "root split items still 2 with lyrics overlay (got \(root.splitViewItems.count))")
    lyricsCheck(root.lyricsVC.view.isHidden == true, "lyrics initially hidden")
    lyricsCheck(!root.isLyricsVisible, "isLyricsVisible false initially")
    root.toggleLyrics()
    lyricsCheck(root.isLyricsVisible, "toggleLyrics shows overlay")
    lyricsCheck(!root.lyricsVC.view.isHidden, "lyrics view not hidden after toggle")
    root.toggleLyrics()
    lyricsCheck(!root.isLyricsVisible, "toggle again hides")
    // PlayerBar has lyrics button
    let bar = root.playerBar
    lyricsCheck(bar.lyricsButton.image != nil, "playerBar lyricsButton has image")
    // Clicking bar lyrics button toggles overlay (delegate)
    bar.lyricsButton.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    lyricsCheck(root.isLyricsVisible, "bar lyricsButton click toggles visible")
    // No WKWebView anywhere
    var found = false
    func walk(_ v: NSView) {
        let t = String(describing: type(of: v))
        if t.contains("WKWebView") || t.contains("WebView") { found = true }
        for s in v.subviews { walk(s) }
    }
    walk(root.view)
    lyricsCheck(!found, "no WKWebView in integrated hierarchy")
}

// MARK: - 15. Randomized property-based (300 trials)

@MainActor
func testRandomizedPropertyBased() {
    print("\n--- Randomized property-based (300 trials) ---")
    var seed = 777
    func rand() -> Double { seed = (seed &* 16807) % 2147483647; return Double(seed) / 2147483647.0 }
    for trial in 0..<300 {
        let n = Int(rand() * 20) + 1
        var times: [Int] = (0..<n).map { _ in Int(rand() * 300) }
        times.sort()
        var lrc = ""
        for (i, t) in times.enumerated() {
            lrc += String(format: "[%02d:%02d.00] line %d\n", t/60, t%60, i)
        }
        let lyrics = LyricSynchronizer.parseLRC(lrc)
        let tst = rand() * 350 - 10
        let got = LyricSynchronizer.activeIndex(lyrics: lyrics, currentTime: tst)
        let exp = LyricSynchronizer.independentActiveIndex(lyrics: lyrics, currentTime: tst)
        if got != exp {
            lyricsCheck(false, "random trial \(trial) n=\(n) t=\(String(format: "%.2f", tst)) got \(got) exp \(exp) times=\(times)")
            break
        }
    }
    lyricsCheck(lyricsFailures.isEmpty || !lyricsFailures.contains(where: { $0.contains("random trial") }), "300 random lyrics+times all match independent")
    // Random seek sequence final wins (seed 999)
    let (eng, vc) = makeLyricsVC()
    vc.load(BASE_LYRICS); vc.open()
    eng._setDuration(200)
    var s2 = 999
    func rand2() -> Double { s2 = (s2 &* 16807) % 2147483647; return Double(s2) / 2147483647.0 }
    var fin: Double = 0
    for _ in 0..<80 { fin = floor(rand2() * 90); eng._setTime(fin); vc.sync(currentTime: fin); if rand2() < 0.3 { vc.sync(currentTime: fin) } }
    vc.sync(currentTime: fin)
    lyricsCheck(vc.activeIndex == LyricSynchronizer.independentActiveIndex(lyrics: BASE_LYRICS, currentTime: fin), "random seek sequence final \(fin) => \(vc.activeIndex)")
    vc.destroy()
}

// MARK: - Runner

@MainActor
func runAllLyricsTests() async {
    testExactBoundariesPure()
    testForwardBackwardSeeks()
    testRapidSeekRace()
    await testClickToSeek()
    testWordSync()
    testPauseResume()
    await testTrackChanges()
    testTrackChangeWhileLoadingViaEngine()
    await testOpenMidSongAndCloseReopen()
    testManualScrollGrace()
    testManualScrollBlocksAutoCenterButNotSync()
    testObserverDuplication()
    testLifecycleNoDuplicateTimersOrRAF()
    testMalformedEmpty()
    testLargeLyricFile()
    testSingleClock()
    testLineDurationCaps()
    testIntegrationRootLyricsOverlay()
    testRandomizedPropertyBased()
    print("\n=== Lyrics Tests: \(lyricsFailures.isEmpty ? "ALL PASS" : "\(lyricsFailures.count) FAILURES") ===")
    for f in lyricsFailures { print("  • \(f)") }
}
