import AppKit

// MARK: - SeekSlider
// NSSlider that tracks scrubbing so the player bar can avoid
// fighting the user's drag with engine time updates.

final class SeekSlider: NSSlider {

    /// True while the user is dragging the knob.
    private(set) var isTrackingSeek = false

    override func mouseDown(with event: NSEvent) {
        isTrackingSeek = true
        super.mouseDown(with: event)
        isTrackingSeek = false
        // After the modal drag loop, ensure the final value is sent as an action.
        if let action = action, let target = target {
            NSApp.sendAction(action, to: target, from: self)
        }
    }
}
