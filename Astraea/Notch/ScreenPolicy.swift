import AppKit
import os

/// The single place that decides which screen owns the notch panel.
///
/// Policy (ROADMAP Phase 1, task 4): the panel lives on the built-in display,
/// always, even when an external monitor is primary. Only when no built-in
/// display is available (clamshell mode) does it fall back to the menu bar screen,
/// where `NotchPanel` draws its no-notch fallback strip.
enum ScreenPolicy {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "ScreenPolicy")

    static func targetScreen() -> NSScreen? {
        let builtIn = NSScreen.screens.first { isBuiltIn($0) }

        if let builtIn {
            logger.notice("Target screen: built-in \(builtIn.localizedName, privacy: .public)")
            return builtIn
        }

        // `screens.first`, not `NSScreen.main`: `main` is the screen holding
        // the key window, which a background agent rarely has, so it is not
        // reliably the menu bar's screen. The first entry always is.
        if let menuBarScreen = NSScreen.screens.first {
            logger.notice("No built-in display; falling back to menu bar screen \(menuBarScreen.localizedName, privacy: .public)")
            return menuBarScreen
        }

        logger.error("No screens available")
        return nil
    }

    /// The built-in display, only when it has a camera housing; nil in
    /// clamshell mode or on a notchless Mac. No fallback, unlike
    /// `targetScreen()`: for overlays that only make sense beside the notch.
    static func builtInNotchedScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            isBuiltIn(screen) && hasNotch(topInset: screen.safeAreaInsets.top,
                                          leftArea: screen.auxiliaryTopLeftArea,
                                          rightArea: screen.auxiliaryTopRightArea)
        }
    }

    /// Whether a screen's insets describe a camera housing: the same
    /// condition under which `NotchPanel.notchRect(frame:…)` computes a
    /// notch rather than its fallback strip.
    nonisolated static func hasNotch(topInset: CGFloat, leftArea: NSRect?, rightArea: NSRect?) -> Bool {
        topInset > 0 && leftArea != nil && rightArea != nil
    }

    private static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? CGDirectDisplayID else { return false }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }
}
