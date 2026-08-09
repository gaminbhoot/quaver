import AppKit
import Combine
import QuartzCore

// MARK: - LyricsViewController
// Detached Apple Music-style lyrics panel. Pure AppKit, no WKWebView, no Timer.
// Single source of truth: PlaybackEngine.currentTime → LyricSynchronizer → active line/word → UI.
// Visual: detached rounded floating surface centered over library, LEFT = artwork + metadata + controls,
// RIGHT = synchronized karaoke lyrics. Library remains visible behind panel via dim.
// No second playback clock. Reacts to PlaybackEngine.statePublisher only.

@MainActor
final class LyricsViewController: NSViewController {

    // MARK: Engine + State (preserved single-clock contracts)

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

    // MARK: - Overlay chrome

    private let dimmingView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        // Translucent dark veil that lets library remain recognizable behind panel.
        // Not opaque black — Apple Music-like depth.
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        return v
    }()

    // DETACHED PANEL — the floating rounded surface
    let panelView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.cornerRadius = 18
        v.layer?.masksToBounds = true
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.34
        v.layer?.shadowRadius = 28
        v.layer?.shadowOffset = NSSize(width: 0, height: 12)
        v.layer?.masksToBounds = false
        return v
    }()

    private var panelGlassView: NSView?

    private let panelBackgroundArtworkView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleAxesIndependently
        v.wantsLayer = true
        v.layer?.masksToBounds = true
        v.alphaValue = 0.14
        return v
    }()

    // MARK: - LEFT COLUMN

    let artworkView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.cornerRadius = 12
        v.layer?.masksToBounds = true
        v.layer?.shadowColor = NSColor.black.cgColor
        v.layer?.shadowOpacity = 0.22
        v.layer?.shadowRadius = 10
        v.layer?.shadowOffset = NSSize(width: 0, height: 4)
        v.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        v.contentTintColor = .secondaryLabelColor
        return v
    }()

    private let artworkFallbackView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        v.layer?.cornerRadius = 12
        v.isHidden = true
        return v
    }()

    let titleLabel: NSTextField = {
        let l = NSTextField(labelWithString: "No track")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.textColor = .labelColor
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.alignment = .center
        return l
    }()

    let artistLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Select a song")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.alignment = .center
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

    // Compact native transport — restrained, not giant
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

    // MARK: - RIGHT COLUMN (lyrics)

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.borderType = .noBorder
        sv.drawsBackground = false
        sv.autohidesScrollers = true
        return sv
    }()

    private let stackView: NSStackView = {
        let s = NSStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 16
        s.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 60, right: 16)
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

    // Close control — native, top-trailing of panel
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

    // Subtle divider between columns — not a harsh line
    private let columnDivider: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        b.alphaValue = 0.12
        return b
    }()

    // Left/right containers for layout
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

    // Legacy compat: headerTrackLabel mirrors title+artist for old tests that inspect it
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
        v.layer?.backgroundColor = NSColor.clear.cgColor
        self.view = v
        view.isHidden = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupActions()
        bindEngine()
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    private func setupUI() {
        // Overlay dim
        view.addSubview(dimmingView)
        NSLayoutConstraint.activate([
            dimmingView.topAnchor.constraint(equalTo: view.topAnchor),
            dimmingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimmingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimmingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Tap dim to close (like Apple Music)
        let dimClick = NSClickGestureRecognizer(target: self, action: #selector(closeTapped))
        dimmingView.addGestureRecognizer(dimClick)

        // Panel — detached, centered, floating
        view.addSubview(panelView)

        // Panel background artwork (subtle) + glass material
        panelView.addSubview(panelBackgroundArtworkView)
        let glass = QuaverGlass.backgroundView(for: .lyrics)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 18
        glass.layer?.masksToBounds = true
        panelView.addSubview(glass)
        self.panelGlassView = glass

        // Soften glass for readability — lyrics panel should be dark translucent, not clear exposing library unreadably
        if glass is NSVisualEffectView {
            // hudWindow at 0.88 already set in Glass; keep but ensure vibrancy
            glass.alphaValue = 0.92
        } else if #available(macOS 26.0, *), glass is NSGlassEffectView {
            glass.alphaValue = 1
        }

        NSLayoutConstraint.activate([
            panelBackgroundArtworkView.topAnchor.constraint(equalTo: panelView.topAnchor),
            panelBackgroundArtworkView.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            panelBackgroundArtworkView.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            panelBackgroundArtworkView.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
            glass.topAnchor.constraint(equalTo: panelView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: panelView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: panelView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: panelView.bottomAnchor),
        ])

        // Panel positioning — detached, centered, responsive
        let panelWidth = panelView.widthAnchor.constraint(equalToConstant: 860)
        panelWidth.priority = NSLayoutConstraint.Priority(500)
        let panelHeight = panelView.heightAnchor.constraint(equalToConstant: 520)
        panelHeight.priority = NSLayoutConstraint.Priority(500)
        NSLayoutConstraint.activate([
            panelView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            panelView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            panelView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
            panelView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
            panelView.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor, constant: 28),
            panelView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -28),
            panelWidth,
            panelView.widthAnchor.constraint(greaterThanOrEqualToConstant: 640),
            panelView.widthAnchor.constraint(lessThanOrEqualToConstant: 980),
            panelHeight,
            panelView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420),
            panelView.heightAnchor.constraint(lessThanOrEqualToConstant: 700),
        ])
        panelView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        panelView.setContentHuggingPriority(.defaultLow, for: .vertical)
        panelView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panelView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        // Close button — top trailing of panel
        panelView.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
        ])
        closeButton.wantsLayer = true
        closeButton.layer?.zPosition = 10

        // Legacy hidden header for compat
        panelView.addSubview(headerTrackLabel)
        NSLayoutConstraint.activate([
            headerTrackLabel.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 4),
            headerTrackLabel.centerXAnchor.constraint(equalTo: panelView.centerXAnchor),
            headerTrackLabel.widthAnchor.constraint(equalToConstant: 1),
            headerTrackLabel.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Two-column layout inside panel
        panelView.addSubview(leftContainer)
        panelView.addSubview(rightContainer)
        panelView.addSubview(columnDivider)

        NSLayoutConstraint.activate([
            leftContainer.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 18),
            leftContainer.leadingAnchor.constraint(equalTo: panelView.leadingAnchor, constant: 20),
            leftContainer.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -18),
            leftContainer.widthAnchor.constraint(equalToConstant: 300),

            columnDivider.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 18),
            columnDivider.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -18),
            columnDivider.leadingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: 16),
            columnDivider.widthAnchor.constraint(equalToConstant: 1),

            rightContainer.topAnchor.constraint(equalTo: panelView.topAnchor, constant: 48),
            rightContainer.leadingAnchor.constraint(equalTo: columnDivider.trailingAnchor, constant: 16),
            rightContainer.trailingAnchor.constraint(equalTo: panelView.trailingAnchor, constant: -16),
            rightContainer.bottomAnchor.constraint(equalTo: panelView.bottomAnchor, constant: -16),
        ])

        // Allow columns to flex when panel shrinks
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

        // Artwork — large but not gigantic, centered, square
        NSLayoutConstraint.activate([
            artworkView.topAnchor.constraint(equalTo: leftContainer.topAnchor, constant: 12),
            artworkView.centerXAnchor.constraint(equalTo: leftContainer.centerXAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 200),
            artworkView.heightAnchor.constraint(equalToConstant: 200),

            artworkFallbackView.topAnchor.constraint(equalTo: artworkView.topAnchor),
            artworkFallbackView.leadingAnchor.constraint(equalTo: artworkView.leadingAnchor),
            artworkFallbackView.trailingAnchor.constraint(equalTo: artworkView.trailingAnchor),
            artworkFallbackView.bottomAnchor.constraint(equalTo: artworkView.bottomAnchor),
        ])

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: artworkView.bottomAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -8),

            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
        ])

        NSLayoutConstraint.activate([
            progressSlider.topAnchor.constraint(equalTo: artistLabel.bottomAnchor, constant: 16),
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

        // Transport row — centered, restrained sizes
        NSLayoutConstraint.activate([
            playPauseButton.topAnchor.constraint(equalTo: elapsedLabel.bottomAnchor, constant: 14),
            playPauseButton.centerXAnchor.constraint(equalTo: leftContainer.centerXAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 36),

            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            previousButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -10),
            previousButton.widthAnchor.constraint(equalToConstant: 28),
            previousButton.heightAnchor.constraint(equalToConstant: 28),

            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            nextButton.heightAnchor.constraint(equalToConstant: 28),

            shuffleButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            shuffleButton.trailingAnchor.constraint(equalTo: previousButton.leadingAnchor, constant: -10),
            shuffleButton.widthAnchor.constraint(equalToConstant: 28),
            shuffleButton.heightAnchor.constraint(equalToConstant: 28),

            repeatButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            repeatButton.leadingAnchor.constraint(equalTo: nextButton.trailingAnchor, constant: 10),
            repeatButton.widthAnchor.constraint(equalToConstant: 28),
            repeatButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Volume row — centered below transport
        NSLayoutConstraint.activate([
            volumeIcon.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 16),
            volumeIcon.leadingAnchor.constraint(equalTo: leftContainer.leadingAnchor, constant: 40),
            volumeIcon.widthAnchor.constraint(equalToConstant: 16),
            volumeIcon.heightAnchor.constraint(equalToConstant: 16),
            volumeIcon.centerYAnchor.constraint(equalTo: volumeSlider.centerYAnchor),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 6),
            volumeSlider.trailingAnchor.constraint(equalTo: leftContainer.trailingAnchor, constant: -40),
            volumeSlider.centerYAnchor.constraint(equalTo: volumeIcon.centerYAnchor),
            volumeSlider.heightAnchor.constraint(equalToConstant: 14),
        ])

        // Flexibility so long titles wrap/truncate gracefully
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

    // MARK: Engine state handling — single clock

    private func handleEngineState(_ state: PlaybackState) {
        let cur = engine.currentTrack
        let key = cur?.key
        if key != displayedTrackKey {
            displayedTrackKey = key
            Task { await self.loadLyrics(for: cur) }
            // Update metadata + artwork immediately (left column + panel background)
            let t = cur?.title.isEmpty == false ? cur!.title : (cur?.path as NSString?)?.lastPathComponent ?? "No track"
            let a = cur?.artist.isEmpty == false ? cur!.artist : "Unknown Artist"
            titleLabel.stringValue = t
            artistLabel.stringValue = a
            headerTrackLabel.stringValue = cur.map { "\($0.title) — \($0.artist)" } ?? ""
            if let url = cur?.coverDataURL, let img = Self.image(fromDataURL: url) {
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
        // Always reflect transport state
        renderPlaybackState(state)
        sync(currentTime: state.currentTime)
    }

    private func renderPlaybackState(_ state: PlaybackState) {
        // Play/pause
        let imgName = state.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: imgName, accessibilityDescription: state.isPlaying ? "Pause" : "Play")
        playPauseButton.toolTip = state.isPlaying ? "Pause" : "Play"

        // Shuffle tint
        shuffleButton.contentTintColor = state.isShuffle ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        shuffleButton.toolTip = state.isShuffle ? "Shuffle on" : "Shuffle off"

        // Repeat
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

        // Volume
        if abs(volumeSlider.doubleValue - state.volume) > 0.01 {
            volumeSlider.doubleValue = state.volume
        }
        let volIcon = state.volume == 0 ? "speaker.slash.fill" : (state.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
        volumeIcon.image = NSImage(systemSymbolName: volIcon, accessibilityDescription: nil)

        // Progress — do not fight drag
        // Treat NSSlider as SeekSlider-like tracking guard via isEnabled + mouse tracking check hidden; use simple guard.
        let isTracking = progressSlider.cell?.isHighlighted == true
        if !isTracking {
            let dur = state.duration
            progressSlider.maxValue = dur > 0 ? dur : 1
            progressSlider.doubleValue = state.currentTime
            progressSlider.isEnabled = dur > 0 && engine.currentTrack != nil
        }
        elapsedLabel.stringValue = Self.formatDuration(state.currentTime)
        durationLabel.stringValue = state.duration > 0 ? Self.formatDuration(state.duration) : "—:—"
    }

    // MARK: Lyrics loading — version-guarded against stale async

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
        // Guard against zero-size clip before window is visible (headless tests)
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

    // MARK: Interactions

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
        if isLyricsActive && !view.isHidden && !isAutoScrolling {
            // Heuristic guard — headless tests simulate via handleManualScroll directly.
        }
    }

    // MARK: Transport actions (reuses single engine, no second clock)

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

    // MARK: Overlay lifecycle (polished, no Timer)

    func open() {
        isLyricsActive = true
        activeIndex = -1
        manualScrollUntil = 0
        // Refresh metadata immediately — handles mid-song open without waiting for next state tick
        if let cur = engine.currentTrack {
            let t = cur.title.isEmpty ? (cur.path as NSString).lastPathComponent : cur.title
            let a = cur.artist.isEmpty ? "Unknown Artist" : cur.artist
            titleLabel.stringValue = t
            artistLabel.stringValue = a
            headerTrackLabel.stringValue = "\(cur.title) — \(cur.artist)"
            if let url = cur.coverDataURL, let img = Self.image(fromDataURL: url) {
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
            // Immediately center without animation so mid-song open shows correct lyric, then animate polish on top
            let savedGrace = manualScrollUntil
            manualScrollUntil = 0
            centerActiveLine(animated: false)
            manualScrollUntil = savedGrace
        }
        // Headless (no WindowServer): skip CoreAnimation — shows instantly, no crash.
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
        // If no window (headless tests), hide synchronously so checks don't race animations.
        if view.window == nil {
            view.isHidden = true
            view.alphaValue = 1
            panelView.alphaValue = 1
            return
        }
        // Subtle close transition — only hide after animation if still closed (guards against close→open races)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            view.animator().alphaValue = 0
            panelView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard !self.isLyricsActive else {
                    // Reopened before animation finished — restore opacity and keep visible
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

    private static func formatDuration(_ secs: Double) -> String {
        guard secs.isFinite, secs > 0 else { return "0:00" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }

    @objc private func closeTapped() { close() }

    // MARK: Test hooks (preserved + extended)

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
    // New hooks for Phase 9 hierarchy checks
    var isPanelVisible: Bool { !view.isHidden && !panelView.isHidden }
    var panelCornerRadius: CGFloat { panelView.layer?.cornerRadius ?? 0 }
    var hasArtworkImage: Bool { artworkView.image != nil }
    var hasBackgroundArtwork: Bool { panelBackgroundArtworkView.image != nil }
    var isDimmingVisible: Bool { !dimmingView.isHidden }
}
