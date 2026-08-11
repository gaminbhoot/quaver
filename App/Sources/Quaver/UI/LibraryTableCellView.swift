import AppKit

// MARK: - LibraryTableCellView
// Native cell for the library NSTableView. Shows artwork + title/artist stacked.
// No WebView. Pure AppKit + Auto Layout.

final class LibraryTableCellView: NSTableCellView {

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("LibraryTableCellView")

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
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .regular)
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private let artistLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byTruncatingTail
        return l
    }()

    private let stack: NSStackView = {
        let s = NSStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .vertical
        s.spacing = 1
        s.alignment = .leading
        return s
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(artistLabel)
        addSubview(artworkView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            artworkView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            artworkView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkView.widthAnchor.constraint(equalToConstant: 32),
            artworkView.heightAnchor.constraint(equalToConstant: 32),

            stack.leadingAnchor.constraint(equalTo: artworkView.trailingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with track: TrackMetadata) {
        titleLabel.stringValue = track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title
        artistLabel.stringValue = track.artist.isEmpty ? "Unknown Artist" : track.artist

        // Artwork: cached base64 — scrolling 483 rows decodes once, then O(1)
        if let dataURL = track.coverDataURL, let image = CoverImageCache.image(fromDataURL: dataURL) {
            artworkView.image = image
            artworkView.contentTintColor = nil
        } else {
            artworkView.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            artworkView.contentTintColor = .secondaryLabelColor
        }
        toolTip = "\(track.title) — \(track.artist) • \(track.album)"
    }

    private static func image(fromDataURL url: String) -> NSImage? {
        CoverImageCache.image(fromDataURL: url)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            // Adapt text colors for selection
            if backgroundStyle == .emphasized {
                titleLabel.textColor = .alternateSelectedControlTextColor
                artistLabel.textColor = .alternateSelectedControlTextColor
            } else {
                titleLabel.textColor = .labelColor
                artistLabel.textColor = .secondaryLabelColor
            }
        }
    }
}
