import AppKit
import Combine

// MARK: - RootSplitViewController
// NSSplitViewController that owns sidebar + library and mediates LibraryStore ↔ UI.
// Single LibraryStore, single `library: [TrackMetadata]` array — no second model.
// No WKWebView / HTML. Pure AppKit Auto Layout. Sidebar + table + header + empty states.

@MainActor
final class RootSplitViewController: NSSplitViewController {

    let store: LibraryStore
    private(set) var library: [TrackMetadata] = []
    private(set) var selectedView: LibraryView = .all
    private(set) var searchQuery: String = ""

    let sidebarVC = SidebarViewController()
    let libraryVC = LibraryViewController()

    private var cancellables = Set<AnyCancellable>()
    private var isLoadingLibrary = false { didSet { libraryVC.setLoading(isLoadingLibrary) } }

    // MARK: - Init

    init(store: LibraryStore? = nil) {
        if let s = store { self.store = s } else { self.store = LibraryStore() }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

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
            // libraryVC already observes didChangePublisher itself; sidebar is the only one we need to forward here.
        }.store(in: &cancellables)

        sidebarVC.selectView(.all)
        libraryVC.setView(.all)

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
        if case .recent = selectedView {
            libraryVC.setView(selectedView)
        }
    }

    func libraryDidRequestAddFolder() {
        handleAddFolderRequest()
    }
}
