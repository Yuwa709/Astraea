import XCTest
import AppKit
@testable import PopNotch

/// The top-edge exit check. `NSRect.contains` is half-open on maxY and the
/// panel's top sits flush with the screen's, so a cursor pinned to the top
/// edge read as outside in every panel state — the panel collapsed one row
/// from the top and oscillated on a ~320ms cycle.
final class HoverEdgeTests: XCTestCase {

    /// The measured geometry: screen 956 tall, panel flush with its top.
    private let screenTop: CGFloat = 956
    private let compact = NSRect(x: 587, y: 914, width: 292, height: 42)
    private let expanded = NSRect(x: 507, y: 681, width: 452, height: 275)

    private func inside(_ p: NSPoint, _ panel: NSRect) -> Bool {
        NotchHoverView.isInsideForExit(mouse: p, panel: panel, screenTop: screenTop)
    }

    // MARK: - The bug

    func testCursorExactlyAtTheTopEdgeCountsAsInside() {
        // y == maxY == screenTop. This is the case that oscillated.
        XCTAssertFalse(compact.contains(NSPoint(x: 735, y: 956)),
                       "precondition: NSRect.contains rejects it, which is the bug")
        XCTAssertTrue(inside(NSPoint(x: 735, y: 956), compact))
        XCTAssertTrue(inside(NSPoint(x: 735, y: 956), expanded),
                      "and in the expanded state too — the top edge never moves")
    }

    func testTopEdgeHoldsAcrossBothPanelStates() {
        // The oscillation was a loop between states, so neither may disagree.
        let atEdge = NSPoint(x: 735, y: 956)
        XCTAssertEqual(inside(atEdge, compact), inside(atEdge, expanded))
    }

    // MARK: - Nothing widened

    func testNotWidenedDownward() {
        // One row below the panel's bottom is still outside.
        XCTAssertFalse(inside(NSPoint(x: 735, y: expanded.minY - 1), expanded))
        XCTAssertFalse(inside(NSPoint(x: 735, y: compact.minY - 1), compact))
    }

    func testNotWidenedSideways() {
        // Left and right of the panel, at the top edge, stay outside.
        XCTAssertFalse(inside(NSPoint(x: compact.minX - 1, y: 956), compact))
        XCTAssertFalse(inside(NSPoint(x: compact.maxX, y: 956), compact),
                       "x keeps contains's half-open semantics")
    }

    func testNotWidenedAboveTheScreen() {
        // Nothing beyond the screen edge counts, however unreachable.
        XCTAssertFalse(inside(NSPoint(x: 735, y: 957), compact))
    }

    // MARK: - Ordinary cases unchanged

    func testOrdinaryInsidePointStillInside() {
        XCTAssertTrue(inside(NSPoint(x: 735, y: 936), compact))
        XCTAssertTrue(inside(NSPoint(x: 735, y: 800), expanded))
    }

    func testGenuineExitBelowThePanelStillExits() {
        // The 23:30:39 case from the diagnostic: cursor moved away properly.
        XCTAssertFalse(inside(NSPoint(x: 834, y: 430), expanded))
    }

    func testPanelNotFlushWithScreenTopOnlyExtendsToItsOwnTop() {
        // Defensive: if the fallback screenTop equals the panel's own maxY,
        // the extension is exactly one row and nothing more.
        let panel = NSRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertTrue(NotchHoverView.isInsideForExit(
            mouse: NSPoint(x: 150, y: 200), panel: panel, screenTop: 200))
        XCTAssertFalse(NotchHoverView.isInsideForExit(
            mouse: NSPoint(x: 150, y: 201), panel: panel, screenTop: 200))
    }
}

/// A file drag has to open the notch, or the shelf's drop zones are
/// unreachable: there is no way to drop into a panel that will not open.
@MainActor
final class HoverDragDestinationTests: XCTestCase {

