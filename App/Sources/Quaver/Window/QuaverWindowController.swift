import AppKit

final class QuaverWindowController: NSWindowController {
    convenience init() {
        let window = QuaverWindow()
        self.init(window: window)
        window.center()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.makeKeyAndOrderFront(nil)
    }
}
