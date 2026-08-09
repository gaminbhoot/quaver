import Foundation
import AppKit

// MARK: - TrackMetadata

/// Swift-side view of the Rust core's `TrackMetadata`.
/// JSON shape matches `quaver-core/src/lib.rs::TrackMetadata` exactly
/// so the FFI passes UTF-8 JSON without a custom binary protocol.
struct TrackMetadata: Codable, Equatable, Sendable {
    var path: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var format: String
    var coverDataURL: String?
    var lyricPath: String?

    enum CodingKeys: String, CodingKey {
        case path, title, artist, album, duration, format
        case coverDataURL = "cover_data_url"
        case lyricPath = "lyric_path"
    }
}

// MARK: - C FFI imports (Rust staticlib `quaver_core`)
// No bridging header needed — @_silgen_name links directly.

@_silgen_name("quaver_scan_directory_json")
private func _quaver_scan_directory_json(_ dirPath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("quaver_read_lyrics_file")
private func _quaver_read_lyrics_file(_ filePath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("quaver_get_saved_music_folder")
private func _quaver_get_saved_music_folder() -> UnsafeMutablePointer<CChar>?

@_silgen_name("quaver_save_music_folder")
private func _quaver_save_music_folder(_ folderPath: UnsafePointer<CChar>?) -> Int32

@_silgen_name("quaver_decode_to_temp_wav")
private func _quaver_decode_to_temp_wav(_ inputPath: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?

@_silgen_name("quaver_decode_to_wav")
private func _quaver_decode_to_wav(_ inputPath: UnsafePointer<CChar>?, _ outputPath: UnsafePointer<CChar>?) -> Int32

@_silgen_name("quaver_free_string")
private func _quaver_free_string(_ ptr: UnsafeMutablePointer<CChar>?)

// MARK: - Errors

enum QuaverCoreError: Error, LocalizedError {
    case scanFailed(String)
    case lyricsReadFailed(String)
    case saveFolderFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .scanFailed(let m): return "Scan failed: \(m)"
        case .lyricsReadFailed(let m): return "Lyrics read failed: \(m)"
        case .saveFolderFailed(let m): return "Save folder failed: \(m)"
        case .encodingFailed: return "String encoding failed"
        }
    }
}

// MARK: - QuaverCore

/// Swift ↔ Rust boundary. Small, explicit, strongly typed.
/// No Tauri IPC. No WKWebView. No hidden WebView.
/// Rust exposes a C ABI (staticlib); Swift calls it with JSON + manual ownership.
/// All blocking FS work is expected to be called off the main thread;
/// callers should dispatch to a background queue and hop back to MainActor for UI.
enum QuaverCore {

    // MARK: Folder persistence (Rust: library.json under Application Support)

    /// Returns the persisted music folder if it exists on disk, else nil.
    /// Mirrors `get_saved_music_folder` / JS `get_saved_music_folder`.
    static func savedMusicFolder() -> String? {
        guard let ptr = _quaver_get_saved_music_folder() else { return nil }
        defer { _quaver_free_string(ptr) }
        let s = String(cString: ptr)
        return s.isEmpty ? nil : s
    }

    /// Persist the music folder. Throws on failure.
    static func saveMusicFolder(_ path: String) throws {
        let rc: Int32 = path.withCString { cstr in _quaver_save_music_folder(cstr) }
        if rc != 0 { throw QuaverCoreError.saveFolderFailed(path) }
    }

    // MARK: Scanning

    /// Scan `path` on the calling thread and return parsed tracks.
    /// Returns [] for missing/non-directory/error (Rust returns null → []).
    /// For UI callers, prefer `scanDirectoryAsync(at:)`.
    static func scanDirectory(at path: String) -> [TrackMetadata] {
        guard let jsonPtr = path.withCString({ cstr in _quaver_scan_directory_json(cstr) }) else {
            return []
        }
        defer { _quaver_free_string(jsonPtr) }
        let json = String(cString: jsonPtr)
        guard let data = json.data(using: .utf8) else { return [] }
        do {
            return try JSONDecoder().decode([TrackMetadata].self, from: data)
        } catch {
            // Corrupt JSON → empty library, not a crash.
            return []
        }
    }

    /// Async variant: runs scanning off the main thread.
    static func scanDirectoryAsync(at path: String) async -> [TrackMetadata] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let tracks = scanDirectory(at: path)
                cont.resume(returning: tracks)
            }
        }
    }

    // MARK: Lyrics

    /// Read an .lrc file at an absolute path. Returns file contents as String.
    /// Throws if the file cannot be read. Caller may present the error or treat as no lyrics.
    static func readLyricsFile(at path: String) throws -> String {
        guard let ptr = path.withCString({ cstr in _quaver_read_lyrics_file(cstr) }) else {
            throw QuaverCoreError.lyricsReadFailed(path)
        }
        defer { _quaver_free_string(ptr) }
        return String(cString: ptr)
    }

    // MARK: Fallback decode — Symphonia → PCM → WAV

    /// Decode `inputPath` (any Symphonia-supported format) to a temp WAV.
    /// Returns the temp WAV path (in /tmp) or nil on failure. Caller should unlink after use if desired.
    static func decodeToTempWAV(inputPath: String) -> String? {
        guard let ptr = inputPath.withCString({ cstr in _quaver_decode_to_temp_wav(cstr) }) else { return nil }
        defer { _quaver_free_string(ptr) }
        let s = String(cString: ptr)
        return s.isEmpty ? nil : s
    }

    static func decodeToWAV(inputPath: String, outputPath: String) -> Bool {
        let rc: Int32 = inputPath.withCString { a in outputPath.withCString { b in _quaver_decode_to_wav(a, b) } }
        return rc == 0
    }

    /// Non-throwing variant — returns nil on failure (convenient for optional lyrics).
    static func readLyricsFileIfPresent(at path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return try? readLyricsFile(at: path)
    }

    // MARK: File picker (pure AppKit — no rfd, no Tauri)

    /// Native NSOpenPanel folder picker. Must be called on MainActor.
    @MainActor
    static func pickMusicFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Select Music Folder"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

// MARK: - Track identity (join key for playlists / liked / recently played)

extension TrackMetadata {
    /// Stable identity key — mirrors JS `trackKey(track) = path || title|artist|album`.
    /// Must be preserved exactly across persistence migrations.
    var key: String {
        if !path.isEmpty { return path }
        return "\(title)|\(artist)|\(album)"
    }
}
