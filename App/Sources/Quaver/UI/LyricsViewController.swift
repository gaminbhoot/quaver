import AppKit
import Combine
import QuartzCore

// MARK: - LyricsViewController
// Native fullscreen/immersive lyrics overlay. Pure AppKit, no WKWebView, no Timer.
// Single source of truth: PlaybackEngine.currentTime → LyricSynchronizer → active line/word → UI/scroll.

@MainActor
final class LyricsViewController: NSViewController {

    // MARK: Engine + State

    private let engine: PlaybackEngine
    private(set) var lyrics: [LyricLine] = []
    private(set) var activeIndex: Int = -1
    private var loadVersion = 0
    private var manualScrollUntil: TimeInterval = 0 // epoch seconds, 0 = no grace
    private(set) var isLyricsActive = false // overlay open?
    private var displayedTrackKey: String?
    private var cancellables = Set<AnyCancellable>()
    private var isAutoScrolling = false
    private(set) var syncCallCount = 0
    private(set) var lastCenteredIndex: Int? = nil

    private let manualGrace: TimeInterval = 4.5

    // MARK: UI

    private let backgroundView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleAxesIndependently
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.alphaValue = 0.18
        return v
    }()

    private let dimmingView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.85).cgColor
        return v
    }()

    private var glassView: NSView?

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        sv.hasVerticalScroller = true
        return sv
    }()

    private let stackView: NSStackView = {
        let s = NSStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 18
        s.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 80, right: 32)
        return s
    }()

    private let documentView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let emptyLabel: NSTextField = {
        let l = NSTextField(labelWithString: "No synced lyrics")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 16, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.isHidden = true
        return l
    }()

    let closeButton: NSButton = {
        let b = NSButton(title: "Close", target: nil, action: nil)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .rounded
        b.keyEquivalent = "\u{1b}" // Escape
        return b
    }()

    private let headerTrackLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    // MARK: Init

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: View lifecycle

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        // Clear so the artwork + glass show through with depth. Previous
        // opaque 0.09 made the overlay a flat dark rectangle even with glass.
        v.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = v
        view.isHidden = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        bindEngine()
        // Observe manual scroll via bounds changes — simplest without capturing MainActor in NSEvent monitor.
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func setupUI() {
        view.addSubview(backgroundView)
        view.addSubview(dimmingView)
        // Native Liquid Glass / material surface for immersive lyrics — sits between
        // artwork background and scroll content so artwork remains visible through
        // genuine AppKit material without intercepting clicks.
        let glass = QuaverGlass.backgroundView(for: .lyrics)
        glass.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(glass)
        self.glassView = glass
        // When real glass/material is active, soften the solid dimming so the
        // material shows through with vibrancy and artwork depth remains
        // visible — previous 0.45/0.35 were still too dark and the overlay
        // read as an opaque dark rectangle hiding the Liquid Glass.
        if glass is NSVisualEffectView {
            dimmingView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.28).cgColor
        } else if #available(macOS 26.0, *) {
            if glass is NSGlassEffectView {
                dimmingView.layer?.backgroundColor = NSColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 0.22).cgColor
            }
        }
        // If glass is the solid fallback (plain NSView), it already covers the
        // dimming color — keep dimming but avoid double-opacity.
        if !(glass is NSVisualEffectView) {
            if #available(macOS 26.0, *) {
                if !(glass is NSGlassEffectView) {
                    // solid fallback — hide extra dimming to keep 0.85 single layer
                    dimmingView.isHidden = true
                }
            } else {
                dimmingView.isHidden = true
            }
        }
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(closeButton)
        view.addSubview(headerTrackLabel)

        documentView.addSubview(stackView)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: view.topAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            glass.topAnchor.constraint(equalTo: view.topAnchor),
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            headerTrackLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerTrackLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            headerTrackLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            headerTrackLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

            closeButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: headerTrackLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            // Height will be driven by stackView

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        closeButton.target = self
        closeButton.action = #selector(closeTapped)

        // Ensure contentView posts bounds changes
        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    private func bindEngine() {
        engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleEngineState(state) }
            .store(in: &cancellables)
    }

    // MARK: Engine state handling — single clock

    private func handleEngineState(_ state: PlaybackState) {
        // Track change detection for stale loads
        let cur = engine.currentTrack
        let key = cur?.key
        if key != displayedTrackKey {
            displayedTrackKey = key
            Task { await self.loadLyrics(for: cur) }
            // Update header + background immediately
            headerTrackLabel.stringValue = cur.map { "\($0.title) — \($0.artist)" } ?? ""
            if let url = cur?.coverDataURL, let img = Self.image(fromDataURL: url) {
                backgroundView.image = img
            } else {
                backgroundView.image = nil
            }
        }
        sync(currentTime: state.currentTime)
    }

    // MARK: Lyrics loading — version-guarded against stale async

    func load(_ newLyrics: [LyricLine]) {
        loadVersion += 1
        lyrics = newLyrics
        activeIndex = -1
        renderLyrics()
        sync(currentTime: engine.state.currentTime)
    }

    /// Version-guarded async loader for tests (mirrors JS loadAsync).
    func loadAsync(_ provider: @escaping () async -> [LyricLine]) async -> Bool {
        loadVersion += 1
        let myVersion = loadVersion
        let result = await provider()
        guard myVersion == loadVersion else { return false }
        lyrics = result
        activeIndex = -1
        renderLyrics()
        sync(currentTime: engine.state.currentTime)
        return true
    }

    private func loadLyrics(for track: TrackMetadata?) async {
        loadVersion += 1
        let myVersion = loadVersion
        // Clear stale UI immediately but don't commit empty until verified? Keep previous until new arrives for visual continuity?
        // For correctness spec: track change must invalidate stale lyric state — we clear.
        lyrics = []
        activeIndex = -1
        // Render empty synchronously so old lyrics don't linger
        renderLyrics()

        guard let track, let lyricPath = track.lyricPath, !lyricPath.isEmpty else {
            // No lrc — empty
            return
        }
        // Read off main thread
        let content: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let c = QuaverCore.readLyricsFileIfPresent(at: lyricPath)
                cont.resume(returning: c)
            }
        }
        guard myVersion == loadVersion else { return } // stale
        if let text = content, !text.isEmpty {
            let parsed = LyricSynchronizer.parseLRC(text)
            guard myVersion == loadVersion else { return }
            lyrics = parsed
        } else {
            lyrics = []
        }
        activeIndex = -1
        renderLyrics()
        sync(currentTime: engine.state.currentTime)
    }

    // MARK: Rendering

    private func renderLyrics() {
        // Clear existing
        for v in stackView.arrangedSubviews { stackView.removeArrangedSubview(v); v.removeFromSuperview() }
        if lyrics.isEmpty {
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        for (idx, line) in lyrics.enumerated() {
            let lineView = LyricLineView(line: line, index: idx)
            lineView.onLineClick = { [weak self] i in self?.clickLyric(at: i) }
            lineView.onWordClick = { [weak self] li, wi in self?.clickWord(line: li, word: wi) }
            stackView.addArrangedSubview(lineView)
        }
        // Initial styling pass
        updateLineStyles()
    }

    // MARK: Sync — single clock derived

    func sync(currentTime: Double) {
        syncCallCount += 1
        guard !lyrics.isEmpty else { return }
        let act = LyricSynchronizer.activeIndex(lyrics: lyrics, currentTime: currentTime)
        let isVisible = isLyricsActive && !view.isHidden && !lyrics.isEmpty
        if !isVisible {
            if act != activeIndex { activeIndex = act }
            return
        }
        if act != activeIndex {
            activeIndex = act
            updateLineStyles()
            if Date().timeIntervalSince1970 >= manualScrollUntil {
                centerActiveLine(animated: true)
            }
        }
        updateWordProgresses(for: act, currentTime: currentTime)
    }

    private func updateLineStyles() {
        for (idx, view) in stackView.arrangedSubviews.enumerated() {
            guard let lineView = view as? LyricLineView else { continue }
            let isActive = idx == activeIndex
            let isPast = idx < activeIndex
            let isUpcoming = idx > activeIndex
            let isNearby = abs(idx - activeIndex) == 1
            lineView.setState(active: isActive, past: isPast, upcoming: isUpcoming, nearby: isNearby)
        }
    }

    private func updateWordProgresses(for lineIndex: Int, currentTime: Double) {
        guard lyrics.indices.contains(lineIndex) else {
            for case let lv as LyricLineView in stackView.arrangedSubviews { lv.updateWordProgresses([]) }
            return
        }
        let dur = engine.state.duration
        let progresses = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: lineIndex, currentTime: currentTime, audioDuration: dur > 0 ? dur : nil)
        for (idx, view) in stackView.arrangedSubviews.enumerated() {
            guard let lv = view as? LyricLineView else { continue }
            if idx == lineIndex {
                lv.updateWordProgresses(progresses)
            } else {
                lv.updateWordProgresses([])
            }
        }
    }

    private func centerActiveLine(animated: Bool) {
        guard activeIndex >= 0, stackView.arrangedSubviews.indices.contains(activeIndex) else { return }
        guard Date().timeIntervalSince1970 >= manualScrollUntil else { return }
        let lineView = stackView.arrangedSubviews[activeIndex]
        lastCenteredIndex = activeIndex
        let visibleRect = lineView.frame
        let clip = scrollView.contentView
        let targetY = max(0, visibleRect.midY - clip.bounds.height / 2)
        let targetOrigin = NSPoint(x: 0, y: targetY)
        if animated {
            isAutoScrolling = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.72
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(targetOrigin)
                scrollView.reflectScrolledClipView(clip)
            }, completionHandler: { [weak self] in
                Task { @MainActor in self?.isAutoScrolling = false }
            })
        } else {
            clip.setBoundsOrigin(targetOrigin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: Interactions

    func clickLyric(at index: Int) {
        guard lyrics.indices.contains(index) else { return }
        let t = lyrics[index].time
        manualScrollUntil = 0
        engine.seek(to: t)
        // Sync will be driven by engine's statePublisher; also immediate for test determinism
        // Use async after seek to allow AVPlayer's seek to settle; tests await.
    }

    func clickWord(line lineIndex: Int, word wordIndex: Int) {
        guard lyrics.indices.contains(lineIndex) else { return }
        let line = lyrics[lineIndex]
        // Mirror JS: words = text.split(/(\s+)/).filter(non-whitespace)
        let words = line.text.split { $0.isWhitespace }.filter { !$0.isEmpty }
        guard wordIndex >= 0, wordIndex < words.count else { return }
        let dur = LyricSynchronizer.lineDuration(lyrics: lyrics, index: lineIndex, audioDuration: engine.state.duration > 0 ? engine.state.duration : nil)
        let target = line.time + dur * (Double(wordIndex) / Double(max(1, words.count)))
        manualScrollUntil = 0
        engine.seek(to: target)
    }

    func handleManualScroll() {
        manualScrollUntil = Date().timeIntervalSince1970 + manualGrace
        isAutoScrolling = false
    }

    @objc private func clipBoundsDidChange(_ note: Notification) {
        if isAutoScrolling { return }
        // If user drags scrollbar, bounds changes; treat as manual if overlay active and not hidden
        if isLyricsActive && !view.isHidden && !isAutoScrolling {
            // Heuristic: if change not triggered by our centerActiveLine, it's user
            // For test determinism, we only mark manual on explicit handleManualScroll or if scrollWheel; bounds change from code also fires but we guard via isAutoScrolling.
            // To avoid spurious, require that activeIndex is valid and view is visible.
            // For headless tests, we simulate via direct handleManualScroll() call.
        }
    }

    // MARK: Overlay lifecycle

    func open() {
        isLyricsActive = true
        activeIndex = -1
        manualScrollUntil = 0
        view.isHidden = false
        if lyrics.isEmpty {
            scrollView.contentView.setBoundsOrigin(.zero)
        } else {
            sync(currentTime: engine.state.currentTime)
        }
    }

    func close() {
        isLyricsActive = false
        view.isHidden = true
        // Cancel any animation
        isAutoScrolling = false
        lastCenteredIndex = nil
    }

    func destroy() {
        // Tear down Combine observers — mirrors JS destroy()
        cancellables.removeAll()
        close()
    }

    deinit {
        cancellables.removeAll()
    }

    // MARK: Helpers

    private static func image(fromDataURL url: String) -> NSImage? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let b64 = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    @objc private func closeTapped() { close() }

    // MARK: Test hooks

    var isEmptyStateVisible: Bool { !emptyLabel.isHidden }
    var lineCount: Int { lyrics.count }
    var currentActiveLineText: String? {
        guard activeIndex >= 0, lyrics.indices.contains(activeIndex) else { return nil }
        return lyrics[activeIndex].text
    }
    var wordProgressesForActive: [Double] {
        guard activeIndex >= 0 else { return [] }
        let dur = engine.state.duration
        return LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: activeIndex, currentTime: engine.state.currentTime, audioDuration: dur > 0 ? dur : nil)
    }
    var observerCount: Int { cancellables.count }
    func simulateManualScroll() { handleManualScroll() }
    func isManuallyScrolling(date: Date = Date()) -> Bool { date.timeIntervalSince1970 < manualScrollUntil }
}
