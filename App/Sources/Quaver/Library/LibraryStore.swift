import Foundation
import Combine

// MARK: - Persisted shapes (mirror JS localStorage exactly)
// JS keys: quaver-playlists, quaver-liked-tracks, quaver-recently-played, quaver-icon-style

/// Mirrors JS `{ id, name, trackKeys: string[] }` stored under `quaver-playlists`.
struct QuaverPlaylist: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var trackKeys: [String]
}

/// Mirrors JS `{ key: string, playedAt: number }` under `quaver-recently-played`.
/// `playedAt` is milliseconds since epoch (JS `Date.now()`).
struct RecentlyPlayedEntry: Codable, Equatable, Sendable {
    var key: String
    var playedAt: Double
}

/// UI-owned view state — not persisted except as session restoration if desired.
enum LibrarySort: String, Codable, Equatable, Sendable, CaseIterable {
    case title, artist, album, recent
}
enum LibraryFilter: String, Codable, Equatable, Sendable, CaseIterable {
    case all, flac, lossless
}
enum LibraryView: Equatable, Sendable {
    case all
    case liked
    case recent
    case artists
    case albums
    case artist(String)
    case album(String)
    case playlist(id: String)
    case nowPlaying
}

// MARK: - Persistence keys (AppKit: UserDefaults suite — not WebView localStorage)

/// Centralizes key names so migration audits can grep one file.
enum QuaverStoreKeys {
    static let playlists = "quaver-playlists"
    static let likedTracks = "quaver-liked-tracks"
    static let recentlyPlayed = "quaver-recently-played"
    static let iconStyle = "quaver-icon-style" // UI only — not library state
}

/// Native persistence for playlists / likes / recently played.
/// Replaces JS `loadLibraryData` / `saveLibraryData` (localStorage).
/// Backed by UserDefaults with suite `com.quaver.app` so the data lives
/// outside any WKWebView and survives app restarts. All JSON shapes match
/// the JS schemas exactly so an importer can read old localStorage dumps unchanged.
@MainActor
final class LibraryStore: ObservableObject {

    // MARK: Published state (single source of truth the UI binds to)

    @Published var playlists: [QuaverPlaylist] { didSet { if !isLoading { savePlaylists(); sendDidChange() } } }
    @Published var likedTrackKeys: Set<String> { didSet { if !isLoading { saveLiked(); sendDidChange() } } }
    @Published var recentlyPlayed: [RecentlyPlayedEntry] { didSet { if !isLoading { saveRecentlyPlayed(); sendDidChange() } } }

    // Non-persisted UI state
    @Published var librarySort: LibrarySort = .title { didSet { if oldValue != librarySort { sendDidChange() } } }
    @Published var libraryFilter: LibraryFilter = .all { didSet { if oldValue != libraryFilter { sendDidChange() } } }

    // Synchronous change publisher for AppKit (avoids Combine timing issues with @Published + MainActor).
    // Emits AFTER the property has been set, so observers reading store see the new value.
    private let didChangeSubject = PassthroughSubject<Void, Never>()
    var didChangePublisher: AnyPublisher<Void, Never> { didChangeSubject.eraseToAnyPublisher() }
    private func sendDidChange() { didChangeSubject.send(()) }

    private let defaults: UserDefaults
    private var isLoading = false

    // MARK: Init — loads from UserDefaults, never throws

    init(defaults: UserDefaults = LibraryStore.makeDefaults()) {
        self.defaults = defaults
        isLoading = true
        defer { isLoading = false }
        self.playlists = LibraryStore.load([QuaverPlaylist].self, key: QuaverStoreKeys.playlists, defaults: defaults) ?? []
        let likedArray: [String] = LibraryStore.load([String].self, key: QuaverStoreKeys.likedTracks, defaults: defaults) ?? []
        self.likedTrackKeys = Set(likedArray)
        self.recentlyPlayed = LibraryStore.load([RecentlyPlayedEntry].self, key: QuaverStoreKeys.recentlyPlayed, defaults: defaults) ?? []
        // librarySort/filter stay at defaults (not persisted in legacy); could load if desired.
    }

    // MARK: Mutations

    func toggleLike(trackKey: String) {
        if likedTrackKeys.contains(trackKey) { likedTrackKeys.remove(trackKey) }
        else { likedTrackKeys.insert(trackKey) }
    }

