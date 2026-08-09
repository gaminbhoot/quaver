import Foundation
import AppKit

// This file is compiled together with QuaverCore.swift + LibraryStore.swift + LyricSynchronizer.swift
// and linked against libquaver_core.a to verify the Swift ↔ Rust boundary end-to-end.
// Run: swiftc ... /tmp/quaver_boundary_main.swift App/Sources/... -o /tmp/quaver_boundary_tests && /tmp/quaver_boundary_tests

var failures: [String] = []
func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond { failures.append("\(msg)  (\(file):\(line))"); print("FAIL: \(msg)") }
    else { print("PASS: \(msg)") }
}
func checkEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String) {
    check(a == b, "\(msg) — got \(a) expected \(b)")
}

// ---------------------------------------------------------------------------
// 1. TrackMetadata.key (identity — must match JS trackKey exactly)
// ---------------------------------------------------------------------------
func testTrackKey() {
    let t1 = TrackMetadata(path: "/a/b.flac", title: "t", artist: "a", album: "b", duration: 1, format: "FLAC", coverDataURL: nil, lyricPath: nil)
    checkEqual(t1.key, "/a/b.flac", "trackKey uses path when present")
    let t2 = TrackMetadata(path: "", title: "Hello", artist: "Alice", album: "World", duration: 1, format: "MP3", coverDataURL: nil, lyricPath: nil)
    checkEqual(t2.key, "Hello|Alice|World", "trackKey falls back to title|artist|album")
    let t3 = TrackMetadata(path: "", title: "", artist: "", album: "", duration: 0, format: "", coverDataURL: nil, lyricPath: nil)
    checkEqual(t3.key, "||", "trackKey empty fields still produce ||")
}

// ---------------------------------------------------------------------------
// 2. LibraryStore persistence — isolated UserDefaults suite
// ---------------------------------------------------------------------------
@MainActor
func testLibraryStore() {
    let suite = "com.quaver.test.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)

    let store = LibraryStore(defaults: d)
    check(store.playlists.isEmpty, "fresh store has no playlists")
    check(store.likedTrackKeys.isEmpty, "fresh store has no liked")
    check(store.recentlyPlayed.isEmpty, "fresh store has no recently played")

    // Playlists round-trip
    let pl = store.createPlaylist(name: "  My Favs  ")
    checkEqual(pl.name, "My Favs", "createPlaylist trims name")
    check(!pl.id.isEmpty, "playlist id is UUID")
    store.addTrack("/a/b.flac", toPlaylist: pl.id)
    store.addTrack("/a/b.flac", toPlaylist: pl.id)
    checkEqual(store.playlists.first?.trackKeys.count, 1, "addTrack dedupes")

    // Liked round-trip — Set persisted as array
    store.toggleLike(trackKey: "/a/b.flac")
    check(store.likedTrackKeys.contains("/a/b.flac"), "toggleLike adds")
    store.toggleLike(trackKey: "/a/b.flac")
    check(!store.likedTrackKeys.contains("/a/b.flac"), "toggleLike removes")

    // Recently played MRU capped 50 — exercises exact JS slice(0,50)
    for i in 0..<55 {
        store.recordPlayed(trackKey: "/track/\(i).flac")
    }
    checkEqual(store.recentlyPlayed.count, 50, "recentlyPlayed capped at 50")
    checkEqual(store.recentlyPlayed.first?.key, "/track/54.flac", "recentlyPlayed MRU order")

    // Persistence survives store recreation
    let store2 = LibraryStore(defaults: d)
    checkEqual(store2.playlists.count, 1, "playlists survive reload")
    checkEqual(store2.playlists.first?.trackKeys, ["/a/b.flac"], "playlist trackKeys survive reload")
    checkEqual(store2.recentlyPlayed.count, 50, "recentlyPlayed survives reload")

    // Corrupt JSON falls back to []
    d.set("not json{{{", forKey: QuaverStoreKeys.playlists)
    let store3 = LibraryStore(defaults: d)
    check(store3.playlists.isEmpty, "corrupt playlists JSON falls back to []")

    // Migration — importLegacyContainer merges union, preserves shapes
    let legacyPlaylists = [QuaverPlaylist(id: "legacy-1", name: "Legacy", trackKeys: ["/x.flac"])]
    let legacyLiked = ["/y.flac"]
    let legacyRecent = [RecentlyPlayedEntry(key: "/z.flac", playedAt: 1234567890000)]
    let enc = JSONEncoder()
    var container: [String: Data] = [:]
    container[QuaverStoreKeys.playlists] = try! enc.encode(legacyPlaylists)
    container[QuaverStoreKeys.likedTracks] = try! enc.encode(legacyLiked)
    container[QuaverStoreKeys.recentlyPlayed] = try! enc.encode(legacyRecent)
    let d2 = UserDefaults(suiteName: "\(suite).migrate")!
    d2.removePersistentDomain(forName: "\(suite).migrate")
    let mStore = LibraryStore(defaults: d2)
    mStore.importLegacyContainer(container)
    check(mStore.playlists.contains(where: { $0.id == "legacy-1" }), "migration imports playlists")
    check(mStore.likedTrackKeys.contains("/y.flac"), "migration imports liked")
    check(mStore.recentlyPlayed.contains(where: { $0.key == "/z.flac" }), "migration imports recentlyPlayed")

    // Migration dedupes on second import
    mStore.importLegacyContainer(container)
    checkEqual(mStore.playlists.filter { $0.id == "legacy-1" }.count, 1, "migration dedupes playlists on re-import")

    d.removePersistentDomain(forName: suite)
    d2.removePersistentDomain(forName: "\(suite).migrate")
}

