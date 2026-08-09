import AVFoundation
import Combine
import AppKit

/// Single source of truth for playback. No HTMLAudioElement. No JS clock.
/// Phase 1: protocol + state shape only. AVPlayer wiring lands in Phase 3.
enum RepeatMode: String, Codable, Equatable { case off, all, one }
enum PlaybackError: Error { case emptyLibrary, invalidIndex, assetFailed(String) }

/// Minimal state snapshot that every UI surface observes.
struct PlaybackState: Equatable {
    var currentTrackIndex: Int = -1
    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var volume: Double = 0.8
    var isShuffle: Bool = false
    var repeatMode: RepeatMode = .off
    var progress: Double { duration > 0 ? currentTime / duration : 0 }
}

/// Contract the real engine will satisfy. UI depends only on this, not on AVPlayer directly.
@MainActor
protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }
    var statePublisher: AnyPublisher<PlaybackState, Never> { get }
    var currentTrack: TrackMetadata? { get }

    func play(trackAt index: Int)
    func togglePlay()
    func pause()
    func next()
    func previous()
    func seek(to time: Double)
    func setVolume(_ volume: Double)
    func setShuffle(_ enabled: Bool)
    func setRepeatMode(_ mode: RepeatMode)
}

/// Stub that compiles and lets Phase 4+ UI build against the protocol before AVPlayer exists.
@MainActor
final class StubPlaybackEngine: PlaybackEngine {
    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    var state: PlaybackState { subject.value }
    var statePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    var currentTrack: TrackMetadata? { nil }
    func play(trackAt index: Int) {}
    func togglePlay() {}
    func pause() {}
    func next() {}
    func previous() {}
    func seek(to time: Double) {}
    func setVolume(_ volume: Double) {}
    func setShuffle(_ enabled: Bool) { var s = subject.value; s.isShuffle = enabled; subject.send(s) }
    func setRepeatMode(_ mode: RepeatMode) { var s = subject.value; s.repeatMode = mode; subject.send(s) }
}
