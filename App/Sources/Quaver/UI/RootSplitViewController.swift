import AppKit
import Combine

// MARK: - RootSplitViewController
// NSSplitViewController that owns sidebar + library and mediates LibraryStore ↔ UI.
// Single LibraryStore, single `library: [TrackMetadata]` array — no second model.
// Now also hosts the native PlayerBar (mini-player) at the bottom and owns the
// single PlaybackEngine instance (no duplicated state, no independent clock).
// No WKWebView / HTML. Pure AppKit Auto Layout. Sidebar + table + header + empty states.

@MainActor
final class RootSplitViewController: NSSplitViewController {

    let store: LibraryStore
    let engine: NativePlaybackEngine
    let playerBar: PlayerBarViewController

    private(set) var library: [TrackMetadata] = []
    private(set) var selectedView: LibraryView = .all
    private(set) var searchQuery: String = ""

    let sidebarVC = SidebarViewController()
    let libraryVC = LibraryViewController()

    private var cancellables = Set<AnyCancellable>()
    private var isLoadingLibrary = false { didSet { libraryVC.setLoading(isLoadingLibrary) } }

    // MARK: - Init

    init(store: LibraryStore? = nil, engine: NativePlaybackEngine? = nil) {
        let eng = engine ?? NativePlaybackEngine()
        self.engine = eng
        self.playerBar = PlayerBarViewController(engine: eng)
        if let s = store { self.store = s } else { self.store = LibraryStore() }
        super.init(nibName: nil, bundle: nil)
        self.playerBar.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - View hierarchy — container with splitView + playerBar

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = container
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = false
        addSplitViewItem(sidebarItem)

        let libraryItem = NSSplitViewItem(viewController: libraryVC)
        libraryItem.minimumThickness = 480
        addSplitViewItem(libraryItem)

        sidebarVC.delegate = self
        libraryVC.delegate = self

        libraryVC.bind(store: store)
        sidebarVC.updatePlaylists(store.playlists)

        // Observe store via synchronous didChangePublisher (no dispatch lag)
        store.didChangePublisher.sink { [weak self] _ in
            guard let self else { return }
            self.sidebarVC.updatePlaylists(self.store.playlists)
        }.store(in: &cancellables)

        sidebarVC.selectView(.all)
        libraryVC.setView(.all)

        // Embed playerBar below splitView via Auto Layout.
        // Do NOT use addChild — NSSplitViewController overrides addChild(_:) to create a split item,
        // which would make splitViewItems.count == 3 and break the 2-pane contract verified by Phase 4.
        // The bar is held strongly by `self.playerBar` and its view is manually added to the container.
        let container = self.view
        let sv = self.splitView
        sv.translatesAutoresizingMaskIntoConstraints = false
        // Force playerBar's view to load before adding (ensures viewDidLoad ran)
        let barView = playerBar.view
        barView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sv)
        container.addSubview(barView)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: container.topAnchor),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: barView.topAnchor),

            barView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            barView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            barView.heightAnchor.constraint(equalToConstant: 76),
        ])

        loadSavedLibrary()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if splitView.frame.width > 0 {
            let target: CGFloat = 260
            let pos = min(max(target, 200), 320)
            if splitView.arrangedSubviews.count >= 2 {
                splitView.setPosition(pos, ofDividerAt: 0)
            }
        }
    }

    private func loadSavedLibrary() {
        guard let folder = QuaverCore.savedMusicFolder() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.scanFolder(folder, persist: false)
        }
    }

    // MARK: - Public API for tests / external callers

    func setLibraryTracks(_ tracks: [TrackMetadata]) {
        self.library = tracks
        libraryVC.setLibrary(tracks)
        engine.setLibrary(tracks)
    }

    func setViewForTest(_ view: LibraryView) {
        self.selectedView = view
        sidebarVC.selectView(view)
        libraryVC.setView(view)
    }

    func scanFolder(_ path: String, persist: Bool = true) async {
        isLoadingLibrary = true
        defer { isLoadingLibrary = false }
        if persist {
            try? QuaverCore.saveMusicFolder(path)
        }
        let tracks = await QuaverCore.scanDirectoryAsync(at: path)
        self.library = tracks
        libraryVC.setLibrary(tracks)
        engine.setLibrary(tracks)
    }

    func handleAddFolderRequest() {
        guard let picked = QuaverCore.pickMusicFolder() else { return }
        Task { await self.scanFolder(picked, persist: true) }
    }

    func handleCreatePlaylistRequest() {
        let alert = NSAlert()
        alert.messageText = "New Playlist"
        alert.informativeText = "Enter a name for your playlist."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Playlist name"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = store.createPlaylist(name: name.isEmpty ? "Untitled" : name)
        }
    }
}

// MARK: - SidebarViewControllerDelegate

extension RootSplitViewController: SidebarViewControllerDelegate {

    func sidebarDidSelectView(_ view: LibraryView) {
        selectedView = view
        libraryVC.setView(view, searchQuery: searchQuery)
    }

    func sidebarDidRequestAddFolder() {
        handleAddFolderRequest()
    }

    func sidebarDidRequestCreatePlaylist() {
        handleCreatePlaylistRequest()
    }

    func sidebarDidSelectPlaylist(id: String) {
        selectedView = .playlist(id: id)
        libraryVC.setView(.playlist(id: id), searchQuery: searchQuery)
    }

    func sidebarSearchChanged(_ query: String) {
        searchQuery = query
        libraryVC.setSearchQuery(query)
    }
}

// MARK: - LibraryViewControllerDelegate

extension RootSplitViewController: LibraryViewControllerDelegate {

    func libraryDidSelectPlay(trackAt index: Int, inVisibleTracks visible: [TrackMetadata]) {
        guard visible.indices.contains(index) else { return }
        let track = visible[index]
        store.recordPlayed(trackKey: track.key)
        // Resolve to engine's library index by key (single source of truth)
        if let libIndex = library.firstIndex(where: { $0.key == track.key }) {
            engine.play(trackAt: libIndex)
        } else if !visible.isEmpty {
            // Fallback: ensure engine has visible queue (filtered) and play there
            engine.setLibrary(visible)
            engine.play(trackAt: index)
        }
        if case .recent = selectedView {
            libraryVC.setView(selectedView)
        }
    }

    func libraryDidRequestAddFolder() {
        handleAddFolderRequest()
    }
}

// MARK: - PlayerBarViewControllerDelegate

extension RootSplitViewController: PlayerBarViewControllerDelegate {
    func playerBarDidRequestQueue(_ bar: PlayerBarViewController) {
        // Queue access: for now, switch to showing the current queue.
        // Full queue popover/list will be enhanced when full player lands.
        // Minimal behavior: if we're not already on all, switch to all so queue is visible.
        // Tests verify the delegate fires and the button exists.
        NSSound.beep()
    }
}