// ---------------------------------------------------------------------------
// 3. LibraryQueries pure filtering / sorting
// ---------------------------------------------------------------------------
@MainActor
func testLibraryQueries() {
    let suite = "com.quaver.test.queries.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    let store = LibraryStore(defaults: d)
    store.likedTrackKeys = ["/liked.flac"]
    store.recentlyPlayed = [RecentlyPlayedEntry(key: "/recent.flac", playedAt: Date().timeIntervalSince1970 * 1000)]

    let lib: [TrackMetadata] = [
        TrackMetadata(path: "/a.flac", title: "B", artist: "X", album: "A1", duration: 10, format: "FLAC", coverDataURL: nil, lyricPath: nil),
        TrackMetadata(path: "/b.mp3", title: "A", artist: "Y", album: "A2", duration: 10, format: "MP3", coverDataURL: nil, lyricPath: nil),
        TrackMetadata(path: "/liked.flac", title: "C", artist: "Z", album: "A3", duration: 10, format: "FLAC", coverDataURL: nil, lyricPath: nil),
        TrackMetadata(path: "/recent.flac", title: "D", artist: "W", album: "A4", duration: 10, format: "ALAC", coverDataURL: nil, lyricPath: nil),
    ]
    check(LibraryQueries.matchesLibraryFilter(track: lib[0], filter: .flac), "flac filter matches FLAC")
    check(!LibraryQueries.matchesLibraryFilter(track: lib[1], filter: .flac), "flac filter excludes MP3")
    check(LibraryQueries.matchesLibraryFilter(track: lib[3], filter: .lossless), "lossless includes ALAC")

    let visibleAll = LibraryQueries.visibleTracks(in: lib, view: .all, filter: .all, sort: .title, searchQuery: "", store: store)
    checkEqual(visibleAll.map(\.title), ["A","B","C","D"], "sort by title")

    let visibleLiked = LibraryQueries.visibleTracks(in: lib, view: .liked, filter: .all, sort: .title, searchQuery: "", store: store)
    checkEqual(visibleLiked.count, 1, "view=liked filters to liked only")

    let pl = QuaverPlaylist(id: "p1", name: "P", trackKeys: ["/a.flac"])
    store.playlists = [pl]
    let visiblePl = LibraryQueries.visibleTracks(in: lib, view: .playlist(id: "p1"), filter: .all, sort: .title, searchQuery: "", store: store)
    checkEqual(visiblePl.count, 1, "playlist view filters by trackKeys")

    let searched = LibraryQueries.visibleTracks(in: lib, view: .all, filter: .all, sort: .title, searchQuery: "alice", store: store)
    check(searched.isEmpty, "search with no match returns empty")
    let searched2 = LibraryQueries.visibleTracks(in: lib, view: .all, filter: .all, sort: .title, searchQuery: "b", store: store)
    check(searched2.contains(where: { $0.path == "/a.flac" }), "search matches title/artist/album")

    d.removePersistentDomain(forName: suite)
}

