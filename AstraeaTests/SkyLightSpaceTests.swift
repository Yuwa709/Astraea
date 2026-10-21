import XCTest
import AppKit
@testable import Astraea

/// `SkyLightSpace`'s lifecycle against fake C functions handed out through
/// `SkyLightAPI`'s resolver. The real SkyLight is never loaded or called.
final class SkyLightSpaceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FakeSkyLight.reset()
    }

    private func makeAPI() throws -> SkyLightAPI {
        try XCTUnwrap(SkyLightAPI(resolve: FakeSkyLight.resolve))
    }

    func testCreateSetsTheLevelThenShows() throws {
        let space = try XCTUnwrap(SkyLightSpace(api: makeAPI()))
        XCTAssertEqual(space.spaceID, FakeSkyLight.spaceIDToCreate)
        XCTAssertEqual(FakeSkyLight.calls, [
            "connection", "create", "level 42 400", "show 42",
        ])
        withExtendedLifetime(space) {}
    }

    func testCreateReturningNoSpaceFailsAndCallsNothingElse() throws {
        FakeSkyLight.spaceIDToCreate = 0
        XCTAssertNil(SkyLightSpace(api: try makeAPI()))
        XCTAssertEqual(FakeSkyLight.calls, ["connection", "create"],
                       "no level, show or destroy for a space that does not exist")
    }

    func testAddWindowMovesItIntoTheSpace() throws {
        let space = try XCTUnwrap(SkyLightSpace(api: makeAPI()))
        FakeSkyLight.calls = []
        space.addWindow(number: 77)
        XCTAssertEqual(FakeSkyLight.calls, ["add 42 [77] mode 7"])
        withExtendedLifetime(space) {}
    }

    func testDestroyHidesThenDestroysOnceOnly() throws {
        let space = try XCTUnwrap(SkyLightSpace(api: makeAPI()))
        FakeSkyLight.calls = []
        space.destroy()
        space.destroy()
        space.addWindow(number: 77)
        XCTAssertTrue(space.isDestroyed)
        XCTAssertEqual(FakeSkyLight.calls, ["hide 42", "destroy 42"],
                       "idempotent, and nothing is added to a destroyed space")
    }

    func testDeinitDestroys() throws {
        var space = SkyLightSpace(api: try makeAPI())
        XCTAssertNotNil(space)
        FakeSkyLight.calls = []
        space = nil
        XCTAssertEqual(FakeSkyLight.calls, ["hide 42", "destroy 42"])
    }

    func testDeinitAfterDestroyDoesNotDestroyAgain() throws {
        var space = SkyLightSpace(api: try makeAPI())
        space?.destroy()
        FakeSkyLight.calls = []
        space = nil
        XCTAssertEqual(FakeSkyLight.calls, [])
    }
}

/// The real `LockScreenScanPresenter` against the fake SkyLight: the space's
/// whole lifecycle around a real (never key, mouse-transparent) panel. The
/// panel is ordered in briefly at alpha 0 or 1; the real SkyLight is never
/// loaded, so it never reaches the lock-screen level.
@MainActor
final class LockScreenScanPresenterTests: XCTestCase {

    /// Every test starts here, which also resets the fake.
    private func makePresenter() throws -> LockScreenScanPresenter {
        FakeSkyLight.reset()
        guard let screen = NSScreen.screens.first else { throw XCTSkip("no screen to place the panel on") }
        return LockScreenScanPresenter(loadSkyLight: { SkyLightAPI(resolve: FakeSkyLight.resolve) },
                                       findScreen: { screen })
    }

    private var visiblePanels: [NSWindow] {
        NSApplication.shared.windows.filter { $0 is LockScreenScanPanel && $0.isVisible }
    }

    private func count(_ prefix: String) -> Int {
        FakeSkyLight.calls.filter { $0.hasPrefix(prefix) }.count
    }

    /// Records, at the moment the space is destroyed, whether any overlay
    /// window was still on screen.
    private func recordVisibilityAtDestroy() -> () -> [Bool] {
        var seen: [Bool] = []
        FakeSkyLight.onDestroy = {
            MainActor.assumeIsolated {
                seen.append(NSApplication.shared.windows.contains { $0 is LockScreenScanPanel && $0.isVisible })
            }
        }
        return { seen }
    }

    func testShowCreatesTheSpaceAndMovesTheWindowIntoIt() throws {
        let presenter = try makePresenter()
        XCTAssertTrue(presenter.present(.scanning, reduceMotion: true))
        defer { presenter.dismiss(animated: false, reason: "test") }
        XCTAssertTrue(presenter.isPresented)
        XCTAssertEqual(Array(FakeSkyLight.calls.prefix(4)), ["connection", "create", "level 42 400", "show 42"])
        let panel = try XCTUnwrap(visiblePanels.first)
        XCTAssertEqual(FakeSkyLight.calls.last, "add 42 [\(panel.windowNumber)] mode 7",
                       "on screen first, then into the space")
        XCTAssertEqual(panel.alphaValue, 1, "Reduce Motion: shown at once, no fade-in")
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertTrue(presenter.present(.matched, reduceMotion: true), "already up: updated in place")
        XCTAssertEqual(count("create"), 1, "no second space")
    }

