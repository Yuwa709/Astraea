import XCTest
import CoreGraphics
@testable import Astraea

/// Where a dropped window lands, from mocked screen numbers.
///
/// Drives the pure core of the window-layout placement engine: the
/// AppKit/Accessibility coordinate flip, which screen a window belongs to,
/// and the rounded zone frame. The Accessibility mover itself needs a live
/// window and is user-verified.
final class WindowLayoutGeometryTests: XCTestCase {

    // MARK: - Fixtures

    /// The notched 14" built-in, primary, at origin zero (AppKit coords).
    private let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// Its visible area: a 33pt menu bar on top and a 70pt Dock at the bottom.
    private let primaryVisible = CGRect(x: 0, y: 70, width: 1512, height: 879)
    /// An external display to the right of the primary, bottoms aligned.
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
    /// Its visible area: a 25pt menu bar, no Dock.
    private let externalVisible = CGRect(x: 1512, y: 0, width: 2560, height: 1415)

    private var primaryHeight: CGFloat { primary.height }

    private func zone(_ id: String) throws -> LayoutZone {
        let all = LayoutPreset.builtIn.flatMap(\.zones)
        return try XCTUnwrap(all.first { $0.id == id }, "no zone \(id)")
    }

    private func target(_ id: String, on visible: CGRect) throws -> CGRect {
        WindowLayoutGeometry.targetAXFrame(
            unitRect: try zone(id).unitRect, visibleFrame: visible, primaryHeight: primaryHeight)
    }

    // MARK: - Coordinate conversion

    func testAXConversionFlipsAgainstPrimaryHeight() {
        let appKit = CGRect(x: 10, y: 70, width: 300, height: 200)
        let ax = WindowLayoutGeometry.axRect(fromAppKit: appKit, primaryHeight: 982)
        XCTAssertEqual(ax, CGRect(x: 10, y: 712, width: 300, height: 200))
    }