// ---------------------------------------------------------------------------
// 4. Swift ↔ Rust FFI — real temp dir, real library.json, ownership
// ---------------------------------------------------------------------------
func testFFI() {
    // missing dir → []
    check(QuaverCore.scanDirectory(at: "/tmp/__quaver_swift_missing_\(UUID().uuidString)").isEmpty, "scan missing dir returns []")

    // empty dir → []
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("__quaver_swift_empty_\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    check(QuaverCore.scanDirectory(at: empty.path).isEmpty, "scan empty dir returns []")
    // non-music files in dir → []
    try! "hello".write(to: empty.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    check(QuaverCore.scanDirectory(at: empty.path).isEmpty, "scan ignores non-music extensions")
    try? FileManager.default.removeItem(at: empty)

    // save/get folder round-trip (isolates via actual HOME Library/Application Support)
    let tmpFolder = FileManager.default.temporaryDirectory.appendingPathComponent("__quaver_swift_folder_\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
    do {
        try QuaverCore.saveMusicFolder(tmpFolder.path)
        let got = QuaverCore.savedMusicFolder()
        checkEqual(got, tmpFolder.path, "save/get music folder round-trip")
    } catch {
        check(false, "saveMusicFolder threw: \(error)")
    }
    // cleanup config + tmp folder to not pollute host (best-effort)
    if let home = ProcessInfo.processInfo.environment["HOME"] {
        let cfg = URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/com.quaver.app/library.json")
        try? FileManager.default.removeItem(at: cfg)
    }
    try? FileManager.default.removeItem(at: tmpFolder)

    // lyrics file round-trip via Rust
    let lrc = FileManager.default.temporaryDirectory.appendingPathComponent("__quaver_swift_\(UUID().uuidString).lrc")
    let lrcContent = "[00:10.00] hello\n[00:12.50] world\n"
    try! lrcContent.write(to: lrc, atomically: true, encoding: .utf8)
    do {
        let got = try QuaverCore.readLyricsFile(at: lrc.path)
        checkEqual(got, lrcContent, "readLyricsFile round-trip via Rust")
    } catch {
        check(false, "readLyricsFile threw: \(error)")
    }
    check(QuaverCore.readLyricsFileIfPresent(at: nil) == nil, "readLyricsFileIfPresent nil returns nil")
    check(QuaverCore.readLyricsFileIfPresent(at: "") == nil, "readLyricsFileIfPresent empty returns nil")
    try? FileManager.default.removeItem(at: lrc)
    // missing lyrics → throws
    do { _ = try QuaverCore.readLyricsFile(at: "/tmp/__quaver_nope_\(UUID().uuidString).lrc"); check(false, "missing lyrics should throw") }
    catch { check(true, "missing lyrics throws as expected") }
}

// ---------------------------------------------------------------------------
// 5. LyricSynchronizer parity spot-checks
// ---------------------------------------------------------------------------
func testLyrics() {
    let lines = LyricSynchronizer.parseLRC("[00:01.00] a\n[00:05.00] b\n[00:10.00] c")
    checkEqual(lines.count, 3, "parseLRC count")
    checkEqual(lines[0].text, "a", "parseLRC text")
    check(LyricSynchronizer.activeIndex(lyrics: lines, currentTime: 0) == -1, "activeIndex before first")
    check(LyricSynchronizer.activeIndex(lyrics: lines, currentTime: 1) == 0, "activeIndex at first stamp")
    check(LyricSynchronizer.activeIndex(lyrics: lines, currentTime: 7) == 1, "activeIndex between stamps")
    check(LyricSynchronizer.activeIndex(lyrics: lines, currentTime: 10) == 2, "activeIndex at last stamp")
    // word progresses
    let wp = LyricSynchronizer.wordProgresses(lyrics: lines, lineIndex: 0, currentTime: 2, audioDuration: nil)
    check(!wp.isEmpty, "wordProgresses non-empty for line with words")
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------
@main struct Runner { static func main() {
print("=== Quaver Phase 2 Boundary Tests ===")
testTrackKey()
testFFI()
testLyrics()
let sem = DispatchSemaphore(value: 0)
Task { @MainActor in
    testLibraryStore()
    testLibraryQueries()
    print("\n=== Result: \(failures.isEmpty ? "ALL PASS" : "\(failures.count) FAILED") ===")
    for f in failures { print("  - \(f)") }
    exit(failures.isEmpty ? 0 : 1)
}
RunLoop.main.run()
} }
