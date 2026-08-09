import AppKit

// MARK: - SidebarViewController
// Native source-list sidebar. No HTML. Real traffic lights are in QuaverWindow's titlebar.

@MainActor
protocol SidebarViewControllerDelegate: AnyObject {
    func sidebarDidSelectView(_ view: LibraryView)
    func sidebarDidRequestAddFolder()
    func sidebarDidRequestCreatePlaylist()
    func sidebarDidSelectPlaylist(id: String)
    func sidebarSearchChanged(_ query: String)
}

@MainActor
final class SidebarViewController: NSViewController {

    weak var delegate: SidebarViewControllerDelegate?

    // MARK: - UI

    private let searchField: NSSearchField = {
        let f = NSSearchField()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.placeholderString = "Search (⌘K)"
        f.sendsSearchStringImmediately = true
        f.sendsWholeSearchString = true
        return f
    }()

    private let tableView: NSTableView = {
        let tv = NSTableView()
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.headerView = nil
        tv.allowsMultipleSelection = false
        tv.backgroundColor = .clear
        tv.rowSizeStyle = .medium
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        if #available(macOS 11.0, *) { tv.style = .sourceList } else { tv.selectionHighlightStyle = .sourceList }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebarColumn"))
        col.isEditable = false
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

    private let addFolderButton: NSButton = {
        let b = NSButton(title: "Add Folder", target: nil, action: nil)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.bezelStyle = .rounded
        b.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.font = .systemFont(ofSize: 13, weight: .medium)
        b.controlSize = .regular
        return b
    }()

    // MARK: - Data

    struct Row {
        let id: String
        let title: String
        let icon: String
        let isHeader: Bool
        let view: LibraryView?
        let playlistID: String?
    }

    private var rows: [Row] = []
    private var selectedRowID: String = "all"

    private var playlistRows: [Row] = []

    // MARK: - Lifecycle

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installGlassBackground()
        setupLayout()
        setupTable()
        rebuildRows()
        selectInitial()
    }

