import AppKit
import Combine

// MARK: - LibraryViewController
// Native library content area: NSTableView + header + empty states.
// No HTML. Uses LibraryStore as single source for playlists/liked/recent + sort/filter.

@MainActor
protocol LibraryViewControllerDelegate: AnyObject {
    func libraryDidSelectPlay(trackAt index: Int, inVisibleTracks: [TrackMetadata])
    func libraryDidRequestAddFolder()
}

@MainActor
final class LibraryViewController: NSViewController {

    weak var delegate: LibraryViewControllerDelegate?

    // MARK: - UI

    private let headerView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let eyebrowLabel: NSTextField = {
        let l = NSTextField(labelWithString: "Library")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }()

    private let titleLabel: NSTextField = {
        let l = NSTextField(labelWithString: "All Songs")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 24, weight: .bold)
        return l
    }()

    private let filterPopup: NSPopUpButton = {
        let b = NSPopUpButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addItems(withTitles: ["All", "FLAC", "Lossless"])
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12)
        return b
    }()

    private let sortPopup: NSPopUpButton = {
        let b = NSPopUpButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addItems(withTitles: ["Title", "Artist", "Album", "Recently Added"])
        b.controlSize = .small
        b.font = .systemFont(ofSize: 12)
        return b
    }()

    private let tableView: NSTableView = {
        let tv = NSTableView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.allowsMultipleSelection = false
        tv.headerView = NSTableHeaderView()
        tv.rowHeight = 44
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.usesAlternatingRowBackgroundColors = false
        tv.gridStyleMask = []
        return tv
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.borderType = .noBorder
        sv.drawsBackground = false
        return sv
    }()

    private let emptyView: NSView = {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    private let emptyIcon: NSTextField = {
        let l = NSTextField(labelWithString: "📁")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 40)
        l.alignment = .center
        return l
    }()

    private let emptyTitle: NSTextField = {
        let l = NSTextField(labelWithString: "No music loaded yet")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 16, weight: .semibold)
        l.alignment = .center
        return l
    }()

    private let emptySubtitle: NSTextField = {
        let l = NSTextField(labelWithString: "Select your FLAC/ALAC library folder from your local disk or external hard drive.")
        l.translatesAutoresizingMaskIntoConstraints = false
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        l.alignment = .center
        return l
    }()

    private let emptyButton: NSButton = {
        let b = NSButton(title: "Select Music Folder", target: nil, action: nil)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        return b
    }()

    private let loadingIndicator: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.translatesAutoresizingMaskIntoConstraints = false
        p.style = .spinning
        p.controlSize = .small
        p.isDisplayedWhenStopped = false
        return p
    }()

    private let separator: NSBox = {
        let b = NSBox()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.boxType = .separator
        return b
    }()

    // MARK: - Data

    private var store: LibraryStore?
    private var library: [TrackMetadata] = []
    private var visibleTracks: [TrackMetadata] = []
    private var currentView: LibraryView = .all
    private var searchQuery: String = ""
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    override func loadView() {
        self.view = NSView()
        view.wantsLayer = true
        // System window background — adapts to Light/Dark and lets the
        // header glass (withinWindow) show scroll content blur with depth
        // instead of a flat opaque slab. Previous hardcoded 0.11 was too
        // dark and defeated vibrancy, contributing to the flat disconnect
        // between glass sidebar and library.
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHeader()
        installHeaderGlass()
        setupTable()
        setupEmpty()
    }

    private func installHeaderGlass() {
        // Header should float over the scroll content with native material
        // (withinWindow) so artwork/list behind shows through with blur.
        // Without this the header was a flat opaque rectangle disconnected
        // from the Liquid Glass surfaces.
        let glass = QuaverGlass.backgroundView(for: .header)
        glass.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(glass, positioned: .below, relativeTo: nil)
        headerView.wantsLayer = true
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: headerView.topAnchor),
            glass.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: headerView.bottomAnchor),
        ])
        if glass is NSVisualEffectView || ({
            if #available(macOS 26.0, *) { return glass is NSGlassEffectView }
            return false
        }()) {
            headerView.layer?.backgroundColor = NSColor.clear.cgColor
            // Soften the hard separator when glass is active — the glass's own
            // edge highlight is the visual boundary, not an opaque 1px rectangle.
            separator.alphaValue = 0.5
        }
    }

    private func setupHeader() {
        view.addSubview(headerView)
        headerView.addSubview(eyebrowLabel)
        headerView.addSubview(titleLabel)
        headerView.addSubview(filterPopup)
        headerView.addSubview(sortPopup)

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            headerView.heightAnchor.constraint(equalToConstant: 56),

            eyebrowLabel.topAnchor.constraint(equalTo: headerView.topAnchor),
            eyebrowLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),

            titleLabel.topAnchor.constraint(equalTo: eyebrowLabel.bottomAnchor, constant: 2),
            titleLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: headerView.bottomAnchor),

            sortPopup.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            sortPopup.trailingAnchor.constraint(equalTo: headerView.trailingAnchor),
            sortPopup.widthAnchor.constraint(equalToConstant: 130),

            filterPopup.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            filterPopup.trailingAnchor.constraint(equalTo: sortPopup.leadingAnchor, constant: -8),
            filterPopup.widthAnchor.constraint(equalToConstant: 100),
        ])

        filterPopup.target = self
        filterPopup.action = #selector(filterChanged)
        sortPopup.target = self
        sortPopup.action = #selector(sortChanged)

        view.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func setupTable() {
        let titleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleCol.title = "Title"
        titleCol.width = 380
        titleCol.minWidth = 180
        titleCol.resizingMask = .autoresizingMask

        let albumCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("album"))
        albumCol.title = "Album"
        albumCol.width = 220
        albumCol.minWidth = 120

        let formatCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("format"))
        formatCol.title = "Format"
        formatCol.width = 80
        formatCol.minWidth = 60
        formatCol.maxWidth = 90

        let durationCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("duration"))
        durationCol.title = "Duration"
        durationCol.width = 80
        durationCol.minWidth = 60
        durationCol.maxWidth = 90

        for col in [titleCol, albumCol, formatCol, durationCol] {
            tableView.addTableColumn(col)
        }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        scrollView.documentView = tableView

        view.addSubview(scrollView)
        view.addSubview(loadingIndicator)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    private func setupEmpty() {
        view.addSubview(emptyView)
        let stack = NSStackView(views: [emptyIcon, emptyTitle, emptySubtitle, emptyButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        emptyView.addSubview(stack)
        emptySubtitle.maximumNumberOfLines = 0
        emptySubtitle.preferredMaxLayoutWidth = 360

        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            emptyView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),

            stack.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: emptyView.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: emptyView.trailingAnchor),
        ])

        emptyButton.target = self
        emptyButton.action = #selector(emptyAddFolderTapped)
    }

    // MARK: - Binding — use LibraryStore.didChangePublisher which fires AFTER didSet (synchronous, no lag)

    func bind(store: LibraryStore) {
        self.store = store
        cancellables.removeAll()
        store.didChangePublisher.sink { [weak self] _ in self?.reloadFromStore() }.store(in: &cancellables)
        syncPopupsFromStore()
        reloadFromStore()
    }

    func setLibrary(_ tracks: [TrackMetadata]) {
        self.library = tracks
        reloadVisible()
    }

    func setView(_ view: LibraryView, searchQuery: String? = nil) {
        self.currentView = view
        if let q = searchQuery { self.searchQuery = q }
        updateHeaderTitle()
        reloadVisible()
    }

    func setSearchQuery(_ query: String) {
        self.searchQuery = query
        reloadVisible()
    }

    func setLoading(_ loading: Bool) {
        if loading {
            loadingIndicator.startAnimation(nil)
            loadingIndicator.isHidden = false
        } else {
            loadingIndicator.stopAnimation(nil)
            loadingIndicator.isHidden = true
        }
    }

    private func syncPopupsFromStore() {
        guard let store = store else { return }
        switch store.libraryFilter {
        case .all: filterPopup.selectItem(at: 0)
        case .flac: filterPopup.selectItem(at: 1)
        case .lossless: filterPopup.selectItem(at: 2)
        }
        switch store.librarySort {
        case .title: sortPopup.selectItem(at: 0)
        case .artist: sortPopup.selectItem(at: 1)
        case .album: sortPopup.selectItem(at: 2)
        case .recent: sortPopup.selectItem(at: 3)
        }
    }

    private func reloadFromStore() {
        syncPopupsFromStore()
        reloadVisible()
    }

    private func reloadVisible() {
        guard let store = store else { return }
        let newVisible = LibraryQueries.visibleTracks(
            in: library,
            view: currentView,
            filter: store.libraryFilter,
            sort: store.librarySort,
            searchQuery: searchQuery,
            store: store
        )
        visibleTracks = newVisible
        updateHeaderTitle()
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateHeaderTitle() {
        switch currentView {
        case .all: titleLabel.stringValue = "All Songs"; eyebrowLabel.stringValue = "Library"
        case .liked: titleLabel.stringValue = "Liked Songs"; eyebrowLabel.stringValue = "Library"
        case .recent: titleLabel.stringValue = "Recently Played"; eyebrowLabel.stringValue = "Library"
        case .artists: titleLabel.stringValue = "Artists"; eyebrowLabel.stringValue = "Browse"
        case .albums: titleLabel.stringValue = "Albums"; eyebrowLabel.stringValue = "Browse"
        case .artist(let name): titleLabel.stringValue = name; eyebrowLabel.stringValue = "Artist"
        case .album(let name): titleLabel.stringValue = name; eyebrowLabel.stringValue = "Album"
        case .playlist(let id):
            let name = store?.playlists.first(where: { $0.id == id })?.name ?? "Playlist"
            titleLabel.stringValue = name; eyebrowLabel.stringValue = "Playlist"
        case .nowPlaying: titleLabel.stringValue = "Now Playing"; eyebrowLabel.stringValue = "Playback"
        }
        if !visibleTracks.isEmpty {
            eyebrowLabel.stringValue += " • \(visibleTracks.count) songs"
        }
    }

    private func updateEmptyState() {
        let isEmptyLibrary = library.isEmpty
        let isEmptyVisible = visibleTracks.isEmpty

        if isEmptyLibrary {
            emptyView.isHidden = false
            emptyTitle.stringValue = "No music loaded yet"
            emptySubtitle.stringValue = "Select your FLAC/ALAC library folder from your local disk or external hard drive."
            emptyButton.isHidden = false
            emptyIcon.stringValue = "📁"
            scrollView.isHidden = true
        } else if isEmptyVisible {
            emptyView.isHidden = false
            emptyTitle.stringValue = "No matches"
            switch currentView {
            case .liked: emptySubtitle.stringValue = "You haven't liked any songs yet. Click the heart on a track to add it."
            case .recent: emptySubtitle.stringValue = "No recently played tracks. Play a song to see it here."
            case .playlist: emptySubtitle.stringValue = "This playlist is empty. Add songs from All Songs."
            default:
                if !searchQuery.isEmpty {
                    emptySubtitle.stringValue = "No results for “\(searchQuery)”."
                } else {
                    emptySubtitle.stringValue = "No songs match the current filter."
                }
            }
            emptyButton.isHidden = true
            emptyIcon.stringValue = "🔍"
            scrollView.isHidden = true
        } else {
            emptyView.isHidden = true
            scrollView.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        guard let store = store else { return }
        switch filterPopup.indexOfSelectedItem {
        case 1: store.libraryFilter = .flac
        case 2: store.libraryFilter = .lossless
        default: store.libraryFilter = .all
        }
    }

    @objc private func sortChanged() {
        guard let store = store else { return }
        switch sortPopup.indexOfSelectedItem {
        case 1: store.librarySort = .artist
        case 2: store.librarySort = .album
        case 3: store.librarySort = .recent
        default: store.librarySort = .title
        }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, visibleTracks.indices.contains(row) else { return }
        delegate?.libraryDidSelectPlay(trackAt: row, inVisibleTracks: visibleTracks)
    }

    @objc private func emptyAddFolderTapped() {
        delegate?.libraryDidRequestAddFolder()
    }

    // MARK: - Helpers for tests

    var currentVisibleTracks: [TrackMetadata] { visibleTracks }
    var currentViewForTest: LibraryView { currentView }
    var currentSearchForTest: String { searchQuery }
    var isEmptyViewVisible: Bool { !emptyView.isHidden }
    var isScrollViewVisible: Bool { !scrollView.isHidden }
}

// MARK: - NSTableViewDataSource / Delegate

extension LibraryViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { visibleTracks.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleTracks.indices.contains(row) else { return nil }
        let track = visibleTracks[row]
        guard let id = tableColumn?.identifier.rawValue else { return nil }

        switch id {
        case "title":
            let view = tableView.makeView(withIdentifier: LibraryTableCellView.reuseIdentifier, owner: nil) as? LibraryTableCellView
                ?? LibraryTableCellView()
            view.identifier = LibraryTableCellView.reuseIdentifier
            view.configure(with: track)
            return view
        case "album":
            let cell = makeSimpleCell(tableView, identifier: "albumCell", text: track.album.isEmpty ? "—" : track.album)
            return cell
        case "format":
            let cell = makeSimpleCell(tableView, identifier: "formatCell", text: track.format.uppercased())
            cell?.textField?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            return cell
        case "duration":
            let cell = makeSimpleCell(tableView, identifier: "durationCell", text: formatDuration(track.duration))
            cell?.textField?.alignment = .right
            return cell
        default:
            return nil
        }
    }

    private func makeSimpleCell(_ tv: NSTableView, identifier: String, text: String) -> NSTableCellView? {
        let id = NSUserInterfaceItemIdentifier(identifier)
        var cell = tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
        if cell == nil {
            cell = NSTableCellView()
            cell?.identifier = id
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            cell?.addSubview(tf)
            cell?.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 8),
                tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
            ])
        }
        cell?.textField?.stringValue = text
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }

    private func formatDuration(_ secs: Double) -> String {
        guard secs.isFinite, secs > 0 else { return "—" }
        let m = Int(secs) / 60
        let s = Int(secs) % 60
        return String(format: "%d:%02d", m, s)
    }
}