    func testHideTakesTheWindowOffScreenThenDestroysTheSpaceOnce() throws {
        let presenter = try makePresenter()
        let visibleAtDestroy = recordVisibilityAtDestroy()
        XCTAssertTrue(presenter.present(.scanning, reduceMotion: false))
        presenter.dismiss(animated: false, reason: "test")
        XCTAssertFalse(presenter.isPresented)
        XCTAssertFalse(presenter.isFadingOut)
        XCTAssertEqual(Array(FakeSkyLight.calls.suffix(2)), ["hide 42", "destroy 42"])
        XCTAssertEqual(visibleAtDestroy(), [false], "window off screen before its space goes")
        XCTAssertTrue(visiblePanels.isEmpty)
        presenter.dismiss(animated: false, reason: "test, again")
        presenter.dismiss(animated: true, reason: "test, again animated")
        XCTAssertEqual(count("destroy"), 1, "hiding twice destroys nothing twice")
        XCTAssertFalse(presenter.isFadingOut)
    }

    func testAFadeOutDestroysTheSpaceWhenItEnds() throws {
        let presenter = try makePresenter()
        let visibleAtDestroy = recordVisibilityAtDestroy()
        XCTAssertTrue(presenter.present(.failed, reduceMotion: false))
        let finished = expectation(description: "fade finished")
        presenter.onFadeOutFinished = { finished.fulfill() }
        presenter.dismiss(animated: true, reason: "test")
        XCTAssertTrue(presenter.isFadingOut)
        XCTAssertEqual(count("destroy"), 0, "the space outlives the fade")
        wait(for: [finished], timeout: 5)
        XCTAssertFalse(presenter.isFadingOut)
        XCTAssertEqual(count("destroy"), 1)
        XCTAssertEqual(visibleAtDestroy(), [false])
        XCTAssertTrue(visiblePanels.isEmpty)
    }

    func testAnInstantHideEndsAFadeAndDestroysEverySpaceOnce() throws {
        let presenter = try makePresenter()
        XCTAssertTrue(presenter.present(.scanning, reduceMotion: false))
        presenter.dismiss(animated: true, reason: "fade")
        XCTAssertTrue(presenter.present(.scanning, reduceMotion: false))
        XCTAssertEqual(count("create"), 2, "a new presentation during a fade gets its own space")
        presenter.dismiss(animated: false, reason: "kill switch")
        XCTAssertFalse(presenter.isFadingOut)
        XCTAssertFalse(presenter.isPresented)
        XCTAssertEqual(count("destroy"), 2, "both spaces, each once")
        XCTAssertTrue(visiblePanels.isEmpty)
        // The cancelled fade's completion, if it still fires, finds nothing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(count("destroy"), 2)
    }
}

/// Fake SkyLight entry points. `@convention(c)` closures cannot capture, so
/// they record into static state, reset before each test.
private enum FakeSkyLight {

    nonisolated(unsafe) static var calls: [String] = []
    nonisolated(unsafe) static var spaceIDToCreate: UInt64 = 42
    /// Runs inside the fake `SLSSpaceDestroy`, before it returns.
    nonisolated(unsafe) static var onDestroy: (() -> Void)?

    static func reset() {
        calls = []
        spaceIDToCreate = 42
        onDestroy = nil
    }

    static func ids(_ array: CFArray) -> String {
        let numbers = (array as NSArray).compactMap { ($0 as? NSNumber)?.uint64Value }
        return numbers.map(String.init).joined(separator: ",")
    }

    static let connection: SkyLightAPI.MainConnectionID = {
        FakeSkyLight.calls.append("connection")
        return 9
    }
    static let create: SkyLightAPI.SpaceCreate = { _, _, _ in
        FakeSkyLight.calls.append("create")
        return FakeSkyLight.spaceIDToCreate
    }
    static let setLevel: SkyLightAPI.SpaceSetAbsoluteLevel = { _, space, level in
        FakeSkyLight.calls.append("level \(space) \(level)")
    }
    static let show: SkyLightAPI.ShowHideSpaces = { _, spaces in
        FakeSkyLight.calls.append("show \(FakeSkyLight.ids(spaces))")
    }
    static let hide: SkyLightAPI.ShowHideSpaces = { _, spaces in
        FakeSkyLight.calls.append("hide \(FakeSkyLight.ids(spaces))")
    }
    static let addWindows: SkyLightAPI.SpaceAddWindows = { _, space, windows, mode in
        FakeSkyLight.calls.append("add \(space) [\(FakeSkyLight.ids(windows))] mode \(mode)")
    }
    static let destroy: SkyLightAPI.SpaceDestroy = { _, space in
        FakeSkyLight.calls.append("destroy \(space)")
        FakeSkyLight.onDestroy?()
    }

    static func resolve(_ name: String) -> UnsafeMutableRawPointer? {
        switch name {
        case "SLSMainConnectionID": unsafeBitCast(connection, to: UnsafeMutableRawPointer.self)
        case "SLSSpaceCreate": unsafeBitCast(create, to: UnsafeMutableRawPointer.self)
        case "SLSSpaceSetAbsoluteLevel": unsafeBitCast(setLevel, to: UnsafeMutableRawPointer.self)
        case "SLSShowSpaces": unsafeBitCast(show, to: UnsafeMutableRawPointer.self)
        case "SLSHideSpaces": unsafeBitCast(hide, to: UnsafeMutableRawPointer.self)
        case "SLSSpaceAddWindowsAndRemoveFromSpaces": unsafeBitCast(addWindows, to: UnsafeMutableRawPointer.self)
        case "SLSSpaceDestroy": unsafeBitCast(destroy, to: UnsafeMutableRawPointer.self)
        default: nil
        }
    }
}
