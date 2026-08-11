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
    /// Ordered library indices defining the play queue. When empty, library order applies.
    /// Published via state — single source, no second model. See NativePlaybackEngine.
    var queueOrder: [Int] = []
    var progress: Double { duration > 0 ? currentTime / duration : 0 }
}

/// Contract the real engine will satisfy. UI depends only on this, not on AVPlayer directly.
@MainActor
protocol PlaybackEngine: AnyObject {
    var state: PlaybackState { get }
    var statePublisher: AnyPublisher<PlaybackState, Never> { get }
    var currentTrack: TrackMetadata? { get }
    /// Ordered queue — library indices. Empty means no queue yet (library order).
    var queueOrder: [Int] { get }

    func play(trackAt index: Int)
    func togglePlay()
    func pause()
    func next()
    func previous()
    func seek(to time: Double)
    func setVolume(_ volume: Double)
    func setShuffle(_ enabled: Bool)
    func setRepeatMode(_ mode: RepeatMode)
    /// Reorder queue (drag). Indices are positions in queueOrder, not library indices.
    func moveQueueItem(from sourceQueuePosition: Int, to destQueuePosition: Int)
}

/// Stub that compiles and lets Phase 4+ UI build against the protocol before AVPlayer exists.
@MainActor
final class StubPlaybackEngine: PlaybackEngine {
    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    var state: PlaybackState { subject.value }
    var statePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    var currentTrack: TrackMetadata? { nil }
    var queueOrder: [Int] { subject.value.queueOrder }
    func play(trackAt index: Int) {}
    func togglePlay() {}
    func pause() {}
    func next() {}
    func previous() {}
    func seek(to time: Double) {}
    func setVolume(_ volume: Double) {}
    func setShuffle(_ enabled: Bool) { var s = subject.value; s.isShuffle = enabled; subject.send(s) }
    func setRepeatMode(_ mode: RepeatMode) { var s = subject.value; s.repeatMode = mode; subject.send(s) }
    func moveQueueItem(from s: Int, to d: Int) {}
}
