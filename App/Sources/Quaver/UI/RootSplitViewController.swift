import AppKit
import Combine

// MARK: - RootSplitViewController
// NSSplitViewController that owns sidebar + library and mediates LibraryStore ↔ UI.
// Single LibraryStore, single `library: [TrackMetadata]` array — no second model.
// Now also hosts the native PlayerBar (mini-player) at the bottom and owns the
// single PlaybackEngine instance — plus the fullscreen Lyrics overlay (single clock).

@MainActor
final class RootSplitViewController: NSSplitViewController {

    let store: LibraryStore
    let engine: NativePlaybackEngine
    let playerBar: PlayerBarViewController
    let lyricsVC: LyricsViewController

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
        self.lyricsVC = LyricsViewController(engine: eng)
        if let s = store { self.store = s } else { self.store = LibraryStore() }
        super.init(nibName: nil, bundle: nil)
        self.playerBar.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - View hierarchy — container with splitView + playerBar + lyrics overlay

    override func loadView() {
        // Liquid Glass container — on Tahoe this groups sidebar + PlayerBar
        // glass so they share a single depth context and transitions are
        // seamless (no hard opaque rectangles). Background is clear so
        // .behindWindow glass (sidebar / PlayerBar) shows desktop blur with
        // depth, while the library pane's own opaque view covers its area.
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = 12
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            self.view = container
        } else {
            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.clear.cgColor
            self.view = container
        }
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

        store.didChangePublisher.sink { [weak self] _ in
            guard let self else { return }
            self.sidebarVC.updatePlaylists(self.store.playlists)
        }.store(in: &cancellables)

        sidebarVC.selectView(.all)
        libraryVC.setView(.all)

        let container = self.view
        let sv = self.splitView
        sv.translatesAutoresizingMaskIntoConstraints = false
        let barView = playerBar.view
        barView.translatesAutoresizingMaskIntoConstraints = false
        // Lyrics overlay — held strongly by self.lyricsVC, view manually added.
        // Do NOT use addChild (would create a split item). Keep splitViewItems == 2.
        let lyricsView = lyricsVC.view
        lyricsView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sv)
        container.addSubview(barView)
        container.addSubview(lyricsView)

        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: container.topAnchor),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: barView.topAnchor),

            barView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            barView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            barView.heightAnchor.constraint(equalToConstant: 76),

            lyricsView.topAnchor.constraint(equalTo: container.topAnchor),
            lyricsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lyricsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lyricsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Ensure lyrics is on top
        lyricsView.wantsLayer = true
        lyricsView.layer?.zPosition = 100

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

    // MARK: - Lyrics overlay API

    func openLyrics() { lyricsVC.open() }
    func closeLyrics() { lyricsVC.close() }
    func toggleLyrics() {
        if lyricsVC.isLyricsActive { lyricsVC.close() } else { lyricsVC.open() }
    }
    var isLyricsVisible: Bool { lyricsVC.isLyricsActive && !lyricsVC.view.isHidden }

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
        if let libIndex = library.firstIndex(where: { $0.key == track.key }) {
            engine.play(trackAt: libIndex)
        } else if !visible.isEmpty {
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
        NSSound.beep()
    }
    func playerBarDidRequestLyrics(_ bar: PlayerBarViewController) {
        toggleLyrics()
    }
}
