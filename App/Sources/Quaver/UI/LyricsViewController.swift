import AppKit
import Combine
import QuartzCore

// MARK: - LyricsViewController
// Monochrome rebuild — no Liquid Glass on this page (user request).
// Strict single-clock: PlaybackEngine.currentTime → LyricSynchronizer → active line/word.
// Visual language lifted from monochrome web fullscreen:
//  • Solid opaque windowBackgroundColor (no NSVisualEffectView/NSGlassEffectView)
//  • Two-column editorial grid: LEFT media (artwork 280 + left-aligned meta + controls)
//    RIGHT large lyrics (30pt active, ─0.6 kern, #F6F4EF on faint 0.08, like
//    --lyplus-font-size-base clamp(34px,3vw,52px) / --lyplus-active-color)
//  • No desktop bleed, no connected glass sheet — this overlay is a coherent dark surface.

@MainActor
final class LyricsViewController: NSViewController {

    // MARK: Engine + State (single-clock contracts preserved)

    private let engine: PlaybackEngine
    private(set) var lyrics: [LyricLine] = []
    private(set) var activeIndex: Int = -1
    private var loadVersion = 0
    private var manualScrollUntil: TimeInterval = 0
    private(set) var isLyricsActive = false
    private var displayedTrackKey: String?
    private var cancellables = Set<AnyCancellable>()
    private var isAutoScrolling = false
    private(set) var syncCallCount = 0
    private(set) var lastCenteredIndex: Int? = nil

    private let manualGrace: TimeInterval = 4.5

    // Playback render diff — avoid rebuilding NSImage / attributed strings every 0.1s
    private var lastLyricsIsPlaying: Bool?
    private var lastLyricsShuffle: Bool?
    private var lastLyricsRepeat: RepeatMode?
    private var lastLyricsVolume: Double = -1
    private var lastLyricsElapsed: String = ""
    private var lastLyricsDuration: String = ""
    private var lastLyricsProgressDuration: Double = -1
    private var lastWordProgresses: [Double] = []
    private var lastWordActiveIndex: Int = -99

    // MARK: Overlay chrome — solid, no glass (this page only)

