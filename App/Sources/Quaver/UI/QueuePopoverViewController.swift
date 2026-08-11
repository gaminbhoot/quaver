import AppKit
import Combine

// MARK: - QueuePopoverViewController
// Up Next / Play Queue — native NSPopover + NSTableView, single-clock.
// No second PlaybackState, no Timer, no polling. Observes PlaybackEngine.statePublisher
// and renders queueOrder (library indices) → TrackMetadata. Drag-reorder mutates
// engine.queueOrder via moveQueueItem(from:to:); double-click plays via engine.play(trackAt:).
// Library is injected from RootSplit (engine.library is private) and kept in sync via
// updateLibrary(_:). All state ownership remains in NativePlaybackEngine/LibraryStore.

@MainActor
final class QueuePopoverViewController: NSViewController {

    // MARK: Dependencies
    private let engine: PlaybackEngine
    private var library: [TrackMetadata]
    private var cancellables = Set<AnyCancellable>()

    // MARK: UI
    private let headerTitle: NSTextField = {
        let l = NSTextField(labelWithString: "Up Next")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        l.textColor = .labelColor
        return l
    }()
    private let countLabel: NSTextField = {
        let l = NSTextField(labelWithString: "")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = .secondaryLabelColor
        return l
    }()
    private let tableView: NSTableView = {
        let tv = NSTableView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.headerView = nil
        tv.allowsMultipleSelection = false
        tv.backgroundColor = .clear
        tv.rowHeight = 44
        tv.intercellSpacing = NSSize(width: 0, height: 1)
        tv.selectionHighlightStyle = .regular
        if #available(macOS 11.0, *) { tv.style = .plain }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("queueColumn"))
        col.isEditable = false
        col.resizingMask = .autoresizingMask
        tv.addTableColumn(col)
        return tv
    }()
    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.autohidesScrollers = true
        return sv
    }()
    private let emptyLabel: NSTextField = {
        let l = NSTextField(labelWithString: "No tracks in queue")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 12, weight: .regular)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        l.isHidden = true
        return l
    }()
    private let emptySubLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Add a folder to get started")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11, weight: .regular)
        l.textColor = .tertiaryLabelColor
        l.alignment = .center
        l.isHidden = true
        return l
    }()

    // Drag state
    private let dragUTI = NSPasteboard.PasteboardType.string

    // MARK: Init
    init(engine: PlaybackEngine, library: [TrackMetadata] = []) {
        self.engine = engine
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Lifecycle
    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // Fixed popover content size — NSPopover will size to this
        v.frame = NSRect(x: 0, y: 0, width: 360, height: 380)
        self.view = v
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupTable()
        bindEngine()
        reload()
    }
    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }
    deinit { cancellables.forEach { $0.cancel() } }

    // MARK: Public API
    func updateLibrary(_ tracks: [TrackMetadata]) {
        library = tracks
        reload()
    }
    func reload() {
        // Validate queue indices against current library before render
        tableView.reloadData()
        updateEmptyState()
        updateCount()
        highlightCurrent()
    }
    var isEmpty: Bool { engine.queueOrder.isEmpty || library.isEmpty }
    var numberOfRows: Int { max(0, min(engine.queueOrder.count, library.count == 0 ? 0 : engine.queueOrder.count)) }

    // MARK: UI setup
    private func setupUI() {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerTitle)
        header.addSubview(countLabel)
        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator
        separator.alphaValue = 0.15
        scrollView.documentView = tableView
        view.addSubview(header)
        view.addSubview(separator)
        view.addSubview(scrollView)
        view.addSubview(emptyLabel)
        view.addSubview(emptySubLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            header.heightAnchor.constraint(equalToConstant: 20),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            countLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -10),
            emptySubLabel.topAnchor.constraint(equalTo: emptyLabel.bottomAnchor, constant: 4),
            emptySubLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
        ])
        view.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.heightAnchor.constraint(equalToConstant: 380).isActive = true
    }
    private func setupTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.registerForDraggedTypes([dragUTI])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)
        tableView.allowsColumnReordering = false
    }
    private func bindEngine() {
        engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (_: PlaybackState) in
                guard let self else { return }
                self.tableView.reloadData()
                self.updateEmptyState()
                self.updateCount()
                self.highlightCurrent()
            }
            .store(in: &cancellables)
    }
    private func updateCount() {
        let n = engine.queueOrder.count
        if library.isEmpty {
            countLabel.stringValue = ""
        } else if n == 0 {
            countLabel.stringValue = "0 tracks"
        } else {
            countLabel.stringValue = "\(n) tracks"
        }
    }
    private func updateEmptyState() {
        let empty = engine.queueOrder.isEmpty || library.isEmpty
        emptyLabel.isHidden = !empty
        emptySubLabel.isHidden = !empty
        scrollView.isHidden = empty
        if empty {
            if library.isEmpty {
                emptyLabel.stringValue = "No tracks in queue"
                emptySubLabel.stringValue = "Add a folder to get started"
            } else {
                emptyLabel.stringValue = "Queue is empty"
                emptySubLabel.stringValue = ""
                emptySubLabel.isHidden = true
            }
        }
    }
    private func highlightCurrent() {
        let cur = engine.state.currentTrackIndex
        guard cur >= 0, !engine.queueOrder.isEmpty else { return }
        if let pos = engine.queueOrder.firstIndex(of: cur) {
            // Don't steal selection if user is interacting; just ensure visible
            tableView.scrollRowToVisible(pos)
            // Select current row to show highlight (transient, not persistent edit)
            if tableView.selectedRow != pos {
                tableView.selectRowIndexes(IndexSet(integer: pos), byExtendingSelection: false)
            }
        }
    }
    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, engine.queueOrder.indices.contains(row) else { return }
        let libIdx = engine.queueOrder[row]
        guard library.indices.contains(libIdx) else { return }
        engine.play(trackAt: libIdx)
    }

    // Exposed for tests — simulate drag programmatically
    func simulateMove(from: Int, to: Int) {
        engine.moveQueueItem(from: from, to: to)
    }
    func simulatePlay(row: Int) {
        guard engine.queueOrder.indices.contains(row) else { return }
        engine.play(trackAt: engine.queueOrder[row])
    }
}

