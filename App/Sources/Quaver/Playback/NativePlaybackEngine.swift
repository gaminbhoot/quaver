import AVFoundation
import Combine
import Foundation

// MARK: - NativePlaybackEngine
// Single source of truth: AVPlayer/AVPlayerItem.
// Duration is authoritative from AVPlayerItem, not TrackMetadata / metadata.
// No arbitrary offsets, no metadata-duration fallback, no timeline correction.
//
// Backend abstraction: PlaybackEngine is the public API (single source of truth).
// Current backend is AVPlayer (native). A Symphonia → PCM → AVFoundation fallback
// can be added later behind this same abstraction without changing the public API:
//   PlaybackEngine (protocol) ──► NativePlaybackEngine (coordinator)
//                                   ├── AVPlayerBackend (native)  ← current
//                                   └── FallbackBackend (Symphonia → WAV → AVPlayer/AVAudioEngine) ← future
// Both backends must expose the same state: currentTime/duration/isPlaying/volume/seek/play/pause/EOF/currentTrack.
// UI and LyricSynchronizer never know which backend is active. See docs/PHASE3_BACKEND.md (future).

@MainActor
final class NativePlaybackEngine: PlaybackEngine {

    // MARK: Public state

    private let subject = CurrentValueSubject<PlaybackState, Never>(PlaybackState())
    var state: PlaybackState { subject.value }
    var statePublisher: AnyPublisher<PlaybackState, Never> { subject.eraseToAnyPublisher() }
    var currentTrack: TrackMetadata? {
        let idx = subject.value.currentTrackIndex
        guard library.indices.contains(idx) else { return nil }
        return library[idx]
    }

    var queueOrder: [Int] { playOrder }

    // Backend introspection (extension point). Currently always .native.
    enum BackendKind { case native, fallback }
    var activeBackend: BackendKind { .native }
    var isUsingFallback: Bool { false }

    // MARK: Backing

    private var library: [TrackMetadata]
    private let player: AVPlayer
    private var timeObserver: Any?
    private var itemStatusObservation: NSKeyValueObservation?
    private var itemDurationObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var eofObserver: NSObjectProtocol?
    private var playOrder: [Int] = []
    private var hasFinishedCurrentItem = false
    private var fallbackInFlight = false
    private var fallbackTempPaths: [String] = []

    // MARK: Init

    init(library: [TrackMetadata] = []) {
        self.library = library
        self.player = AVPlayer()
        self.player.volume = 0.8
        rebuildPlayOrder()
        installRateObservation()
        installTimeObserver()
    }

