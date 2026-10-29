import XCTest
@testable import Astraea

/// Telling a window drag from everything else that presses and drags. Only
/// a moved origin with an unchanged size opens the layout picker; a resize
/// from the top or left edge moves the origin too, and must not.
final class WindowDragMonitorTests: XCTestCase {

    private let start = CGRect(x: 200, y: 120, width: 800, height: 600)

    private func verdict(_ current: CGRect) -> WindowDragMonitor.Verdict {
        WindowDragMonitor.classify(start: start, current: current)
    }

    func testMovedOriginWithSameSizeIsADrag() {
        XCTAssertEqual(verdict(start.offsetBy(dx: 12, dy: -30)), .moved)
    }

    func testOnePointMoveIsADrag() {
        // A slow start to the drag still confirms on the first check.
        XCTAssertEqual(verdict(start.offsetBy(dx: 1, dy: 0)), .moved)
    }

    func testUnmovedWindowIsUnchanged() {
        // A text selection or file drag inside the window.
        XCTAssertEqual(verdict(start), .unchanged)
    }

    func testResizeFromTopLeftIsNotADrag() {
        // Origin and size both change; the size wins.
        let current = CGRect(x: 180, y: 100, width: 820, height: 620)
        XCTAssertEqual(verdict(current), .resized)
    }

    func testResizeFromBottomRightIsNotADrag() {
        XCTAssertEqual(verdict(CGRect(x: 200, y: 120, width: 840, height: 640)), .resized)
    }

    func testSubpointJitterIsUnchanged() {
        // Retina rounding can report half points; that is not a move.
        XCTAssertEqual(verdict(start.offsetBy(dx: 0.5, dy: 0.5)), .unchanged)
    }
}