    @discardableResult
    func createPlaylist(name: String) -> QuaverPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = UUID().uuidString
        let pl = QuaverPlaylist(id: id, name: trimmed.isEmpty ? "Untitled" : trimmed, trackKeys: [])
        playlists.append(pl)
        return pl
    }

    func addTrack(_ trackKey: String, toPlaylist id: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        if playlists[idx].trackKeys.contains(trackKey) { return }
        var copy = playlists
        copy[idx].trackKeys.append(trackKey)
        playlists = copy
    }

    func removeTrack(_ trackKey: String, fromPlaylist id: String) {
        guard let idx = playlists.firstIndex(where: { $0.id == id }) else { return }
        var copy = playlists
        copy[idx].trackKeys.removeAll { $0 == trackKey }
        playlists = copy
    }

    func deletePlaylist(id: String) {
        playlists.removeAll { $0.id == id }
    }

    /// Mirrors JS: MRU capped at 50.
    func recordPlayed(trackKey: String) {
        let now = Date().timeIntervalSince1970 * 1000 // ms like JS Date.now()
        recentlyPlayed.removeAll { $0.key == trackKey }
        recentlyPlayed.insert(RecentlyPlayedEntry(key: trackKey, playedAt: now), at: 0)
        if recentlyPlayed.count > 50 { recentlyPlayed = Array(recentlyPlayed.prefix(50)) }
    }

    // MARK: Migration — import legacy localStorage JSON dumps

    /// Import legacy data exported from the old WebView `localStorage`.
    /// `container` keys are the exact localStorage keys (`quaver-playlists` etc).
    /// Existing native data is merged (union) rather than overwritten.
    func importLegacyContainer(_ container: [String: Data]) {
        if let data = container[QuaverStoreKeys.playlists],
           let imported = try? JSONDecoder().decode([QuaverPlaylist].self, from: data) {
            var byId = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
            for pl in imported where byId[pl.id] == nil { byId[pl.id] = pl }
            playlists = Array(byId.values)
        }
        if let data = container[QuaverStoreKeys.likedTracks],
           let imported = try? JSONDecoder().decode([String].self, from: data) {
            likedTrackKeys.formUnion(imported)
        }
        if let data = container[QuaverStoreKeys.recentlyPlayed],
           let imported = try? JSONDecoder().decode([RecentlyPlayedEntry].self, from: data) {
            var byKey: [String: RecentlyPlayedEntry] = [:]
            for e in recentlyPlayed { byKey[e.key] = e }
            for e in imported {
                if let cur = byKey[e.key] { if e.playedAt > cur.playedAt { byKey[e.key] = e } }
                else { byKey[e.key] = e }
            }
            recentlyPlayed = byKey.values.sorted { $0.playedAt > $1.playedAt }.prefix(50).map { $0 }
        }
    }

    /// Convenience: import from a file that contains `{ "quaver-playlists": [...], ... }`
    /// as written by the legacy app's export helper.
    func importLegacyFile(at url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var container: [String: Data] = [:]
        for key in [QuaverStoreKeys.playlists, QuaverStoreKeys.likedTracks, QuaverStoreKeys.recentlyPlayed] {
            if let val = obj[key] {
                container[key] = try JSONSerialization.data(withJSONObject: val)
            }
        }
        importLegacyContainer(container)
    }

    // MARK: Private persistence

    private func savePlaylists() {
        guard !isLoading else { return }
        save(playlists, key: QuaverStoreKeys.playlists)
    }
    private func saveLiked() {
        guard !isLoading else { return }
        save(Array(likedTrackKeys), key: QuaverStoreKeys.likedTracks)
    }
    private func saveRecentlyPlayed() {
        guard !isLoading else { return }
        save(recentlyPlayed, key: QuaverStoreKeys.recentlyPlayed)
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value),
           let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: key)
        }
    }

    // MARK: Defaults

    nonisolated static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "com.quaver.app") ?? .standard
    }

    static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let str = defaults.string(forKey: key),
              let data = str.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Library queries (pure, testable — no I/O)

/// Pure filtering/sorting/browsing over an in-memory library.
/// Mirrors JS `isInCurrentLibraryView` / `matchesLibraryFilter` / `sortVisibleTracks` / `renderBrowseGroups`.
@MainActor
enum LibraryQueries {

    static func isInCurrentLibraryView(track: TrackMetadata, view: LibraryView, store: LibraryStore, playlistResolver: (String) -> QuaverPlaylist?) -> Bool {
        switch view {
        case .all, .artists, .albums, .nowPlaying:
            return true
        case .liked:
            return store.likedTrackKeys.contains(track.key)
        case .recent:
            return store.recentlyPlayed.contains { $0.key == track.key }
        case .playlist(let id):
            return playlistResolver(id)?.trackKeys.contains(track.key) ?? false
        case .artist(let name):
            return track.artist == name
        case .album(let name):
            return track.album == name
        }
    }

    static func matchesLibraryFilter(track: TrackMetadata, filter: LibraryFilter) -> Bool {
        let fmt = track.format.lowercased()
        switch filter {
        case .all: return true
        case .flac: return fmt == "flac"
        case .lossless: return ["flac", "alac", "wav", "aiff", "aif"].contains(fmt)
        }
    }

    static func matchesSearch(track: TrackMetadata, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return track.title.lowercased().contains(q)
            || track.artist.lowercased().contains(q)
            || track.album.lowercased().contains(q)
    }

    static func sortVisibleTracks(_ tracks: [TrackMetadata], sort: LibrarySort, recentlyPlayed: [RecentlyPlayedEntry]) -> [TrackMetadata] {
        switch sort {
        case .title:  return tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: return tracks.sorted { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        case .album:  return tracks.sorted { $0.album.localizedCaseInsensitiveCompare($1.album) == .orderedAscending }
        case .recent:
            let pos: [String: Double] = Dictionary(uniqueKeysWithValues: recentlyPlayed.map { ($0.key, $0.playedAt) })
            return tracks.sorted {
                let aPos = pos[$0.key] ?? -1
                let bPos = pos[$1.key] ?? -1
                if aPos != bPos { return aPos > bPos }
                return false
            }
        }
    }

    static func visibleTracks(in library: [TrackMetadata], view: LibraryView, filter: LibraryFilter, sort: LibrarySort, searchQuery: String, store: LibraryStore) -> [TrackMetadata] {
        let resolver: (String) -> QuaverPlaylist? = { id in store.playlists.first { $0.id == id } }
        var out = library.filter { track in
            isInCurrentLibraryView(track: track, view: view, store: store, playlistResolver: resolver)
                && matchesLibraryFilter(track: track, filter: filter)
                && matchesSearch(track: track, query: searchQuery)
        }
        out = sortVisibleTracks(out, sort: sort, recentlyPlayed: store.recentlyPlayed)
        return out
    }
}
