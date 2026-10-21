import AppKit
import SwiftUI

/// The lock-screen overlay's window. Separate from `NotchPanel`, which this
/// does not touch: this one exists only while Face Unlock is scanning at the
/// lock screen, and is moved into a level-400 SkyLight space by its
/// presenter, which is what puts it above the lock screen.
///
/// Every property below is the configuration verified on hardware
/// (macOS 27.0.1, 2026-10-15): visible above the lock screen, and a click on
/// it did not take focus from the password field. Change none of them
/// without re-running that check.
final class LockScreenScanPanel: NSPanel {

    // Never key, never main: the password field must keep focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, model: LockScreenScanModel) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        canBecomeVisibleWithoutLogin = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: LockScreenScanView(model: model))
        // The frame is computed from the notch; SwiftUI must not resize it.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        setFrame(frame, display: false)
    }
}