    private let dimmingView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        // True opaque — covers library completely, no blur, no desktop bleed.
        v.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        v.layer?.isOpaque = true
        return v
    }()

    // Full-window panel — coherent dark surface, not floating glass
    let panelView: NSView = {
        let v = NSView()
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.layer?.cornerRadius = 0
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        v.layer?.isOpaque = true
        return v
    }()

    private var panelGlassView: NSView? // kept for compat — stays nil (no glass on this page)

    private let panelBackgroundArtworkView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleAxesIndependently
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        // Very faint texture behind solid — like monochrome's subtle backdrop, not a wallpaper
        v.alphaValue = 0.06
        return v
    }()

    // MARK: LEFT COLUMN — media like monochrome's .fullscreen-media-column

    let artworkView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.masksToBounds = true
        v.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        v.contentTintColor = .secondaryLabelColor
        return v
    }()

    private let artworkFallbackView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        v.layer?.cornerRadius = 14
        v.isHidden = true
        return v
    }()

    let titleLabel: NSTextField = {
        let l = NSTextField(labelWithString: "No track")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 18, weight: .semibold)
        l.textColor = .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.alignment = .left
        return l
    }()

    let artistLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Select a song")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.alignment = .left
        return l
    }()

    let elapsedLabel: NSTextField = {
        let l = NSTextField(labelWithString: "0:00")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .left
        return l
    }()

    let durationLabel: NSTextField = {
        let l = NSTextField(labelWithString: "—:—")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        return l
    }()

    let progressSlider: NSSlider = {
        let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.controlSize = .small
        s.isContinuous = true
        return s
    }()

    let shuffleButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: "Shuffle")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Shuffle"
        return b
    }()

    let previousButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Previous")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.contentTintColor = .labelColor
        return b
    }()

    let playPauseButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        b.bezelStyle = .circular
        b.isBordered = true
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        b.contentTintColor = .labelColor
        return b
    }()

    let nextButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Next")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.contentTintColor = .labelColor
        return b
    }()

    let repeatButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Repeat")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Repeat"
        return b
    }()

    let volumeSlider: NSSlider = {
        let s = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.controlSize = .small
        s.isContinuous = true
        return s
    }()

    let volumeIcon: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)
        v.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        v.contentTintColor = .secondaryLabelColor
        return v
    }()

    // MARK: RIGHT COLUMN — large editorial lyrics

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.usesPredominantAxisScrolling = true
        sv.verticalScrollElasticity = .allowed
        sv.horizontalScrollElasticity = .none
        return sv
    }()

    private let stackView: NSStackView = {
        let s = NSStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 22
        // Monochrome airy padding — lyrics breathe, like --lyrics-scroll-padding-top 18%
        s.edgeInsets = NSEdgeInsets(top: 36, left: 12, bottom: 80, right: 12)
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
        l.font = .systemFont(ofSize: 15, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.isHidden = true
        return l
    }()

    let closeButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Close (Esc)"
        b.keyEquivalent = "\u{1b}"
        return b
    }()

    private let columnDivider: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        b.alphaValue = 0.10
        return b
    }()

    private let leftContainer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()
    private let rightContainer: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let headerTrackLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = .clear
        l.isHidden = true
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
        // Opaque host — no windowBackgroundColor bleed, no .clear letting library show through.
        // Monochrome fullscreen is solid #0a0a0a; match that here for the lyric-only opaque page.
        v.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.08, alpha: 1.0).cgColor
        v.layer?.isOpaque = true
        self.view = v
        view.isHidden = true
        view.appearance = NSAppearance(named: .vibrantDark)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupActions()
        bindEngine()
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    override func viewWillLayout() {
        super.viewWillLayout()
        panelView.frame = view.bounds
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        panelView.frame = view.bounds
    }

    private func setupUI() {
        // Dim — solid opaque (monochrome: no translucent veil, no desktop bleed)
        view.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let dimClick = NSClickGestureRecognizer(target: self, action: #selector(closeTapped))
        dimmingView.addGestureRecognizer(dimClick)

        // Panel — full-window solid editorial surface (no glass)
        panelView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panelView)
        NSLayoutConstraint.activate([
            panelView.topAnchor.constraint(equalTo: view.topAnchor),
            panelView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            panelView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            panelView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Very faint artwork texture behind solid (alpha 0.06) — tests check hasBackgroundArtwork via image, not alpha
        panelView.addSubview(panelBackgroundArtworkView)
        // No glass view on this page by design
        self.panelGlassView = nil

        NSLayoutConstraint.activate([
            panelBackgroundArtworkView.topAnchor.constraint(equalTo: panelView.topAnchor),
            panelBackgroundArtworkView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            panelBackgroundArtworkView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            panelBackgroundArtworkView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
        ])

        // Close — top trailing
        panelView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -20),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        closeButton.wantsLayer = true
        closeButton.layer?.zPosition = 10

        panelView.addSubview(headerTrackLabel)
        NSLayoutConstraint.activate([
            headerTrackLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 4),
            headerTrackLabel.centerXAnchor.constraint(equalTo: panelView.centerXAnchor),
            headerTrackLabel.widthAnchor.constraint(equalToConstant: 1),
            headerTrackLabel.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Grid: LEFT media (monochrome 340–430) / RIGHT lyrics (520–760), gap 48
        panelView.addSubview(leftContainer)
        panelView.addSubview(rightContainer)
        panelView.addSubview(columnDivider)

        NSLayoutConstraint.activate([
            leftContainer.centerYAnchor.constraint(equalTo: panelView.centerYAnchor),
            leftContainer.topAnchor.constraint(greaterThanOrEqualTo: panelView.topAnchor, constant: 36),
            leftContainer.bottomAnchor.constraint(lessThanOrEqualTo: panelView.bottomAnchor, constant: -36),
            leftContainer.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 40),
            leftContainer.widthAnchor.constraint(equalToConstant: 360),

            columnDivider.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 40),
            columnDivider.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -36),
            columnDivider.leadingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: 32),
            columnDivider.widthAnchor.constraint(equalToConstant: 1),

            rightContainer.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 32),
            rightContainer.leadingAnchor.constraint(equalTo: columnDivider.trailingAnchor, constant: 32),
            rightContainer.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -40),
            rightContainer.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -32),
        ])

        leftContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        rightContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setupLeftColumn()
        setupRightColumn()

        scrollView.contentView.postsBoundsChangedNotifications = true
    }

    private func setupLeftColumn() {
        leftContainer.addSubview(artworkView)
        leftContainer.addSubview(artworkFallbackView)
        leftContainer.addSubview(titleLabel)
        leftContainer.addSubview(artistLabel)
        leftContainer.addSubview(progressSlider)
        leftContainer.addSubview(elapsedLabel)
        leftContainer.addSubview(durationLabel)
        leftContainer.addSubview(shuffleButton)
        leftContainer.addSubview(previousButton)
        leftContainer.addSubview(playPauseButton)
        leftContainer.addSubview(nextButton)
        leftContainer.addSubview(repeatButton)
        leftContainer.addSubview(volumeIcon)
        leftContainer.addSubview(volumeSlider)

        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: leftContainer.topAnchor, constant: 8),
            artworkView.centerXAnchor.constraint(equalTo: leftContainer.centerXAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 280),
            artworkView.heightAnchor.constraint(equalToConstant: 280),

            artworkFallbackView.topAnchor.constraint(equalTo: artworkView.topAnchor),
            artworkFallbackView.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            artworkFallbackView.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            artworkFallbackView.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -4),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])

        NSLayoutConstraint.activate([
            progressSlider.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 18),
            progressSlider.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 4),
            progressSlider.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -4),
            progressSlider.heightAnchor.constraint(equalToConstant: 14),

            elapsedLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            elapsedLabel.leadingAnchor.constraint(equalTo: progressSlider.leadingAnchor),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),

            durationLabel.topAnchor.constraint(equalTo: progressSlider.bottomAnchor, constant: 4),
            durationLabel.trailingAnchor.constraint(equalTo: progressSlider.trailingAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])

        NSLayoutConstraint.activate([
            playPauseButton.topAnchor.constraint(equalTo: elapsedLabel.bottomAnchor, constant: 16),
            playPauseButton.centerXAnchor.constraint(equalTo: leftContainer.centerXAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 40),
            playPauseButton.heightAnchor.constraint(equalToConstant: 40),

            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -10),
            previousButton.widthAnchor.constraint(equalToConstant: 28),
            previousButton.heightAnchor.constraint(equalToConstant: 28),

            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            nextButton.heightAnchor.constraint(equalToConstant: 28),

            shuffleButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            shuffleButton.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -12),
            shuffleButton.widthAnchor.constraint(equalToConstant: 28),
            shuffleButton.heightAnchor.constraint(equalToConstant: 28),

            repeatButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            repeatButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 12),
            repeatButton.widthAnchor.constraint(equalToConstant: 28),
            repeatButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        NSLayoutConstraint.activate([
            volumeIcon.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 18),
            volumeIcon.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 48),
            volumeIcon.widthAnchor.constraint(equalToConstant: 16),
            volumeIcon.heightAnchor.constraint(equalToConstant: 16),
            volumeIcon.centerYAnchor.constraint(equalTo: volumeSlider.centerYAnchor),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 6),
            volumeSlider.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -48),
            volumeSlider.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeSlider.heightAnchor.constraint(equalToConstant: 14),
        ])

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        volumeSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func setupRightColumn() {
        rightContainer.addSubview(scrollView)
        rightContainer.addSubview(emptyLabel)

        documentView.addSubview(stackView)
        scrollView.documentView = documentView
        scrollView.automaticallyAdjustsContentInsets = false

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: rightContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: rightContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: rightContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: rightContainer.bottomAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: rightContainer.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: rightContainer.centerYAnchor),
        ])
    }

    private func setupActions() {
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        previousButton.target = self
        previousButton.action = #selector(previousTapped)
        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseTapped)
        nextButton.target = self
        nextButton.action = #selector(nextTapped)
        shuffleButton.target = self
        shuffleButton.action = #selector(shuffleTapped)
        repeatButton.target = self
        repeatButton.action = #selector(repeatTapped)
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
    }

    private func bindEngine() {
        engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handleEngineState(state) }
            .store(in: &cancellables)
    }

    // MARK: Engine state — single clock

    private func handleEngineState(_ state: PlaybackState) {
        let cur = engine.currentTrack
        let key = cur?.key
        if key != displayedTrackKey {
            displayedTrackKey = key
            Task { await self.loadLyrics(for: cur) }
            let t = cur?.title.isEmpty == false ? cur!.title : (cur?.path as NSString?)?.lastPathComponent ?? "No track"
            let a = cur?.artist.isEmpty == false ? cur!.artist : "Unknown Artist"
            titleLabel.stringValue = t
            artistLabel.stringValue = a
            headerTrackLabel.stringValue = cur.map { "\($0.title) — \($0.artist)" } ?? ""
            if let url = cur?.coverDataURL, let img = CoverImageCache.image(fromDataURL: url) {
                artworkView.image = img
                artworkView.contentTintColor = nil
                artworkFallbackView.isHidden = true
                panelBackgroundArtworkView.image = img
                panelBackgroundArtworkView.isHidden = false
            } else {
                artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
                artworkView.contentTintColor = .secondaryLabelColor
                artworkFallbackView.isHidden = false
                panelBackgroundArtworkView.image = nil
                panelBackgroundArtworkView.isHidden = true
            }
        }
        renderPlaybackState(state)
        sync(currentTime: state.currentTime)
    }

    private func renderPlaybackState(_ state: PlaybackState) {
        // Diff-gated: avoid NSImage creation + attributed string churn every 0.1s
        if state.isPlaying != lastLyricsIsPlaying {
            lastLyricsIsPlaying = state.isPlaying
            let imgName = state.isPlaying ? "pause.fill" : "play.fill"
            playPauseButton.image = NSImage(systemSymbolName: imgName, accessibilityDescription: state.isPlaying ? "Pause" : "Play")
            playPauseButton.toolTip = state.isPlaying ? "Pause" : "Play"
        }
        if state.isShuffle != lastLyricsShuffle {
            lastLyricsShuffle = state.isShuffle
            shuffleButton.contentTintColor = state.isShuffle ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            shuffleButton.toolTip = state.isShuffle ? "Shuffle on" : "Shuffle off"
        }
        if state.repeatMode != lastLyricsRepeat {
            lastLyricsRepeat = state.repeatMode
            switch state.repeatMode {
            case .off:
                repeatButton.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Repeat off")
                repeatButton.contentTintColor = .secondaryLabelColor
                repeatButton.toolTip = "Repeat off"
            case .all:
                repeatButton.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Repeat all")
                repeatButton.contentTintColor = .controlAccentColor
                repeatButton.toolTip = "Repeat all"
            case .one:
                repeatButton.image = NSImage(systemSymbolName: "repeat.1", accessibilityDescription: "Repeat one")
                repeatButton.contentTintColor = .controlAccentColor
                repeatButton.toolTip = "Repeat one"
            }
        }
        if abs(state.volume - lastLyricsVolume) > 0.005 {
            lastLyricsVolume = state.volume
            if abs(volumeSlider.doubleValue - state.volume) > 0.01 {
                volumeSlider.doubleValue = state.volume
            }
            let volIcon = state.volume == 0 ? "speaker.slash.fill" : (state.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
            volumeIcon.image = NSImage(systemSymbolName: volIcon, accessibilityDescription: nil)
        }
        let isTracking = progressSlider.cell?.isHighlighted == true
        if !isTracking {
            if state.duration != lastLyricsProgressDuration {
                lastLyricsProgressDuration = state.duration
                let dur = state.duration
                progressSlider.maxValue = dur > 0 ? dur : 1
                progressSlider.isEnabled = dur > 0 && engine.currentTrack != nil
                let newDur = dur > 0 ? Self.formatDuration(dur) : "—:—"
                if newDur != lastLyricsDuration {
                    lastLyricsDuration = newDur
                    durationLabel.stringValue = newDur
                }
            }
            progressSlider.doubleValue = state.currentTime
        }
        let newElapsed = Self.formatDuration(state.currentTime)
        if newElapsed != lastLyricsElapsed {
            lastLyricsElapsed = newElapsed
            elapsedLabel.stringValue = newElapsed
        }
    }

    // MARK: Lyrics loading

    func load(_ newLyrics: [LyricLine]) {
        loadVersion += 1
        lyrics = newLyrics
        activeIndex = -1
        renderLyrics()
        sync(currentTime: engine.state.currentTime)
    }

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
        lyrics = []
        activeIndex = -1
        renderLyrics()
        guard let track, let lyricPath = track.lyricPath, !lyricPath.isEmpty else { return }
        let content: String? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let c = QuaverCore.readLyricsFileIfPresent(at: lyricPath)
                cont.resume(returning: c)
            }
        }
        guard myVersion == loadVersion else { return }
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
        updateLineStyles()
    }

    // MARK: Sync — single clock

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
        // Only the active line animates karaoke; inactive lines are reset once on switch,
        // not every 100ms. Diff against last progresses to skip redundant attributedString churn.
        guard lyrics.indices.contains(lineIndex) else {
            if lastWordActiveIndex >= 0, stackView.arrangedSubviews.indices.contains(lastWordActiveIndex),
               let prev = stackView.arrangedSubviews[lastWordActiveIndex] as? LyricLineView {
                prev.updateWordProgresses([])
            }
            lastWordActiveIndex = -1
            lastWordProgresses = []
            return
        }
        let dur = engine.state.duration
        let progresses = LyricSynchronizer.wordProgresses(lyrics: lyrics, lineIndex: lineIndex, currentTime: currentTime, audioDuration: dur > 0 ? dur : nil)
        let eps = 0.015
        let sameLine = lineIndex == lastWordActiveIndex && lastWordProgresses.count == progresses.count
        if sameLine {
            var changed = false
            for (a, b) in zip(lastWordProgresses, progresses) where abs(a - b) > eps { changed = true; break }
            if !changed { return }
        }
        if lastWordActiveIndex != lineIndex, lastWordActiveIndex >= 0,
           stackView.arrangedSubviews.indices.contains(lastWordActiveIndex),
           let prev = stackView.arrangedSubviews[lastWordActiveIndex] as? LyricLineView {
            prev.updateWordProgresses([])
        }
        if stackView.arrangedSubviews.indices.contains(lineIndex),
           let lv = stackView.arrangedSubviews[lineIndex] as? LyricLineView {
            lv.updateWordProgresses(progresses)
        }
        lastWordActiveIndex = lineIndex
        lastWordProgresses = progresses
    }

    private func centerActiveLine(animated: Bool) {
        guard activeIndex >= 0, stackView.arrangedSubviews.indices.contains(activeIndex) else { return }
        guard Date().timeIntervalSince1970 >= manualScrollUntil else { return }
        let lineView = stackView.arrangedSubviews[activeIndex]
        lastCenteredIndex = activeIndex
        let visibleRect = lineView.frame
        let clip = scrollView.contentView
        guard clip.bounds.height > 0 else { return }
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

    func clickLyric(at index: Int) {
        guard lyrics.indices.contains(index) else { return }
        let t = lyrics[index].time
        manualScrollUntil = 0
        engine.seek(to: t)
    }

    func clickWord(line lineIndex: Int, word wordIndex: Int) {
        guard lyrics.indices.contains(lineIndex) else { return }
        let line = lyrics[lineIndex]
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
        if isLyricsActive && !view.isHidden && !isAutoScrolling { }
    }

    @objc private func playPauseTapped() { engine.togglePlay() }
    @objc private func previousTapped() { engine.previous() }
    @objc private func nextTapped() { engine.next() }
    @objc private func shuffleTapped() { engine.setShuffle(!engine.state.isShuffle) }
    @objc private func repeatTapped() {
        let next: RepeatMode
        switch engine.state.repeatMode {
        case .off: next = .all
        case .all: next = .one
        case .one: next = .off
        }
        engine.setRepeatMode(next)
    }
    @objc private func progressChanged() { engine.seek(to: progressSlider.doubleValue) }
    @objc private func volumeChanged() { engine.setVolume(volumeSlider.doubleValue) }

    func open() {
        isLyricsActive = true
        activeIndex = -1
        lastWordActiveIndex = -99
        lastWordProgresses = []
        manualScrollUntil = 0
        if let cur = engine.currentTrack {
            let t = cur.title.isEmpty ? (cur.path as NSString).lastPathComponent : cur.title
            let a = cur.artist.isEmpty ? "Unknown Artist" : cur.artist
            titleLabel.stringValue = t
            artistLabel.stringValue = a
            headerTrackLabel.stringValue = "\(cur.title) — \(cur.artist)"
            if let url = cur.coverDataURL, let img = CoverImageCache.image(fromDataURL: url) {
                artworkView.image = img
                artworkView.contentTintColor = nil
                artworkFallbackView.isHidden = true
                panelBackgroundArtworkView.image = img
                panelBackgroundArtworkView.isHidden = false
            } else {
                artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
                artworkView.contentTintColor = .secondaryLabelColor
                artworkFallbackView.isHidden = false
                panelBackgroundArtworkView.image = nil
                panelBackgroundArtworkView.isHidden = true
            }
        }
        renderPlaybackState(engine.state)
        view.isHidden = false
        if lyrics.isEmpty {
            scrollView.contentView.setBoundsOrigin(.zero)
        } else {
            sync(currentTime: engine.state.currentTime)
            let savedGrace = manualScrollUntil
            manualScrollUntil = 0
            centerActiveLine(animated: false)
            manualScrollUntil = savedGrace
        }
        if view.window == nil {
            view.alphaValue = 1
            panelView.alphaValue = 1
        } else {
            view.alphaValue = 0
            panelView.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
                panelView.animator().alphaValue = 1
            }, completionHandler: nil)
        }
    }

    func close() {
        isLyricsActive = false
        isAutoScrolling = false
        lastCenteredIndex = nil
        lastWordActiveIndex = -99
        lastWordProgresses = []
        if view.window == nil {
            view.isHidden = true
            view.alphaValue = 1
            panelView.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
            panelView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isLyricsActive else {
                    self.view.alphaValue = 1
                    self.panelView.alphaValue = 1
                    return
                }
                self.view.isHidden = true
                self.view.alphaValue = 1
                self.panelView.alphaValue = 1
            }
        })
    }

    func destroy() {
        cancellables.removeAll()
        close()
    }

    deinit { cancellables.removeAll() }

    private static func image(fromDataURL url: String) -> NSImage? {
        CoverImageCache.image(fromDataURL: url)
    }

    private static func formatDuration(_ secs: Double) -> String {
        guard secs.isFinite, secs > 0 else { return "0:00" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }

    @objc private func closeTapped() { close() }

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
    var isPanelVisible: Bool { !view.isHidden && !panelView.isHidden }
    var panelCornerRadius: CGFloat { panelView.layer?.cornerRadius ?? 0 }
    var hasArtworkImage: Bool { artworkView.image != nil }
    var hasBackgroundArtwork: Bool { panelBackgroundArtworkView.image != nil }
    var isDimmingVisible: Bool { !dimmingView.isHidden }
}
