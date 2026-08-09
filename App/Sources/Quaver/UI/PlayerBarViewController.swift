import AppKit
import Combine

// MARK: - PlayerBarViewController
// Native mini-player bottom bar. Pure AppKit, SF Symbols, no WKWebView.
// Single source of truth: PlaybackEngine. No independent clock, no duplicated state.

@MainActor
protocol PlayerBarViewControllerDelegate: AnyObject {
    func playerBarDidRequestQueue(_ bar: PlayerBarViewController)
    func playerBarDidRequestLyrics(_ bar: PlayerBarViewController)
}

@MainActor
final class PlayerBarViewController: NSViewController {

    weak var delegate: PlayerBarViewControllerDelegate?

    // MARK: Engine

    private let engine: PlaybackEngine
    private var cancellables = Set<AnyCancellable>()

    // MARK: UI — separator

    private let topSeparator: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        return b
    }()

    // Left: artwork + labels

    private let artworkView: NSImageView = {
        let v = NSImageView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        v.layer?.masksToBounds = true
        v.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
        v.contentTintColor = .secondaryLabelColor
        return v
    }()

    private let titleLabel: NSTextField = {
        let l = NSTextField(labelWithString: "No track")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        return l
    }()

    private let artistLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Select a song to play")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        return l
    }()

    // Center: transport + progress

    let previousButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Previous")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        b.contentTintColor = .labelColor
        b.toolTip = "Previous"
        return b
    }()

    let playPauseButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        b.bezelStyle = .texturedRounded
        b.isBordered = true
        b.bezelStyle = .circular
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        b.contentTintColor = .labelColor
        b.toolTip = "Play"
        return b
    }()

    let nextButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Next")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        b.contentTintColor = .labelColor
        b.toolTip = "Next"
        return b
    }()

    let elapsedLabel: NSTextField = {
        let l = NSTextField(labelWithString: "0:00")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }()

    let durationLabel: NSTextField = {
        let l = NSTextField(labelWithString: "—:—")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .left
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }()

    let progressSlider: SeekSlider = {
        let s = SeekSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.controlSize = .small
        s.isContinuous = true
        return s
    }()

    // Right: shuffle / repeat / volume / queue

    let shuffleButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: "Shuffle")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Shuffle"
        return b
    }()

    let repeatButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "repeat", accessibilityDescription: "Repeat")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
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

    let queueButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: "Queue")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Queue"
        return b
    }()

    let lyricsButton: NSButton = {
        let b = NSButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: "Lyrics")
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Lyrics"
        return b
    }()

    // MARK: Init

    init(engine: PlaybackEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: Lifecycle

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1.0).cgColor
        self.view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        setupActions()
        bindEngine()
        render(engine.state)
        view.setAccessibilityLabel("Player")
    }

    // MARK: Layout

    private func setupLayout() {
        view.addSubview(topSeparator)
        view.addSubview(artworkView)
        view.addSubview(titleLabel)
        view.addSubview(artistLabel)
        view.addSubview(previousButton)
        view.addSubview(playPauseButton)
        view.addSubview(nextButton)
        view.addSubview(elapsedLabel)
        view.addSubview(durationLabel)
        view.addSubview(progressSlider)
        view.addSubview(shuffleButton)
        view.addSubview(repeatButton)
        view.addSubview(volumeIcon)
        view.addSubview(volumeSlider)
        view.addSubview(lyricsButton)
        view.addSubview(queueButton)

        NSLayoutConstraint.activate([
            // Overall height
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 72),

            // Separator
            topSeparator.topAnchor.constraint(equalTo: view.topAnchor),
            topSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topSeparator.heightAnchor.constraint(equalToConstant: 1),

            // Left: artwork
            artworkView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            artworkView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 2),
            artworkView.widthAnchor.constraint(equalToConstant: 44),
            artworkView.heightAnchor.constraint(equalToConstant: 44),

            // Labels to the right of artwork
            titleLabel.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 10),
            titleLabel.topAnchor.constraint(equalTo: artworkView.topAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: previousButton.leadingAnchor, constant: -16),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            artistLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            artistLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            artistLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),

            // Center transport: horizontally centered as a group
            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 10),
            playPauseButton.widthAnchor.constraint(equalToConstant: 36),
            playPauseButton.heightAnchor.constraint(equalToConstant: 36),

            previousButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -12),
            previousButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            previousButton.widthAnchor.constraint(equalToConstant: 28),
            previousButton.heightAnchor.constraint(equalToConstant: 28),

            nextButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 12),
            nextButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 28),
            nextButton.heightAnchor.constraint(equalToConstant: 28),

            // Progress row below transport, centered
            elapsedLabel.trailingAnchor.constraint(equalTo: progressSlider.leadingAnchor, constant: -8),
            elapsedLabel.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),
            elapsedLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            progressSlider.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            progressSlider.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 8),
            progressSlider.widthAnchor.constraint(equalToConstant: 340),
            progressSlider.heightAnchor.constraint(equalToConstant: 16),

            durationLabel.leadingAnchor.constraint(equalTo: progressSlider.trailingAnchor, constant: 8),
            durationLabel.centerYAnchor.constraint(equalTo: progressSlider.centerYAnchor),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36),

            // Right cluster — lyrics sits left of shuffle
            lyricsButton.trailingAnchor.constraint(equalTo: shuffleButton.leadingAnchor, constant: -8),
            lyricsButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 8),
            lyricsButton.widthAnchor.constraint(equalToConstant: 28),
            lyricsButton.heightAnchor.constraint(equalToConstant: 28),

            shuffleButton.trailingAnchor.constraint(equalTo: repeatButton.leadingAnchor, constant: -8),
            shuffleButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 8),
            shuffleButton.widthAnchor.constraint(equalToConstant: 28),
            shuffleButton.heightAnchor.constraint(equalToConstant: 28),

            repeatButton.trailingAnchor.constraint(equalTo: volumeIcon.leadingAnchor, constant: -16),
            repeatButton.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor),
            repeatButton.widthAnchor.constraint(equalToConstant: 28),
            repeatButton.heightAnchor.constraint(equalToConstant: 28),

            volumeIcon.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor),
            volumeIcon.widthAnchor.constraint(equalToConstant: 16),
            volumeIcon.heightAnchor.constraint(equalToConstant: 16),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 6),
            volumeSlider.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 90),

            queueButton.leadingAnchor.constraint(equalTo: volumeSlider.trailingAnchor, constant: 12),
            queueButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            queueButton.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor),
            queueButton.widthAnchor.constraint(equalToConstant: 28),
            queueButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Compression priorities so center stays and sides compress first
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        artistLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressSlider.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    private func setupActions() {
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
        queueButton.target = self
        queueButton.action = #selector(queueTapped)
        lyricsButton.target = self
        lyricsButton.action = #selector(lyricsTapped)
        progressSlider.target = self
        progressSlider.action = #selector(progressChanged)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
    }

    // MARK: Engine binding — single source of truth

    private func bindEngine() {
        engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
    }

    private func render(_ state: PlaybackState) {
        // Artwork / title / artist from currentTrack
        if let track = engine.currentTrack {
            let displayTitle = track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title
            let displayArtist = track.artist.isEmpty ? "Unknown Artist" : track.artist
            titleLabel.stringValue = displayTitle
            artistLabel.stringValue = displayArtist
            if let dataURL = track.coverDataURL, let img = Self.image(fromDataURL: dataURL) {
                artworkView.image = img
                artworkView.contentTintColor = nil
            } else {
                artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
                artworkView.contentTintColor = .secondaryLabelColor
            }
            playPauseButton.isEnabled = true
            previousButton.isEnabled = true
            nextButton.isEnabled = true
            progressSlider.isEnabled = state.duration > 0
        } else {
            titleLabel.stringValue = "No track"
            artistLabel.stringValue = "Select a song to play"
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .secondaryLabelColor
            playPauseButton.isEnabled = false
            previousButton.isEnabled = false
            nextButton.isEnabled = false
            progressSlider.isEnabled = false
        }

        // Play/pause
        let playImageName = state.isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.image = NSImage(systemSymbolName: playImageName, accessibilityDescription: state.isPlaying ? "Pause" : "Play")
        playPauseButton.toolTip = state.isPlaying ? "Pause" : "Play"
        playPauseButton.setAccessibilityLabel(state.isPlaying ? "Pause" : "Play")

        // Shuffle
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

        // Progress — do not fight the user's drag
        if !progressSlider.isTrackingSeek {
            let dur = state.duration
            progressSlider.maxValue = dur > 0 ? dur : 1
            progressSlider.doubleValue = state.currentTime
        }
        elapsedLabel.stringValue = Self.formatDuration(state.currentTime)
        durationLabel.stringValue = state.duration > 0 ? Self.formatDuration(state.duration) : "—:—"
    }

    // MARK: Actions

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
    @objc private func queueTapped() { delegate?.playerBarDidRequestQueue(self) }
    @objc private func lyricsTapped() { delegate?.playerBarDidRequestLyrics(self) }
    @objc private func progressChanged() { engine.seek(to: progressSlider.doubleValue) }
    @objc private func volumeChanged() { engine.setVolume(volumeSlider.doubleValue) }

    // MARK: Helpers

    private static func formatDuration(_ secs: Double) -> String {
        guard secs.isFinite, secs > 0 else { return "0:00" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func image(fromDataURL url: String) -> NSImage? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let b64 = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Test hooks

    var currentTitle: String { titleLabel.stringValue }
    var currentArtist: String { artistLabel.stringValue }
    var isPlayPauseEnabled: Bool { playPauseButton.isEnabled }
    var playPauseImageName: String { engine.state.isPlaying ? "pause.fill" : "play.fill" }
    var shuffleActive: Bool { engine.state.isShuffle }
    var repeatModeCurrent: RepeatMode { engine.state.repeatMode }
    var elapsedText: String { elapsedLabel.stringValue }
    var durationText: String { durationLabel.stringValue }
    var progressValue: Double { progressSlider.doubleValue }
    var progressMax: Double { progressSlider.maxValue }
    var isProgressEnabled: Bool { progressSlider.isEnabled }
    var volumeValue: Double { volumeSlider.doubleValue }
    var artworkHasImage: Bool { artworkView.image != nil }
    var isTrackingSeek: Bool { progressSlider.isTrackingSeek }
}
