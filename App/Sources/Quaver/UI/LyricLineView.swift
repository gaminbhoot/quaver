import AppKit

// MARK: - LyricLineView
// Monochrome editorial line: huge 34–52pt base → 30pt active on macOS,
// tight tracking -0.04em, warm off-white #F6F4EF active, 0.08 inactive.
// Pure AppKit, no glass, no pill highlight — just typography like
// fullscreen-lyrics-content am-lyrics (--lyplus-*). Word progress 0..1
// from LyricSynchronizer maps to karaoke blend dim→active.

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
        s.spacing = 6
        s.alignment = .centerY
        return s
    }()

    private var wordLabels: [NSTextField] = []
    private var wordStrings: [String] = []
    private var isActiveLine = false
    private var isPastLine = false

    private var words: [String] { wordStrings }

    init(line: LyricLine, index: Int) {
        self.lyricLine = line
        self.lineIndex = index
        super.init(frame: .zero)
        // Perf: no layer/cornerRadius — line is just typography on solid #0a0a0a,
        // no background fill ever (layer?.backgroundColor always clear). Removing
        // the extra CALayer per line saves compositing for 200+ lines while scrolling.
        buildWords()
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        let click = NSClickGestureRecognizer(target: self, action: #selector(lineClicked))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func buildWords() {
        let rawWords = lyricLine.text.split { $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
        wordStrings = rawWords
        // Perf: rely on NSStackView spacing (8) for gaps — no extra spacer NSViews per gap.
        // Each spacer was an extra view+constraint pair per word, doubling layout work for 200 lines.
        container.spacing = 8
        for (wi, w) in rawWords.enumerated() {
            let label = NSTextField(labelWithString: w)
            label.font = .systemFont(ofSize: 24, weight: .medium)
            label.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.42)
            label.isSelectable = false
            label.isEditable = false
            label.isBezeled = false
            label.drawsBackground = false
            label.tag = wi
            label.isEnabled = true
            let gr = NSClickGestureRecognizer(target: self, action: #selector(wordClicked(_:)))
            label.addGestureRecognizer(gr)
            wordLabels.append(label)
            container.addArrangedSubview(label)
        }
        if rawWords.isEmpty {
            let label = NSTextField(labelWithString: lyricLine.text)
            label.font = .systemFont(ofSize: 24, weight: .medium)
            label.textColor = .secondaryLabelColor
            wordLabels = [label]
            container.addArrangedSubview(label)
        }
    }

    // MARK: Style — monochrome editorial (no pill, pure typography)

    func setState(active: Bool, past: Bool, upcoming: Bool, nearby: Bool) {
        isActiveLine = active
        isPastLine = past
        // CSS: .synced-line 0.5 blur1.5 scale0.95 → .active 1 blur0 scale1 → .upcoming 0.7/0.98 → .past 0.3/0.93
        let baseSize: CGFloat
        let weight: NSFont.Weight
        let alpha: CGFloat
        let baseColor: NSColor
        if active {
            baseSize = 30
            weight = .semibold
            alpha = 1.0
            baseColor = NSColor(hex: 0xF6F4EF) ?? .labelColor
        } else if past {
            baseSize = nearby ? 23 : 20
            weight = .regular
            alpha = nearby ? 0.44 : 0.30
            baseColor = NSColor(hex: 0xF6F4EF) ?? .secondaryLabelColor
        } else if upcoming {
            baseSize = nearby ? 26 : 22
            weight = nearby ? .medium : .regular
            alpha = nearby ? 0.72 : 0.56
            baseColor = NSColor(hex: 0xF6F4EF) ?? .secondaryLabelColor
        } else {
            baseSize = 22
            weight = .regular
            alpha = 0.50
            baseColor = NSColor(hex: 0xF6F4EF) ?? .secondaryLabelColor
        }
        for label in wordLabels {
            let kern: CGFloat = active ? -0.6 : -0.2
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: baseSize, weight: weight),
                .foregroundColor: baseColor.withAlphaComponent(alpha),
                .kern: kern,
            ]
            label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: attrs)
            label.alphaValue = 1
        }
        // No layer backgroundColor churn — view is already solid behind overlay.
    }

    func updateWordProgresses(_ progresses: [Double]) {
        if progresses.isEmpty { return }
        let highlight = NSColor(hex: 0xF6F4EF) ?? .labelColor
        // Perf: karaoke blends only color/alpha — keeping font size/weight constant
        // avoids NSStackView relayout on every 0.1s tick. Previous code toggled
        // 30↔29 and medium↔semibold per word per tick which invalidated layout for
        // the active line and forced the whole lyrics documentView to reflow.
        let fixedSize: CGFloat = isActiveLine ? 30 : 24
        let fixedWeight: NSFont.Weight = isActiveLine ? .semibold : .medium
        let fixedFont = NSFont.systemFont(ofSize: fixedSize, weight: fixedWeight)
        for (idx, prog) in progresses.enumerated() where wordLabels.indices.contains(idx) {
            let label = wordLabels[idx]
            let p = max(0, min(1, prog))
            let baseAlpha: CGFloat = isPastLine ? 0.32 : 0.42
            let blended = highlight.withAlphaComponent(baseAlpha + (1.0 - baseAlpha) * p)
            // Reuse font — no layout churn
            label.attributedStringValue = NSAttributedString(string: label.stringValue, attributes: [
                .font: fixedFont,
                .foregroundColor: blended,
                .kern: -0.5,
            ])
        }
    }

    @objc private func lineClicked() { onLineClick?(lineIndex) }
    @objc private func wordClicked(_ gr: NSClickGestureRecognizer) {
        guard let v = gr.view as? NSTextField else { return }
        onWordClick?(lineIndex, v.tag)
    }

    var wordCount: Int { wordStrings.count }
    var currentFontSize: CGFloat { wordLabels.first?.font?.pointSize ?? 0 }
    var isHighlighted: Bool { false }
}

private extension NSColor {
    convenience init?(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
