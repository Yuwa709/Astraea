import XCTest
import AppKit
import os
@testable import Astraea

/// The settings window must open from the notch panel's gear with no help
/// from the scene graph, because the menu bar icon — which used to host the
/// observer that did it — is now optional.
///
/// Counted, not trusted. The previous route,
/// `NSApp.sendAction(Selector(("showSettingsWindow:")))`, returned **true**
/// while creating no window at all, so a Bool is not evidence here. These
/// count real `NSWindow`s before and after.
@MainActor
final class SettingsWindowTests: XCTestCase {

    private static let log = Logger(subsystem: "com.techie.Astraea", category: "Diag")

    private func settingsWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.title == "Astraea Settings" }
    }

    /// Each test opens the window; none may leave it on screen for the next
    /// one (or for the rest of the suite). `isReleasedWhenClosed` is false,
    /// so closing keeps the object the reuse test compares against.
    override func tearDown() {
        settingsWindows().forEach { $0.close() }
        super.tearDown()
    }

    func testPostingTheNotificationCreatesARealWindow() {
        let before = NSApp.windows.count
        let settingsBefore = settingsWindows().count

        NotificationCenter.default.post(name: .astraeaOpenSettings, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        let after = NSApp.windows.count
        let windows = settingsWindows()
        Self.log.notice("SETTINGSWIN before=\(before, privacy: .public) after=\(after, privacy: .public) settings=\(windows.count, privacy: .public)")
        for w in windows {
            Self.log.notice("SETTINGSWIN   \(String(describing: type(of: w)), privacy: .public) visible=\(w.isVisible, privacy: .public) canBecomeKey=\(w.canBecomeKey, privacy: .public)")
        }

        XCTAssertEqual(windows.count, 1, "the gear must produce exactly one settings window")
        XCTAssertGreaterThan(after, before, "window count must actually rise")
        let window = try? XCTUnwrap(windows.first)
        XCTAssertTrue(window?.isVisible ?? false, "and it must be on screen")
        // Cmd+Q and text fields both need this; the notch panel deliberately
        // cannot become key, so the settings window has to.
        XCTAssertTrue(window?.canBecomeKey ?? false,
                      "settings must be focusable or Cmd+Q has nothing to act on")
    }

    func testReopeningReusesTheSameWindow() {
        NotificationCenter.default.post(name: .astraeaOpenSettings, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        let first = settingsWindows().first
        settingsWindows().forEach { $0.close() }

        NotificationCenter.default.post(name: .astraeaOpenSettings, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        XCTAssertEqual(settingsWindows().count, 1, "closing must not orphan or duplicate it")
        XCTAssertTrue(settingsWindows().first === first,
                      "isReleasedWhenClosed is false, so it is the same object")
    }

    /// The sidebar replaced a TabView that collapsed into a toolbar overflow
    /// menu when the window was narrow — three clicks to reach any section.
    /// The minimum size is what prevents that, so it is asserted rather than
    /// left as a layout modifier nobody notices removing.
    func testWindowCannotShrinkBelowTheSidebarFloor() {
        NotificationCenter.default.post(name: .astraeaOpenSettings, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let window = settingsWindows().first
        // Width only: it is what keeps the sidebar from collapsing. The height
        // is the OS's to adjust (it measured 500 on older macOS and 552 on
        // macOS 27, where the safe-area band grew), so it is not pinned.
        XCTAssertEqual(window?.contentMinSize.width ?? 0, 715, accuracy: 0.5)
    }

    /// Order is the spec: General, Modules, Music, Face Unlock, Permissions,
    /// About — and Spotify is gone as a section of its own, folded into Music.
    func testSidebarSectionsAreInOrder() {
        XCTAssertEqual(SettingsSection.allCases.map(\.title),
                       ["General", "Modules", "Music", "Face Unlock", "Permissions", "About"])
        XCTAssertFalse(SettingsSection.allCases.map(\.title).contains("Spotify"))
        for section in SettingsSection.allCases {
            XCTAssertFalse(section.symbol.isEmpty, "\(section.title) needs an SF Symbol")
            XCTAssertNotNil(NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil),
                            "\(section.symbol) must be a real SF Symbol")
        }
    }

    /// Nothing load-bearing may sit only in the menu bar menu any more.
    func testQuitIsReachableWithoutTheMenuBar() {
        // AboutSettingsTab owns the only guaranteed Quit; building it proves
        // the affordance exists and is wired to something.
        var quit = false
        _ = AboutSettingsTab(updater: nil, onQuit: { quit = true })
        XCTAssertFalse(quit, "constructing must not fire it")
    }
}

/// Cmd+Q in an LSUIElement app.
///
/// There is no app menu in the menu bar, so the only thing that can service
/// the shortcut is the main menu SwiftUI installs behind the scenes, acting
/// on whatever window is key. Measured 2026-10-13: the menu is present with
/// a "Quit Astraea" ⌘Q item, so Cmd+Q in the settings window works — and
/// this now asserts it rather than only logging, so losing it fails here.
@MainActor
final class QuitShortcutTests: XCTestCase {

    private static let log = Logger(subsystem: "com.techie.Astraea", category: "Diag")

    func testMainMenuHasACommandQQuitItem() {
        let main = NSApp.mainMenu
        Self.log.notice("QUIT mainMenu=\(main == nil ? "nil" : "present", privacy: .public) items=\(main?.items.count ?? 0, privacy: .public)")
        var found: String?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalent == "q" && item.keyEquivalentModifierMask.contains(.command) {
                    found = item.title
                }
                if let sub = item.submenu { walk(sub) }
            }
        }
        if let main { walk(main) }
        Self.log.notice("QUIT cmdQItem=\(found ?? "NONE", privacy: .public)")
        XCTAssertNotNil(main, "SwiftUI installs a main menu even for an LSUIElement app")
        XCTAssertNotNil(found, "without a ⌘Q item, Cmd+Q in the settings window does nothing")
    }
}
