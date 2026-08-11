import AppKit

// MARK: - QuaverMenuBuilder
// Single owner of the macOS main menu. No HTML menu. No Tauri menu.
// All playback actions go through PlaybackEngine (single source of truth).
// All navigation goes through RootSplitViewController.

@MainActor
enum QuaverMenuBuilder {

    static func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // MARK: App (Quaver)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Quaver", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Preferences…", action: #selector(QuaverApp.showPreferences(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Quaver", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h", modifierMask: [.command, .option]))
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Quaver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        appMenuItem.title = "Quaver"

        // MARK: File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Add Music Folder…", action: #selector(QuaverApp.addMusicFolder(_:)), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "New Playlist", action: #selector(QuaverApp.createPlaylist(_:)), keyEquivalent: "n"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        fileItem.title = "File"

        // MARK: Edit
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find…", action: #selector(QuaverApp.find(_:)), keyEquivalent: "f"))
        editItem.submenu = editMenu
        editItem.title = "Edit"

        // MARK: Playback
        let playbackItem = NSMenuItem()
        mainMenu.addItem(playbackItem)
        let playbackMenu = NSMenu(title: "Playback")
        playbackMenu.addItem(NSMenuItem(title: "Play / Pause", action: #selector(QuaverApp.togglePlay(_:)), keyEquivalent: " "))
        // Space as keyEquivalent is handled via menu; also via direct Space handler with text-field guard.
        playbackMenu.addItem(NSMenuItem(title: "Next Track", action: #selector(QuaverApp.nextTrack(_:)), keyEquivalent: "]", modifierMask: [.command]))
        playbackMenu.addItem(NSMenuItem(title: "Previous Track", action: #selector(QuaverApp.previousTrack(_:)), keyEquivalent: "[", modifierMask: [.command]))
        playbackMenu.addItem(.separator())
        let shuffleItem = NSMenuItem(title: "Shuffle", action: #selector(QuaverApp.toggleShuffle(_:)), keyEquivalent: "s", modifierMask: [.command, .shift])
        shuffleItem.state = .off
        shuffleItem.identifier = NSUserInterfaceItemIdentifier("playback.shuffle")
        playbackMenu.addItem(shuffleItem)
        let repeatItem = NSMenuItem(title: "Repeat", action: #selector(QuaverApp.cycleRepeat(_:)), keyEquivalent: "r", modifierMask: [.command, .shift])
        repeatItem.identifier = NSUserInterfaceItemIdentifier("playback.repeat")
        playbackMenu.addItem(repeatItem)
        playbackItem.submenu = playbackMenu
        playbackItem.title = "Playback"

        // MARK: View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(title: "All Songs", action: #selector(QuaverApp.viewAllSongs(_:)), keyEquivalent: "1"))
        viewMenu.addItem(NSMenuItem(title: "Liked Songs", action: #selector(QuaverApp.viewLikedSongs(_:)), keyEquivalent: "2"))
        viewMenu.addItem(NSMenuItem(title: "Recently Played", action: #selector(QuaverApp.viewRecentlyPlayed(_:)), keyEquivalent: "3"))
        viewMenu.addItem(NSMenuItem(title: "Artists", action: #selector(QuaverApp.viewArtists(_:)), keyEquivalent: "4"))
        viewMenu.addItem(NSMenuItem(title: "Albums", action: #selector(QuaverApp.viewAlbums(_:)), keyEquivalent: "5"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Find…", action: #selector(QuaverApp.find(_:)), keyEquivalent: "k"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Show Lyrics", action: #selector(QuaverApp.toggleLyrics(_:)), keyEquivalent: "l"))
        viewMenu.addItem(.separator())
        viewMenu.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f", modifierMask: [.command, .control]))
        viewItem.submenu = viewMenu
        viewItem.title = "View"

        // MARK: Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        windowItem.submenu = windowMenu
        windowItem.title = "Window"
        // Tell AppKit this is the Windows menu so it auto-populates window list.
        NSApp?.windowsMenu = windowMenu

        // MARK: Help
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "Quaver Help", action: #selector(QuaverApp.showHelp(_:)), keyEquivalent: "?"))
        helpItem.submenu = helpMenu
        helpItem.title = "Help"
        NSApp?.helpMenu = helpMenu

        return mainMenu
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, modifierMask: NSEvent.ModifierFlags = .command) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.keyEquivalentModifierMask = modifierMask
    }
}