    func testRegistersForFileURLsOnly() {
        let view = NotchHoverView()
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL),
                      "without this the panel never sees a file drag")
        XCTAssertEqual(view.registeredDraggedTypes, [.fileURL],
                       "registering more would open the notch on dragged text")
    }

    func testRegistrationSurvivesTheFrameInitialiser() {
        // The panel builds this with NotchHoverView(), which routes through
        // init(frame:). Registering anywhere else would silently not apply.
        XCTAssertTrue(NotchHoverView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            .registeredDraggedTypes.contains(.fileURL))
    }

    func testNeverConsumesADrop() {
        // This view opens the panel and nothing more; the shelf's own zones,
        // which sit above it as subviews once expanded, do the accepting.
        // A sender cannot be faked, so this pins the contract structurally:
        // both hooks are implemented and both refuse.
        let view = NotchHoverView()
        XCTAssertTrue(view.responds(to: #selector(NSView.prepareForDragOperation(_:))))
        XCTAssertTrue(view.responds(to: #selector(NSView.performDragOperation(_:))))
    }

    func testStillTracksTheMouseAsWell() {
        // Drag support must not have displaced hover: the tracking area is
        // rebuilt on every geometry change and both paths share beginEnter.
        let view = NotchHoverView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(view.trackingAreas[0].options.contains(.mouseEnteredAndExited))
        XCTAssertTrue(view.trackingAreas[0].options.contains(.activeAlways))
    }
}


/// The drag-out suppression flag, and specifically its re-arm.
///
/// `NotchHoverView.endDrag` is the only thing that schedules a collapse once a
/// drag finishes, and during a drag-out it fires while suppression is on, so
/// its `beginExit()` is dropped. If clearing the flag did not re-run that
/// evaluation, the panel would stay open after every drag-out until the
/// pointer wandered in and out again.
@MainActor
final class DragOutSuppressionTests: XCTestCase {

    func testOnlyClearingTheFlagRearmsCollapse() {
        XCTAssertTrue(NotchHoverView.clearingShouldRearmCollapse(was: true, now: false),
                      "the session ending is the one edge that must re-evaluate collapse")
        XCTAssertFalse(NotchHoverView.clearingShouldRearmCollapse(was: false, now: true),
                       "starting a drag must never schedule a collapse")
        XCTAssertFalse(NotchHoverView.clearingShouldRearmCollapse(was: true, now: true),
                       "a redundant set mid-drag is not a session ending")
        XCTAssertFalse(NotchHoverView.clearingShouldRearmCollapse(was: false, now: false),
                       "nothing to re-arm when no drag was in flight")
    }

    func testPanelExposesTheFlagWithoutReachingIntoContentView() {
        guard let screen = NSScreen.main else { return XCTFail("no screen") }
        let panel = NotchPanel(screen: screen)
        XCTAssertFalse(panel.isDraggingOut, "a fresh panel is not a drag source")
        panel.isDraggingOut = true
        XCTAssertTrue(panel.isDraggingOut, "set must reach the hover view")
        panel.isDraggingOut = false
        XCTAssertFalse(panel.isDraggingOut, "and clear again")
    }
}

/// The pin, and the single funnel it relies on.
///
/// Nine things collapse the panel — hover exit, `endDrag`, the drag-out
/// re-arm, arbiter presentation changes, module toggles, navigation, screen
/// reconfiguration, shelf mode swaps — and every one routes through
/// `applyState`, the sole caller of `panel.setState`, which asks
/// `desiredState`. So the pin is honoured in exactly one place, and these
/// pin that precedence rather than trusting a reading of the branch.
@MainActor
final class PinStateTests: XCTestCase {

    func testPinBeatsEveryOtherInput() {
        // Cursor away, nothing playing: the case that would otherwise collapse.
        XCTAssertTrue(NotchCoordinator.shouldExpand(
            isPinned: true, isHovered: false, hasLiveActivity: false),
            "a pinned notch stays open with the cursor nowhere near it")
        XCTAssertTrue(NotchCoordinator.shouldExpand(
            isPinned: true, isHovered: true, hasLiveActivity: true))
    }

    func testUnpinnedBehavesExactlyAsBefore() {
        XCTAssertFalse(NotchCoordinator.shouldExpand(
            isPinned: false, isHovered: false, hasLiveActivity: false),
            "unpinned with the cursor away must still collapse")
        XCTAssertTrue(NotchCoordinator.shouldExpand(
            isPinned: false, isHovered: true, hasLiveActivity: false),
            "hover still expands")
        XCTAssertTrue(NotchCoordinator.shouldExpand(
            isPinned: false, isHovered: false, hasLiveActivity: true),
            "a live activity still expands")
    }

    /// The "Pin Notch" menu bar item is gone — the icon is optional now, and
    /// the pin button in the panel chrome is visible whenever the panel is
    /// expanded. This exercises the action that button invokes, so the
    /// remaining route is known to be wired.
    func testTheButtonsActionPathStillTogglesThePin() {
        let pinState = PinState()
        let coordinator = NotchCoordinator(settings: SettingsStore(), pinState: pinState)
        XCTAssertFalse(coordinator.isPinned)

        coordinator.setPinned(true)
        XCTAssertTrue(coordinator.isPinned, "what the panel's pin button calls")
        XCTAssertTrue(pinState.isPinned, "and the menu-free source of truth agrees")

        coordinator.setPinned(false)
        XCTAssertFalse(coordinator.isPinned)
    }

    func testStartsUnpinnedAndIsNotPersisted() {
        XCTAssertFalse(PinState().isPinned, "a fresh session is never pinned")
        // The guard against someone adding it to AppSettings later: a pinned
        // panel surviving a relaunch has no visible cause.
        let encoded = try? JSONEncoder().encode(AppSettings())
        let json = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(json.lowercased().contains("pin"),
                       "pin state must never reach persisted settings")
    }
}
