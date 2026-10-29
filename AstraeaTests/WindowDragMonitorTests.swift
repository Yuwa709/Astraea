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

/// The picker's hit-testing. Each preset's area reaches 7pt past its tile so
/// neighbouring areas meet; inside it the cursor is always on a zone, so the
/// gaps never drop the selection or flash the dimmed presets back.
final class ZoneAnchorHitTests: XCTestCase {

    // Two 100x60 tiles, 14pt apart; the left one split into halves with a 2pt gap.
    private let presets: [(id: String, frame: CGRect)] = [
        ("halves", CGRect(x: 0, y: 0, width: 100, height: 60)),
        ("full", CGRect(x: 114, y: 0, width: 100, height: 60)),
    ]
    private let zones: [(id: String, presetID: String, frame: CGRect)] = [
        ("halves.left", "halves", CGRect(x: 3, y: 3, width: 46, height: 54)),
        ("halves.right", "halves", CGRect(x: 51, y: 3, width: 46, height: 54)),
        ("full.full", "full", CGRect(x: 117, y: 3, width: 94, height: 54)),
    ]

    private func hit(_ x: CGFloat, _ y: CGFloat) -> (presetID: String, zoneID: String)? {
        ZoneAnchors.hit(at: CGPoint(x: x, y: y), presets: presets, zones: zones)
    }

    func testInsideAZoneHitsIt() {
        XCTAssertEqual(hit(20, 30)?.zoneID, "halves.left")
    }

    func testGapBetweenZonesSnapsToTheNearest() {
        // x 49.5 sits in the 2pt gap, nearer the left half.
        XCTAssertEqual(hit(49.5, 30)?.zoneID, "halves.left")
        XCTAssertEqual(hit(50.5, 30)?.zoneID, "halves.right")
    }

    func testTileEdgeInsetStillHitsAZone() {
        XCTAssertEqual(hit(1, 1)?.zoneID, "halves.left")
    }

    func testSpacingBetweenTilesBelongsToANeighbour() {
        // The 14pt between tiles is split 7/7, so every column of it hits.
        for x in stride(from: CGFloat(100), through: 114, by: 1) {
            XCTAssertNotNil(hit(x, 30), "x \(x) fell between presets")
        }
        XCTAssertEqual(hit(106, 30)?.presetID, "halves")
        XCTAssertEqual(hit(108, 30)?.presetID, "full")
    }

    func testFarOutsideHitsNothing() {
        XCTAssertNil(hit(50, 80))
        XCTAssertNil(hit(-10, 30))
    }
}
