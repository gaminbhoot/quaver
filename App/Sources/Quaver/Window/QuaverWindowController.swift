import AppKit

final class QuaverWindowController: NSWindowController {

    let rootSplit: RootSplitViewController

    convenience init() {
        let window = QuaverWindow()
        self.init(window: window, rootSplit: RootSplitViewController())
    }

    init(window: QuaverWindow, rootSplit: RootSplitViewController) {
        self.rootSplit = rootSplit
        super.init(window: window)
        // Host the split controller in the window — replaces the placeholder contentView
        window.contentViewController = rootSplit
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.makeKeyAndOrderFront(nil)
    }
}