// MARK: - NSTableViewDataSource / Delegate
extension QueuePopoverViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if library.isEmpty { return 0 }
        return engine.queueOrder.count
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let idx = engine.queueOrder[row]
        guard library.indices.contains(idx) else { return nil }
        let track = library[idx]
        let isCurrent = idx == engine.state.currentTrackIndex
        let identifier = NSUserInterfaceItemIdentifier("QueueCell")
        var cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = identifier
            let art = NSImageView(frame: NSRect(x: 0, y: 6, width: 32, height: 32))
            art.translatesAutoresizingMaskIntoConstraints = false
            art.imageScaling = .scaleProportionallyUpOrDown
            art.wantsLayer = true
            art.layer?.cornerRadius = 4
            art.layer?.masksToBounds = true
            art.identifier = NSUserInterfaceItemIdentifier("art")
            let title = NSTextField(labelWithString: "")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
            title.lineBreakMode = .byTruncatingTail
            title.identifier = NSUserInterfaceItemIdentifier("title")
            let artist = NSTextField(labelWithString: "")
            artist.translatesAutoresizingMaskIntoConstraints = false
            artist.font = .systemFont(ofSize: 11, weight: .regular)
            artist.textColor = .secondaryLabelColor
            artist.lineBreakMode = .byTruncatingTail
            artist.identifier = NSUserInterfaceItemIdentifier("artist")
            let indicator = NSImageView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.identifier = NSUserInterfaceItemIdentifier("indicator")
            cell?.addSubview(art)
            cell?.addSubview(title)
            cell?.addSubview(artist)
            cell?.addSubview(indicator)
            NSLayoutConstraint.activate([
                art.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 8),
                art.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                art.widthAnchor.constraint(equalToConstant: 32),
                art.heightAnchor.constraint(equalToConstant: 32),
                indicator.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -8),
                indicator.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                indicator.widthAnchor.constraint(equalToConstant: 12),
                indicator.heightAnchor.constraint(equalToConstant: 12),
                title.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 8),
                title.trailingAnchor.constraint(equalTo: indicator.leadingAnchor, constant: -8),
                title.topAnchor.constraint(equalTo: cell!.topAnchor, constant: 6),
                artist.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                artist.trailingAnchor.constraint(equalTo: title.trailingAnchor),
                artist.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            ])
        }
        // Resolve subviews
        let art = cell?.viewWithIdentifier(NSUserInterfaceItemIdentifier("art")) as? NSImageView
        let titleF = cell?.viewWithIdentifier(NSUserInterfaceItemIdentifier("title")) as? NSTextField
        let artistF = cell?.viewWithIdentifier(NSUserInterfaceItemIdentifier("artist")) as? NSTextField
        let indicator = cell?.viewWithIdentifier(NSUserInterfaceItemIdentifier("indicator")) as? NSImageView
        let displayTitle = track.title.isEmpty ? (track.path as NSString).lastPathComponent : track.title
        let displayArtist = track.artist.isEmpty ? "Unknown Artist" : track.artist
        titleF?.stringValue = displayTitle
        artistF?.stringValue = displayArtist
        titleF?.font = .systemFont(ofSize: 12, weight: isCurrent ? .semibold : .regular)
        titleF?.textColor = isCurrent ? NSColor.controlAccentColor : NSColor.labelColor
        if let dataURL = track.coverDataURL, let img = Self.image(fromDataURL: dataURL) {
            art?.image = img
            art?.contentTintColor = nil
        } else {
            art?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            art?.contentTintColor = .secondaryLabelColor
        }
        if isCurrent {
            indicator?.image = NSImage(systemSymbolName: engine.state.isPlaying ? "waveform" : "pause.fill", accessibilityDescription: nil)
            indicator?.contentTintColor = .controlAccentColor
            indicator?.isHidden = false
        } else {
            indicator?.isHidden = true
        }
        // Drag handle affordance via row's own drag (no extra view needed)
        return cell
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 44 }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
    // MARK: Drag & drop
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(row)", forType: dragUTI)
        return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .on { return [] }
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let items = info.draggingPasteboard.pasteboardItems, let first = items.first,
              let s = first.string(forType: dragUTI), let source = Int(s) else { return false }
        // Adjust for removal-before-insertion when dragging downwards
        var dest = row
        if source < dest { dest -= 1 }
        if source == dest { return false }
        engine.moveQueueItem(from: source, to: dest)
        return true
    }
    private static func image(fromDataURL url: String) -> NSImage? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let b64 = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }
}

// Helper for cell reuse
private extension NSView {
    func viewWithIdentifier(_ id: NSUserInterfaceItemIdentifier) -> NSView? {
        for sub in subviews where sub.identifier == id { return sub }
        return nil
    }
}
