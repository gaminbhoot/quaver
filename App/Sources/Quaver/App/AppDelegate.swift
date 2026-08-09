import AppKit

@main
final class QuaverApp: NSObject, NSApplicationDelegate {
    var windowController: QuaverWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = QuaverWindowController()
        controller.showWindow(nil)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}
