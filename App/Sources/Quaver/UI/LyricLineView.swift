import AppKit

// MARK: - LyricLineView
// Single lyric line with per-word karaoke highlighting. Pure AppKit.
// No HTML/CSS, no WebView. Word progress 0..1 driven from LyricSynchronizer.

@MainActor
final class LyricLineView: NSView {

    let lineIndex: Int
    let lyricLine: LyricLine
    var onLineClick: ((Int) -> Void)?
    var onWordClick: ((Int, Int) -> Void)?

    private let container: NSStackView = {
        let s = NSStackView()
        s.translatesAutoresizingMaskIntoConstraints = false
        s.orientation = .horizontal
        s.spacing = 4
        s.alignment = .centerY
        return s
    }()

    private var wordLabels: [NSTextField] = []
    private var wordStrings: [String] = []
    private var isActiveLine = false
    private var isPastLine = false

    // Keep raw text splits for progress mapping. Mirrors JS: split(\s+) filtered.
    private var words: [String] { wordStrings }

    init(line: LyricLine, index: Int) {
        self.lyricLine = line
        self.lineIndex = index
        super.init(frame: .zero)
        wantsLayer = true
        buildWords()
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        // Click gesture for line (fallback when not hitting a word)
        let click = NSClickGestureRecognizer(target: self, action: #selector(lineClicked))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildWords() {
        let rawWords = lyricLine.text.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
        wordStrings = rawWords
        for (wi, w) in rawWords.enumerated() {
            let label = NSTextField(labelWithString: w)
            label.font = .systemFont(ofSize: 22, weight: .regular)
            label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.65)
            label.isSelectable = false
            label.isEditable = false
            label.isBezeled = false
            label.drawsBackground = false
            label.tag = wi
            // Per-word click
            label.isEnabled = true
            let gr = NSClickGestureRecognizer(target: self, action: #selector(wordClicked(_:)))
            label.addGestureRecognizer(gr)
            wordLabels.append(label)
            container.addArrangedSubview(label)
            // Add inter-word space as fixed spacer view (except after last)
            if wi < rawWords.count - 1 {
                let sp = NSView()
                sp.translatesAutoresizingMaskIntoConstraints = false
                sp.widthAnchor.constraint(equalToConstant: 6).isActive = true
                sp.heightAnchor.constraint(equalToConstant: 1).isActive = true
                container.addArrangedSubview(sp)
            }
        }
        if rawWords.isEmpty {
            // Empty lyric fallback — shouldn't happen (parse filters) but keep.
            let label = NSTextField(labelWithString: lyricLine.text)
            label.font = .systemFont(ofSize: 22, weight: .regular)
            label.textColor = .secondaryLabelColor
            wordLabels = [label]
            container.addArrangedSubview(label)
        }
    }

    // MARK: Style update from LyricsViewController

    func setState(active: Bool, past: Bool, upcoming: Bool, nearby: Bool) {
        isActiveLine = active
        isPastLine = past
        // Typography mirrors spec: active is prominent, past dimmed, upcoming dimmed but less, nearby intermediate.
        let baseSize: CGFloat = active ? 26 : (nearby ? 22 : 20)
        let weight: NSFont.Weight = active ? .semibold : (past ? .regular : .medium)
        let alpha: CGFloat = active ? 1.0 : (past ? 0.42 : (nearby ? 0.78 : 0.55))
        let color: NSColor = active ? .labelColor : .secondaryLabelColor
        for label in wordLabels {
            label.font = .systemFont(ofSize: baseSize, weight: weight)
            // Keep wordProgress tint if active, otherwise base color
            if !active {
                label.textColor = color.withAlphaComponent(alpha)
            }
            // Scale active line slightly
            label.alphaValue = alpha
        }
        // Background highlight for active
        layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
        layer?.cornerRadius = 8
    }

    func updateWordProgresses(_ progresses: [Double]) {
        // Only active line gets karaoke highlighting; others cleared by caller with [].
        if progresses.isEmpty {
            // Reset to base state — keep alpha but remove word tint
            for label in wordLabels {
                // leave setState to control alpha; just ensure no progress highlight
                label.textColor = isActiveLine ? NSColor.labelColor.withAlphaComponent(0.55) : label.textColor
            }
            return
        }
        for (idx, prog) in progresses.enumerated() where wordLabels.indices.contains(idx) {
            let label = wordLabels[idx]
            // Karaoke: 0 = dim, 1 = fully highlighted white. Interpolate.
            // Use textColor blend and subtle scale.
            let p = max(0, min(1, prog))
            if p >= 1 {
                label.textColor = .labelColor
                label.alphaValue = 1.0
            } else if p > 0 {
                // Partially filled word — use accent tint interpolation
                // Blend secondary -> labelColor by p
                label.textColor = NSColor.labelColor.withAlphaComponent(0.45 + 0.55 * p)
                label.alphaValue = 0.6 + 0.4 * p
            } else {
                label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.55)
                label.alphaValue = isPastLine ? 0.5 : 0.65
            }
        }
    }

    // MARK: Interactions

    @objc private func lineClicked() {
        onLineClick?(lineIndex)
    }

    @objc private func wordClicked(_ gr: NSClickGestureRecognizer) {
        guard let v = gr.view as? NSTextField else { return }
        onWordClick?(lineIndex, v.tag)
    }

    // MARK: Test hooks

    var wordCount: Int { wordStrings.count }
    var currentFontSize: CGFloat { wordLabels.first?.font?.pointSize ?? 0 }
    var isHighlighted: Bool { layer?.backgroundColor != NSColor.clear.cgColor }
}