    deinit {
        if let t = timeObserver { (player as AnyObject).removeTimeObserver(t) }
        if let o = eofObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: Library

    func setLibrary(_ tracks: [TrackMetadata]) {
        library = tracks
        rebuildPlayOrder()
        if subject.value.currentTrackIndex >= library.count {
            updateState { $0.currentTrackIndex = -1; $0.isPlaying = false; $0.currentTime = 0; $0.duration = 0 }
        }
    }

    // MARK: PlaybackEngine contract

    func play(trackAt index: Int) {
        guard library.indices.contains(index) else {
            NSLog("[Quaver] play(trackAt:) out of bounds \(index) libCount=\(library.count)")
            return
        }
        let t = library[index]
        NSLog("[Quaver] play(trackAt:) \(index) \(t.path) fmt=\(t.format) durMeta=\(t.duration)")
        hasFinishedCurrentItem = false
        loadItem(at: index, autoPlay: true)
    }

    func play(trackWithKey key: String) {
        guard let idx = library.firstIndex(where: { $0.key == key }) else {
            NSLog("[Quaver] play(trackWithKey:) miss \(key)")
            return
        }
        play(trackAt: idx)
    }

    func togglePlay() {
        if subject.value.isPlaying { pause() } else { resume() }
    }

    func pause() {
        player.pause()
        updateState { $0.isPlaying = false }
    }

    func resume() {
        guard subject.value.currentTrackIndex >= 0 else { return }
        hasFinishedCurrentItem = false
        player.play()
        updateState { $0.isPlaying = true }
    }

    func next() {
        guard let nxt = nextIndex() else {
            player.pause()
            hasFinishedCurrentItem = true
            updateState { $0.isPlaying = false }
            return
        }
        hasFinishedCurrentItem = false
        loadItem(at: nxt, autoPlay: true)
    }

    func previous() {
        guard let prv = previousIndex() else { return }
        hasFinishedCurrentItem = false
        loadItem(at: prv, autoPlay: true)
    }

    func seek(to time: Double) {
        guard let item = player.currentItem else { return }
        let dur = resolvedDuration(for: item)
        let clamped = max(0, min(time, dur > 0 ? dur : time))
        let cm = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateState { $0.currentTime = clamped }
                let d = self.subject.value.duration
                if d > 0 && clamped >= d - 0.02 { self.hasFinishedCurrentItem = false }
            }
        }
    }

    func setVolume(_ volume: Double) {
        let clamped = max(0, min(1, volume))
        player.volume = Float(clamped)
        updateState { $0.volume = clamped }
    }

    func setShuffle(_ enabled: Bool) {
        guard subject.value.isShuffle != enabled else { return }
        updateState { $0.isShuffle = enabled }
        rebuildPlayOrder()
    }

    func setRepeatMode(_ mode: RepeatMode) {
        updateState { $0.repeatMode = mode }
    }

    func moveQueueItem(from sourceQueuePosition: Int, to destQueuePosition: Int) {
        guard playOrder.indices.contains(sourceQueuePosition) else { return }
        guard destQueuePosition >= 0, destQueuePosition <= playOrder.count else { return }
        // Clamp dest when moving downwards (removal shifts)
        let item = playOrder.remove(at: sourceQueuePosition)
        let clampedDest = min(destQueuePosition, playOrder.count)
        // Adjust when source < dest (array shrank by one)
        let insertAt = clampedDest
        playOrder.insert(item, at: insertAt)
        let snapshot = playOrder
        updateState { $0.queueOrder = snapshot }
    }

    // MARK: Private — item loading (single clock)

    private func loadItem(at index: Int, autoPlay: Bool) {
        let track = library[index]
        let url = URL(fileURLWithPath: track.path)
        NSLog("[Quaver] loadItem idx=\(index) url=\(url.path) exists=\(FileManager.default.fileExists(atPath: track.path))")
        tearDownItemObservations()
        if let o = eofObserver { NotificationCenter.default.removeObserver(o); eofObserver = nil }
        hasFinishedCurrentItem = false
        let item = AVPlayerItem(url: url)
        updateState { s in
            s.currentTrackIndex = index
            s.currentTime = 0
            s.duration = 0
            s.isPlaying = false
        }
        eofObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleEOF() } }
        observe(item: item)
        player.replaceCurrentItem(with: item)
        NSLog("[Quaver] replaceCurrentItem status=\(item.status.rawValue) autoPlay=\(autoPlay)")
        if autoPlay {
            if item.status == .readyToPlay {
                player.play()
                updateState { $0.isPlaying = true }
                NSLog("[Quaver] immediate play (readyToPlay)")
            } else {
                NSLog("[Quaver] deferred play awaiting readyToPlay (status \(item.status.rawValue))")
            }
        }
    }

    private func observe(item: AVPlayerItem) {
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            Task { @MainActor in self?.handleStatusChange(it) }
        }
        itemDurationObservation = item.observe(\.duration, options: [.new, .initial]) { [weak self] it, _ in
            Task { @MainActor in self?.handleDurationChange(it) }
        }
    }

    private func tearDownItemObservations() {
        itemStatusObservation?.invalidate(); itemStatusObservation = nil
        itemDurationObservation?.invalidate(); itemDurationObservation = nil
    }

    private func handleStatusChange(_ item: AVPlayerItem) {
        switch item.status {
        case .readyToPlay:
            fallbackInFlight = false
            let d = resolvedDuration(for: item)
            updateState { $0.duration = d }
            if !hasFinishedCurrentItem && subject.value.currentTrackIndex >= 0, player.rate == 0 {
                player.play()
                updateState { $0.isPlaying = true }
            }
            Task { [weak self] in
                guard let self else { return }
                if let assetDur = try? await item.asset.load(.duration), assetDur.isNumeric, !assetDur.isIndefinite {
                    let secs = CMTimeGetSeconds(assetDur)
                    if secs.isFinite, secs > 0 {
                        await MainActor.run { self.updateState { $0.duration = secs } }
                    }
                }
            }
        case .failed:
            // AVPlayer couldn't handle the source (e.g. obscure FLAC/ALAC variant).
            // Transparent fallback via Symphonia → temp WAV → AVPlayer, same state/surfaces.
            if fallbackInFlight { fallbackInFlight = false; updateState { $0.isPlaying = false; $0.duration = 0 }; return }
            let idx = subject.value.currentTrackIndex
            guard library.indices.contains(idx) else { updateState { $0.isPlaying = false; $0.duration = 0 }; return }
            let track = library[idx]
            let err = item.error?.localizedDescription ?? "unknown"
            NSLog("[Quaver] AVPlayer failed for \(track.path) (\(track.format)): \(err) — trying Symphonia fallback")
            attemptFallback(for: track, at: idx)
        case .unknown: break
        @unknown default: break
        }
    }

    private func attemptFallback(for track: TrackMetadata, at index: Int) {
        guard !fallbackInFlight else { return }
        fallbackInFlight = true
        // Heavy decode off main thread — keep UI responsive for 483-row list.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tmp = QuaverCore.decodeToTempWAV(inputPath: track.path)
            Task { @MainActor in
                guard let self else { return }
                guard let wavPath = tmp, !wavPath.isEmpty else {
                    self.fallbackInFlight = false
                    self.updateState { $0.isPlaying = false; $0.duration = 0 }
                    NSLog("[Quaver] Symphonia fallback failed for \(track.path)")
                    return
                }
                self.fallbackTempPaths.append(wavPath)
                self.loadFallbackItem(wavPath: wavPath, originalIndex: index)
            }
        }
    }

    private func loadFallbackItem(wavPath: String, originalIndex: Int) {
        let url = URL(fileURLWithPath: wavPath)
        tearDownItemObservations()
        if let o = eofObserver { NotificationCenter.default.removeObserver(o); eofObserver = nil }
        hasFinishedCurrentItem = false
        let item = AVPlayerItem(url: url)
        // Keep the same track index so UI/lyrics stay bound to the original TrackMetadata.
        updateState { s in
            s.currentTrackIndex = originalIndex
            s.currentTime = 0
            s.duration = 0
            s.isPlaying = false
        }
        eofObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.handleEOF() } }
        observe(item: item)
        player.replaceCurrentItem(with: item)
        if item.status == .readyToPlay {
            player.play()
            updateState { $0.isPlaying = true }
        }
        NSLog("[Quaver] fallback loaded \(wavPath) for index \(originalIndex)")
    }

    private func handleDurationChange(_ item: AVPlayerItem) {
        let d = resolvedDuration(for: item)
        if d.isFinite, d > 0 { updateState { $0.duration = d } }
    }

    private func resolvedDuration(for item: AVPlayerItem) -> Double {
        let cm = item.duration
        if cm.isNumeric, !cm.isIndefinite {
            let secs = CMTimeGetSeconds(cm)
            if secs.isFinite, secs > 0, !secs.isNaN { return secs }
        }
        return 0
    }

    private func handleEOF() {
        guard !hasFinishedCurrentItem else { return }
        hasFinishedCurrentItem = true
        let mode = subject.value.repeatMode
        switch mode {
        case .one:
            hasFinishedCurrentItem = false
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.player.play()
                Task { @MainActor in self?.updateState { $0.isPlaying = true; $0.currentTime = 0 } }
            }
            updateState { $0.currentTime = subject.value.duration }
        case .all:
            if let nxt = nextIndex(wrapping: true) {
                hasFinishedCurrentItem = false
                loadItem(at: nxt, autoPlay: true)
            } else {
                updateState { $0.isPlaying = false; $0.currentTime = subject.value.duration }
            }
        case .off:
            updateState { $0.isPlaying = false; $0.currentTime = subject.value.duration }
        }
    }

    // MARK: Queue / shuffle / repeat

    private func rebuildPlayOrder() {
        let n = library.count
        guard n > 0 else { playOrder = []; updateState { $0.queueOrder = [] }; return }
        if subject.value.isShuffle {
            playOrder = Array(0..<n).shuffled()
        } else {
            playOrder = Array(0..<n)
        }
        let snapshot = playOrder
        updateState { $0.queueOrder = snapshot }
    }

    private func nextIndex(wrapping: Bool = false) -> Int? {
        let cur = subject.value.currentTrackIndex
        guard library.indices.contains(cur) else { return library.indices.first }
        let mode = subject.value.repeatMode
        let shouldWrap = wrapping || mode == .all
        // Use queueOrder (playOrder) as authoritative Up Next order — respects drag-reorder
        // for both shuffle and non-shuffle. When queue is empty, fall back to index math.
        if !playOrder.isEmpty {
            guard let pos = playOrder.firstIndex(of: cur) else { return nil }
            let nxtPos = pos + 1
            if nxtPos < playOrder.count { return playOrder[nxtPos] }
            return shouldWrap ? playOrder.first : nil
        } else {
            let nxt = cur + 1
            if library.indices.contains(nxt) { return nxt }
            return shouldWrap ? library.indices.first : nil
        }
    }

    private func previousIndex() -> Int? {
        let cur = subject.value.currentTrackIndex
        guard library.indices.contains(cur) else { return nil }
        let mode = subject.value.repeatMode
        if !playOrder.isEmpty {
            guard let pos = playOrder.firstIndex(of: cur) else { return nil }
            if pos > 0 { return playOrder[pos - 1] }
            return mode == .all ? playOrder.last : nil
        } else {
            if cur > 0 { return cur - 1 }
            return mode == .all ? library.indices.last : nil
        }
    }

    // MARK: Time / rate observers

    private func installTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] cm in
            Task { @MainActor in
                guard let self else { return }
                if self.hasFinishedCurrentItem { return }
                let secs = CMTimeGetSeconds(cm)
                guard secs.isFinite, !secs.isNaN else { return }
                let dur = self.subject.value.duration
                let clamped = dur > 0 ? min(secs, dur) : secs
                self.updateState { $0.currentTime = clamped }
            }
        }
    }

    private func installRateObservation() {
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in
                guard let self else { return }
                let playing = p.rate != 0 && !self.hasFinishedCurrentItem
                if self.subject.value.isPlaying != playing {
                    self.updateState { $0.isPlaying = playing }
                }
            }
        }
    }

    // MARK: State helper

    private func updateState(_ mutate: (inout PlaybackState) -> Void) {
        var s = subject.value
        mutate(&s)
        if s.duration > 0, s.currentTime > s.duration { s.currentTime = s.duration }
        subject.send(s)
    }
}

private extension TrackMetadata {
    var keyForPlayback: String { key }
}
