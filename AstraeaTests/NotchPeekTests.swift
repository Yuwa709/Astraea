import XCTest
import AppKit
@testable import Astraea

/// The two-stage open (2026-10-29): a hover peeks before it opens, so a
/// cursor that lingers briefly near the menu bar no longer flashes the
/// whole panel open and shut.
final class NotchPeekTests: XCTestCase {

    // MARK: - Geometry

    private let housing = NSRect(x: 652, y: 924, width: 184, height: 32)

    func testPeekGrowsSidewaysAboutTheCentreAndDownFromTheTop() {
        let peek = NotchPanel.peekRect(resting: housing)
        XCTAssertEqual(peek.midX, housing.midX, "grows evenly on both sides")
        XCTAssertEqual(peek.maxY, housing.maxY, "the top stays on the screen edge")
        XCTAssertEqual(peek.width, housing.width + NotchPanel.peekSideGrowth * 2)
        XCTAssertEqual(peek.height, housing.height + NotchPanel.peekDownGrowth)
    }

    func testPeekOverTheWingsGrowsFromTheWings() {
        let wings = NotchPanel.compactRect(housing: housing)
        let peek = NotchPanel.peekRect(resting: wings)
        XCTAssertTrue(peek.contains(wings), "never smaller than what it grew from")
        XCTAssertEqual(peek.minX, wings.minX - NotchPanel.peekSideGrowth)
    }

    func testPeekStaysSmallerThanTheOpenPanel() {
        let peek = NotchPanel.peekRect(resting: NotchPanel.compactRect(housing: housing))
        let open = NotchPanel.expandedRect(housing: housing, contentSize: .zero)
        XCTAssertLessThan(peek.height, open.height)
    }

    // MARK: - State precedence

    func testOpenBeatsPeek() {
        XCTAssertEqual(NotchCoordinator.state(expand: true, isPeeking: true, hasWings: true), .expanded)
    }

    func testPeekBeatsTheRestingSilhouette() {
        XCTAssertEqual(NotchCoordinator.state(expand: false, isPeeking: true, hasWings: true), .peek)
        XCTAssertEqual(NotchCoordinator.state(expand: false, isPeeking: true, hasWings: false), .peek)
    }

    func testRestingStatesAreUnchangedWithoutAPeek() {
        XCTAssertEqual(NotchCoordinator.state(expand: false, isPeeking: false, hasWings: true), .compact)
        XCTAssertEqual(NotchCoordinator.state(expand: false, isPeeking: false, hasWings: false), .idle)
    }

    // MARK: - Hover timing

    func testThePeekAlwaysComesBeforeTheOpen() {
        // Including at the shortest settings: the first version skipped the
        // peek at 0.1, which was the user's own setting.
        for delay in [0, 0.1, AppSettings.defaultHoverEnterDelay, 0.35, 1] {
            XCTAssertEqual(NotchHoverView.fullDelay(forEnterDelay: delay) - delay,
                           NotchHoverView.peekHold, accuracy: 0.0001, "at \(delay)")
        }
    }

    func testThePeekHoldsLongEnoughToSee() {
        XCTAssertGreaterThanOrEqual(NotchHoverView.peekHold, 0.3)
    }

    func testExitGraceIsTheOriginal() {
        XCTAssertEqual(NotchHoverView.exitGrace, 0.1, accuracy: 0.0001)
    }

    func testADragOpensNoLaterThanItUsedTo() {
        XCTAssertLessThanOrEqual(NotchHoverView.dragEnterCeiling, 0.35)
    }
}