    private func installGlassBackground() {
        let glass = QuaverGlass.backgroundView(for: .sidebar)
        glass.translatesAutoresizingMaskIntoConstraints = false
        // Insert at back so controls remain interactive (glass must not intercept clicks)
        view.addSubview(glass, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: view.topAnchor),
            glass.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // When genuine glass/material is active, make the hosting view transparent
        // so the material shows through without a hard opaque boundary.
        // Solid fallback (reduced transparency) keeps the opaque background.
        if glass is NSVisualEffectView {
            view.layer?.backgroundColor = NSColor.clear.cgColor
        } else if #available(macOS 26.0, *) {
            if glass is NSGlassEffectView {
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    private func setupLayout() {
        scrollView.documentView = tableView

        let bottomBar = NSView()
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(addFolderButton)
        addFolderButton.target = self
        addFolderButton.action = #selector(addFolderTapped)

        view.addSubview(searchField)
        view.addSubview(scrollView)
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: view.topAnchor, constant: 32),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),

            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            bottomBar.heightAnchor.constraint(equalToConstant: 32),

            addFolderButton.centerXAnchor.constraint(equalTo: bottomBar.centerXAnchor),
            addFolderButton.centerYAnchor.constraint(equalTo: bottomBar.centerYAnchor),
            addFolderButton.leadingAnchor.constraint(greaterThanOrEqualTo: bottomBar.leadingAnchor, constant: 8),
            addFolderButton.trailingAnchor.constraint(lessThanOrEqualTo: bottomBar.trailingAnchor, constant: -8),
        ])

        searchField.delegate = self
    }

    private func setupTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
    }

    private func rebuildRows() {
        var newRows: [Row] = []
        newRows.append(Row(id: "hdr-library", title: "Library", icon: "", isHeader: true, view: nil, playlistID: nil))
        newRows.append(Row(id: "all", title: "All Songs", icon: "music.note.list", isHeader: false, view: .all, playlistID: nil))
        newRows.append(Row(id: "liked", title: "Liked", icon: "heart", isHeader: false, view: .liked, playlistID: nil))
        newRows.append(Row(id: "recent", title: "Recently Played", icon: "clock", isHeader: false, view: .recent, playlistID: nil))
        newRows.append(Row(id: "hdr-browse", title: "Browse", icon: "", isHeader: true, view: nil, playlistID: nil))
        newRows.append(Row(id: "artists", title: "Artists", icon: "music.mic", isHeader: false, view: .artists, playlistID: nil))
        newRows.append(Row(id: "albums", title: "Albums", icon: "square.stack", isHeader: false, view: .albums, playlistID: nil))
        newRows.append(Row(id: "hdr-playlists", title: "Playlists", icon: "", isHeader: true, view: nil, playlistID: nil))
        newRows.append(contentsOf: playlistRows)
        if playlistRows.isEmpty {
            newRows.append(Row(id: "no-playlists", title: "No playlists yet", icon: "", isHeader: true, view: nil, playlistID: nil))
        }
        rows = newRows
        tableView.reloadData()
        if let idx = rows.firstIndex(where: { $0.id == selectedRowID }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
    }

    func updatePlaylists(_ playlists: [QuaverPlaylist]) {
        playlistRows = playlists.map { pl in
            Row(id: "pl:\(pl.id)", title: pl.name, icon: "music.note.list", isHeader: false, view: .playlist(id: pl.id), playlistID: pl.id)
        }
        rebuildRows()
    }

    private func selectInitial() {
        if let idx = rows.firstIndex(where: { $0.id == "all" }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            selectedRowID = "all"
        }
    }

    func selectView(_ view: LibraryView) {
        let targetID: String
        switch view {
        case .all: targetID = "all"
        case .liked: targetID = "liked"
        case .recent: targetID = "recent"
        case .artists, .artist: targetID = "artists"
        case .albums, .album: targetID = "albums"
        case .playlist(let id): targetID = "pl:\(id)"
        case .nowPlaying: targetID = "all"
        }
        if let idx = rows.firstIndex(where: { $0.id == targetID }) {
            selectedRowID = targetID
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
    }

    // MARK: - Actions

    @objc private func addFolderTapped() {
        delegate?.sidebarDidRequestAddFolder()
    }

    @objc private func createPlaylistTapped() {
        delegate?.sidebarDidRequestCreatePlaylist()
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, rows.indices.contains(row) else { return }
        let item = rows[row]
        if item.isHeader { return }
        handleSelection(row: row)
    }

    private func handleSelection(row: Int) {
        guard rows.indices.contains(row) else { return }
        let item = rows[row]
        if item.isHeader { return }
        selectedRowID = item.id
        if let playlistID = item.playlistID {
            delegate?.sidebarDidSelectPlaylist(id: playlistID)
        } else if let view = item.view {
            delegate?.sidebarDidSelectView(view)
        } else if item.id == "addFolder" {
            delegate?.sidebarDidRequestAddFolder()
        }
    }

    func setSearchQuery(_ query: String) {
        searchField.stringValue = query
    }

    var currentSearchQuery: String { searchField.stringValue }
}

// MARK: - NSTableViewDataSource / Delegate

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row].isHeader ? 22 : 28
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !rows[row].isHeader
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        if item.isHeader {
            let cell = NSTextField(labelWithString: item.title)
            cell.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textColor = .secondaryLabelColor
            let view = NSView()
            view.addSubview(cell)
            cell.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
                cell.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        } else {
            let cellID = NSUserInterfaceItemIdentifier("SidebarCell")
            var cell = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView
            if cell == nil {
                cell = NSTableCellView()
                cell?.identifier = cellID
                let iv = NSImageView()
                iv.translatesAutoresizingMaskIntoConstraints = false
                iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
                iv.contentTintColor = .secondaryLabelColor
                cell?.addSubview(iv)
                iv.tag = 100
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.font = .systemFont(ofSize: 13, weight: .regular)
                tf.lineBreakMode = .byTruncatingTail
                cell?.addSubview(tf)
                tf.tag = 101
                cell?.textField = tf
                cell?.imageView = iv
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: cell!.leadingAnchor, constant: 12),
                    iv.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8),
                    tf.trailingAnchor.constraint(equalTo: cell!.trailingAnchor, constant: -8),
                    tf.centerYAnchor.constraint(equalTo: cell!.centerYAnchor),
                ])
            }
            cell?.textField?.stringValue = item.title
            if !item.icon.isEmpty {
                cell?.imageView?.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)
                cell?.imageView?.isHidden = false
            } else {
                cell?.imageView?.isHidden = true
            }
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, rows.indices.contains(row) else { return }
        handleSelection(row: row)
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField, field == searchField {
            delegate?.sidebarSearchChanged(field.stringValue)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSSearchField, field == searchField {
            delegate?.sidebarSearchChanged(field.stringValue)
        }
    }
}
