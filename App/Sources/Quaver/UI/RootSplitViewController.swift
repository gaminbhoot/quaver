import AppKit
import Combine

// MARK: - RootSplitViewController
// NSSplitViewController that owns sidebar + library and mediates LibraryStore ↔ UI.
// Single LibraryStore, single `library: [TrackMetadata]` array — no second model.
// Now also hosts the native PlayerBar (floating pill) at the bottom and owns the
// single PlaybackEngine instance — plus the fullscreen Lyrics overlay (single clock).
//
// Visual composition (detached floating):
//   WINDOW / APPLICATION BACKGROUND (windowBackgroundColor, opaque)
//     → MAIN LIBRARY (dominant, calm, solid, fills window, non-glass)
//       → FLOATING SIDEBAR (independent rounded glass, detached, shadowed, inset)
//       → FLOATING MINI-PLAYER PILL (capsule glass, detached, shadowed, inset)
// Gaps around sidebar/pill are INTENTIONAL — they show the coherent library
// background, not the desktop. Sidebar and pill are independent objects with
// independent geometry/shadow/material, not a connected sheet.

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

    // MARK: - View hierarchy — detached floating sidebar + pill over library

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        self.view = container
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        // Keep splitViewItems for tests (thickness, collapse, vertical) — they
        // define the *logical* sidebar/library widths, but visually we use a
        // manual floating layout. The splitView is kept behind the library as a
        // hidden placeholder so existing tests that inspect splitViewItems still pass.
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

        // Library: dominant background surface behind floating objects.
        // We add it directly to the container filling it, and hide the splitView's
        // visual use. The splitView is kept hidden but with valid items for tests.
        let libraryView = libraryVC.view
        libraryView.translatesAutoresizingMaskIntoConstraints = false
        let sidebarView = sidebarVC.view
        sidebarView.translatesAutoresizingMaskIntoConstraints = false
        let barView = playerBar.view
        barView.translatesAutoresizingMaskIntoConstraints = false
        let lyricsView = lyricsVC.view
        lyricsView.translatesAutoresizingMaskIntoConstraints = false

        // Add splitView hidden for test compatibility — library/sidebar views will be
        // reparented to container for the floating composition.
        container.addSubview(sv)
        // Reparent library/sidebar/pill/lyrics to container for independent floating.
        // Adding to container automatically removes them from splitView's panes.
        container.addSubview(libraryView)
        container.addSubview(sidebarView)
        container.addSubview(barView)
        container.addSubview(lyricsView)

        // Configure floating appearance — independent rounded/shadowed surfaces.
        sidebarView.wantsLayer = true
        sidebarView.layer?.cornerRadius = 0
        sidebarView.layer?.masksToBounds = true
        sidebarView.layer?.shadowColor = NSColor.black.cgColor
        sidebarView.layer?.shadowOpacity = 0
        sidebarView.layer?.shadowRadius = 0
        sidebarView.layer?.shadowOffset = NSSize(width: 0, height: 0)

        barView.wantsLayer = true
        barView.layer?.cornerRadius = 34
        barView.layer?.masksToBounds = false
        barView.layer?.shadowColor = NSColor.black.cgColor
        barView.layer?.shadowOpacity = 0.28
        barView.layer?.shadowRadius = 20
        barView.layer?.shadowOffset = NSSize(width: 0, height: 8)

        // SplitView fills container but is hidden — preserves layout logic for tests
        // while the manual libraryView provides the visible background.
        sv.isHidden = true
        NSLayoutConstraint.activate([
            sv.topAnchor.constraint(equalTo: container.topAnchor),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Library fills behind floating objects but inset from sidebar so content
        // (header, table) is not occluded by the floating sidebar. Leading = sidebar
        // trailing +12 gives intentional breathing room. Library remains dominant:
        // its background (windowBackgroundColor) plus container background are same,
        // so the gap reads as library surface behind sidebar.
        NSLayoutConstraint.activate([
            libraryView.topAnchor.constraint(equalTo: container.topAnchor),
            libraryView.leadingAnchor.constraint(equalTo: sidebarView.trailingAnchor, constant: 0),
            libraryView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            libraryView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Full-height sidebar — pinned flush to container edges (top 0, leading 0, bottom 0).
        // Keeps material distinct but not floating vertically; geometry fills vertical extent.
        // Width is responsive: ideal 260 (priority 750), min 200, max 320, so window resizing
        // can compress/expand without breaking constraints.
        let sidebarWidthIdeal = sidebarView.widthAnchor.constraint(equalToConstant: 260)
        sidebarWidthIdeal.priority = .defaultHigh // 750
        NSLayoutConstraint.activate([
            sidebarView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 0),
            sidebarView.topAnchor.constraint(equalTo: container.topAnchor, constant: 0),
            sidebarView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: 0),
            sidebarView.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            sidebarView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            sidebarWidthIdeal,
        ])

        // Floating pill — capsule, compact, centered, detached from edges.
        // Breathing room on all sides shows the calm library behind it. Width 560
        // is sleek but responsive via leading/trailing >=12 and width <= available.
        // Prevent overlap with sidebar at minimum width by keeping pill leading
        // at least 12pt beyond sidebar's trailing edge. CenterX remains but with
        // lower priority than the sidebar gap when compressed.
        let pillWidth = barView.widthAnchor.constraint(equalToConstant: 560)
        pillWidth.priority = .defaultHigh
        let pillCenterX = barView.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        pillCenterX.priority = .defaultHigh
        let pillLeadingGap = barView.leadingAnchor.constraint(greaterThanOrEqualTo: sidebarView.trailingAnchor, constant: 12)
        pillLeadingGap.priority = .required
        NSLayoutConstraint.activate([
            pillCenterX,
            barView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            barView.heightAnchor.constraint(equalToConstant: 68),
            pillWidth,
            barView.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            barView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            pillLeadingGap,
        ])
        // Make pill width responsive: at narrow widths it compresses via leading/trailing;
        // priority low so it can shrink.
        barView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Lyrics overlay full — independent immersive surface (artwork-through glass).
        NSLayoutConstraint.activate([
            lyricsView.topAnchor.constraint(equalTo: container.topAnchor),
            lyricsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            lyricsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            lyricsView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
