import AppKit
import Combine
import MediaPlayer

// MARK: - NowPlayingInfoController
// Bridges PlaybackEngine (single clock) → macOS system:
//   MPNowPlayingInfoCenter  (Lock Screen / Control Center / Touch Bar)
//   MPRemoteCommandCenter   (media keys, headset, Control Center transport)
// No second playback clock. No duration from TrackMetadata. Duration/currentTime
// are always from PlaybackState which derives from AVPlayerItem.

@MainActor
final class NowPlayingInfoController {

    private let engine: PlaybackEngine
    private var cancellables = Set<AnyCancellable>()
    private var commandTargets: [Any] = []
    private var lastNPKey: String?
    private var lastNPArtwork: Any?

    init(engine: PlaybackEngine) {
        self.engine = engine
        setupRemoteCommands()
        bindEngine()
    }

    deinit {
        // Cannot call MainActor-isolated teardownRemoteCommands() from deinit (nonisolated).
        // The owning AppDelegate calls invalidate() explicitly on MainActor before release.
        // As a fallback, attempt best-effort cleanup without requiring isolation:
        // MPRemoteCommandCenter removal is safe to skip here — process termination will clear it.
        // We just clear the sentinel.
    }

    /// Explicit teardown — call from MainActor owner before releasing.
    func invalidate() {
        teardownRemoteCommands()
    }

    // MARK: - Engine binding

    private func bindEngine() {
        engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateNowPlayingInfo() }
            }
            .store(in: &cancellables)
        // Initial
        updateNowPlayingInfo()
    }

    // MARK: - Now Playing Info

    private func updateNowPlayingInfo() {
        var info: [String: Any] = [:]
        let state = engine.state
        let curKey = engine.currentTrack?.key

        if let track = engine.currentTrack {
            let title = track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title
            let artist = track.artist.isEmpty ? "Unknown Artist" : track.artist
            info[MPMediaItemPropertyTitle] = title
            info[MPMediaItemPropertyArtist] = artist
            if !track.album.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = track.album
            }
            // Artwork — cached: base64 decode + MPMediaItemArtwork only when track changes
            if let dataURL = track.coverDataURL {
                if curKey == lastNPKey, let art = lastNPArtwork {
                    info[MPMediaItemPropertyArtwork] = art
                } else if let image = CoverImageCache.image(fromDataURL: dataURL) {
                    if #available(macOS 11.0, *) {
                        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                        info[MPMediaItemPropertyArtwork] = artwork
                        lastNPArtwork = artwork
                    } else {
                        info[MPMediaItemPropertyArtwork] = image
                        lastNPArtwork = image
                    }
                } else {
                    lastNPArtwork = nil
                }
            } else {
                lastNPArtwork = nil
            }
            lastNPKey = curKey
        } else {
            info[MPMediaItemPropertyTitle] = "Quaver"
            lastNPKey = nil
            lastNPArtwork = nil
        }

        let dur = state.duration
        if dur.isFinite, dur > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = dur
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.currentTime
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0.0
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        // For proper progress display, also set default playback rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Commands (media keys etc.)

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        // Ensure all relevant commands are enabled and have our handlers.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.engine.state.isPlaying { self.engine.togglePlay() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.engine.state.isPlaying { self.engine.pause() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.engine.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let posEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.engine.seek(to: posEvent.positionTime) }
            return .success
        }
        // Keep a sentinel so we can reason about lifecycle in tests
        commandTargets = [center]
    }

    private func teardownRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        commandTargets.removeAll()
    }

    // MARK: - Test hooks

    var hasRemoteCommands: Bool { !commandTargets.isEmpty }
    var nowPlayingTitle: String? {
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String
    }

    // MARK: - Helpers

    private static func image(fromDataURL url: String) -> NSImage? {
        CoverImageCache.image(fromDataURL: url)
    }
}
