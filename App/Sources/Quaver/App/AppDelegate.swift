import AppKit

@main
final class QuaverApp: NSObject, NSApplicationDelegate {
    var windowController: QuaverWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Show menu bar — NSApplication without a nib has no main menu by default
        if NSApp.mainMenu == nil {
            let mainMenu = NSMenu()
            let appMenuItem = NSMenuItem()
            mainMenu.addItem(appMenuItem)
            let appMenu = NSMenu()
            appMenu.addItem(NSMenuItem(title: "About Quaver", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
            appMenu.addItem(.separator())
            appMenu.addItem(NSMenuItem(title: "Hide Quaver", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
            appMenu.addItem(NSMenuItem(title: "Quit Quaver", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            appMenuItem.submenu = appMenu

            let editMenuItem = NSMenuItem()
            mainMenu.addItem(editMenuItem)
            let editMenu = NSMenu(title: "Edit")
            editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
            editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
            editMenu.addItem(.separator())
            editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
            editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
            editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
            editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
            editMenuItem.submenu = editMenu

            // Search (⌘K) — window listener handles it, but having it in menu is standard
            let findMenuItem = NSMenuItem()
            mainMenu.addItem(findMenuItem)
            let findMenu = NSMenu(title: "Find")
            findMenu.addItem(NSMenuItem(title: "Find…", action: #selector(NSSearchField.performClick(_:)), keyEquivalent: "k"))
            findMenuItem.submenu = findMenu

            NSApp.mainMenu = mainMenu
        }

        // Global ⌘K focus search (handled inside window via keyDown monitor — simple global monitor)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "k" {
                // Try to focus sidebar search if visible
                if let win = NSApp.keyWindow, let wc = win.windowController as? QuaverWindowController {
                    wc.rootSplit.sidebarVC.view.window?.makeFirstResponder(
                        wc.rootSplit.sidebarVC.view.viewWithTag(0) // fallback
                    )
                    // Search field is the first subview tracking — ask App to find NSSearchField
                    if let field = Self.findSearchField(in: wc.rootSplit.sidebarVC.view) {
                        win.makeFirstResponder(field)
                        return nil // swallow
                    }
                }
            }
            return event
        }

        let controller = QuaverWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func findSearchField(in view: NSView) -> NSSearchField? {
        if let f = view as? NSSearchField { return f }
        for sub in view.subviews { if let hit = findSearchField(in: sub) { return hit } }
        return nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