    func testAXAppKitRoundTrip() {
        let rects = [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: 1512, y: -433, width: 1280, height: 707),
            CGRect(x: -1920, y: 1200, width: 640.5, height: 480.25),
        ]
        for r in rects {
            let ax = WindowLayoutGeometry.axRect(fromAppKit: r, primaryHeight: 982)
            XCTAssertEqual(WindowLayoutGeometry.appKitRect(fromAX: ax, primaryHeight: 982), r)
            let back = WindowLayoutGeometry.appKitRect(fromAX: r, primaryHeight: 982)
            XCTAssertEqual(WindowLayoutGeometry.axRect(fromAppKit: back, primaryHeight: 982), r)
        }
    }

    func testPrimaryScreenFrameMapsToItselfInAX() {
        XCTAssertEqual(WindowLayoutGeometry.axRect(fromAppKit: primary, primaryHeight: 982), primary)
    }

    // MARK: - Screen selection

    func testScreenIndexSideBySide() {
        let screens = [primary, external]
        let onPrimary = CGRect(x: 100, y: 100, width: 800, height: 600)
        let onExternal = CGRect(x: 2000, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: onPrimary, screenFrames: screens, primaryHeight: primaryHeight), 0)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: onExternal, screenFrames: screens, primaryHeight: primaryHeight), 1)
    }

    func testScreenIndexScreenStackedAbovePrimary() {
        // Above the primary in AppKit means positive y; in AX that is negative y.
        let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        let screens = [primary, above]
        let onAbove = CGRect(x: 100, y: -800, width: 800, height: 600)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: onAbove, screenFrames: screens, primaryHeight: primaryHeight), 1)
        let onPrimary = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: onPrimary, screenFrames: screens, primaryHeight: primaryHeight), 0)
    }

    func testScreenIndexStraddlingPicksLargerOverlap() {
        let screens = [primary, external]
        // 212pt on the primary, 588pt on the external.
        let mostlyExternal = CGRect(x: 1300, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: mostlyExternal, screenFrames: screens, primaryHeight: primaryHeight), 1)
        // 612pt on the primary, 188pt on the external.
        let mostlyPrimary = CGRect(x: 900, y: 100, width: 800, height: 600)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: mostlyPrimary, screenFrames: screens, primaryHeight: primaryHeight), 0)
    }

    func testScreenIndexOffAllScreensPicksNearest() {
        let screens = [primary, external]
        let farRight = CGRect(x: 6000, y: 100, width: 200, height: 200)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: farRight, screenFrames: screens, primaryHeight: primaryHeight), 1)
        let farLeft = CGRect(x: -3000, y: 100, width: 200, height: 200)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: farLeft, screenFrames: screens, primaryHeight: primaryHeight), 0)
    }

    func testScreenIndexZeroSizeWindowUsesContainingScreen() {
        let screens = [primary, external]
        let point = CGRect(x: 2000, y: 300, width: 0, height: 0)
        XCTAssertEqual(WindowLayoutGeometry.screenIndex(
            forWindowAX: point, screenFrames: screens, primaryHeight: primaryHeight), 1)
    }

    func testScreenIndexEmptyListIsNil() {
        XCTAssertNil(WindowLayoutGeometry.screenIndex(
            forWindowAX: CGRect(x: 0, y: 0, width: 100, height: 100), screenFrames: [], primaryHeight: 982))
    }

    // MARK: - Target frames

    func testQuartersOnPrimaryWithMenuBarAndDock() throws {
        // Visible area in AX: y 33...912, height 879, half 439.5.
        XCTAssertEqual(try target("quarters.topLeft", on: primaryVisible),
                       CGRect(x: 0, y: 33, width: 756, height: 439))
        XCTAssertEqual(try target("quarters.topRight", on: primaryVisible),
                       CGRect(x: 756, y: 33, width: 756, height: 439))
        XCTAssertEqual(try target("quarters.bottomLeft", on: primaryVisible),
                       CGRect(x: 0, y: 473, width: 756, height: 439))
        XCTAssertEqual(try target("quarters.bottomRight", on: primaryVisible),
                       CGRect(x: 756, y: 473, width: 756, height: 439))
    }

    func testQuartersOnExternalToTheRight() throws {
        // Visible area in AX: x 1512, y -433...982, height 1415, half 707.5.
        XCTAssertEqual(try target("quarters.topLeft", on: externalVisible),
                       CGRect(x: 1512, y: -433, width: 1280, height: 707))
        XCTAssertEqual(try target("quarters.topRight", on: externalVisible),
                       CGRect(x: 2792, y: -433, width: 1280, height: 707))
        XCTAssertEqual(try target("quarters.bottomLeft", on: externalVisible),
                       CGRect(x: 1512, y: 275, width: 1280, height: 707))
        XCTAssertEqual(try target("quarters.bottomRight", on: externalVisible),
                       CGRect(x: 2792, y: 275, width: 1280, height: 707))
    }

    func testFullFillsVisibleArea() throws {
        XCTAssertEqual(try target("full.full", on: primaryVisible),
                       CGRect(x: 0, y: 33, width: 1512, height: 879))
    }

    // MARK: - Tiling

    func testPresetsTileTheirScreenWithoutOverlapOrGaps() throws {
        let odd = CGRect(x: -1366.5, y: 982, width: 1365, height: 743) // fractional, above-left
        for visible in [primaryVisible, externalVisible, odd] {
            for presetID in ["halves", "quarters", "thirds", "full"] {
                let preset = try XCTUnwrap(LayoutPreset.builtIn.first { $0.id == presetID })
                let frames = preset.zones.map {
                    WindowLayoutGeometry.targetAXFrame(
                        unitRect: $0.unitRect, visibleFrame: visible, primaryHeight: primaryHeight)
                }
                assertTiles(frames, visible: visible, label: "\(presetID) on \(visible)")
            }
        }
    }

    /// No two frames overlap, every frame stays inside the visible area, and
    /// any uncovered strip is at most 1pt wide.
    private func assertTiles(_ frames: [CGRect], visible: CGRect, label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        let area = WindowLayoutGeometry.axRect(fromAppKit: visible, primaryHeight: primaryHeight)
        for (i, a) in frames.enumerated() {
            XCTAssertGreaterThanOrEqual(a.minX, area.minX - 0.5, label, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.minY, area.minY - 0.5, label, file: file, line: line)
            XCTAssertLessThanOrEqual(a.maxX, area.maxX + 0.5, label, file: file, line: line)
            XCTAssertLessThanOrEqual(a.maxY, area.maxY + 0.5, label, file: file, line: line)
            for b in frames[(i + 1)...] {
                let overlap = a.intersection(b)
                let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
                XCTAssertEqual(overlapArea, 0, "\(label): \(a) overlaps \(b)", file: file, line: line)
            }
        }

        // Probe the midpoint of every interval between consecutive edges
        // (plus just inside each edge). A gap wider than 1pt contains such a
        // probe outside every frame grown by 0.5pt per side.
        func probes(_ edges: [CGFloat], lo: CGFloat, hi: CGFloat) -> [CGFloat] {
            let sorted = Array(Set(edges + [lo, hi])).sorted()
            var out: [CGFloat] = []
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                out.append((a + b) / 2)
                out.append(a + 0.25)
                out.append(b - 0.25)
            }
            // A 1pt strip at the screen edge has no neighbour to grow into it.
            return out.filter { $0 > lo + 0.5 && $0 < hi - 0.5 }
        }
        let xs = probes(frames.flatMap { [$0.minX, $0.maxX] }, lo: area.minX, hi: area.maxX)
        let ys = probes(frames.flatMap { [$0.minY, $0.maxY] }, lo: area.minY, hi: area.maxY)
        let grown = frames.map { $0.insetBy(dx: -0.5, dy: -0.5) }
        for x in xs {
            for y in ys {
                let covered = grown.contains { $0.minX <= x && x <= $0.maxX && $0.minY <= y && y <= $0.maxY }
                XCTAssertTrue(covered, "\(label): gap over 1pt at (\(x), \(y))", file: file, line: line)
            }
        }
    }

    // MARK: - Presets

    func testBuiltInOrderAndZoneCounts() {
        XCTAssertEqual(LayoutPreset.builtIn.map(\.id), ["halves", "quarters", "thirds", "full"])
        XCTAssertEqual(LayoutPreset.builtIn.map(\.zones.count), [2, 4, 3, 1])
    }

    func testBuiltInZoneIDsAreUnique() {
        let ids = LayoutPreset.builtIn.flatMap(\.zones).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        let presetIDs = LayoutPreset.builtIn.map(\.id)
        XCTAssertEqual(Set(presetIDs).count, presetIDs.count)
    }
}
