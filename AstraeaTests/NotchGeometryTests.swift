import XCTest
import AppKit
@testable import Astraea

/// Where the notch rect lands, from the screen's own numbers.
///
/// `NotchPanel.notchRect(on:)` takes a real `NSScreen`; these drive its pure
/// core with mocked frames, safe-area insets and auxiliary areas, so the
/// geometry CLAUDE.md requires tests for is a test: the notched built-in at
/// origin 0 (regression against the measured values in PROJECT-CONTEXT.md),
/// the same display at a non-zero origin (an external monitor primary), an
/// asymmetric auxiliary gap, and the notchless fallback.
final class NotchGeometryTests: XCTestCase {

    // MARK: - Fixtures

    /// One display configuration, in the global coordinates `NSScreen.frame`
    /// reports.
    private struct Display {
        var frame: NSRect
        var topInset: CGFloat
        /// Where the housing's gap starts and ends, measured from the
        /// screen's own left edge.
        var gapStart: CGFloat
        var gapEnd: CGFloat

        /// The auxiliary areas as AppKit would hand them over, either in
        /// screen-local coordinates or offset to the screen's origin. The
        /// function must not care which.
        func areas(global: Bool) -> (left: NSRect, right: NSRect) {
            let x0 = global ? frame.minX : 0
            let y = (global ? frame.minY : 0) + frame.height - topInset
            return (NSRect(x: x0, y: y, width: gapStart, height: topInset),
                    NSRect(x: x0 + gapEnd, y: y, width: frame.width - gapEnd, height: topInset))
        }

        func moved(toX x: CGFloat, y: CGFloat) -> Display {
            var copy = self
            copy.frame.origin = NSPoint(x: x, y: y)
            return copy
        }
    }

    /// The two scales this display has reported (PROJECT-CONTEXT.md, §2).
    private let defaultScale = Display(frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
                                       topInset: 32, gapStart: 646, gapEnd: 825)
    private let moreSpace = Display(frame: NSRect(x: 0, y: 0, width: 1710, height: 1112),
                                    topInset: 38, gapStart: 751, gapEnd: 960)

    private func notch(_ d: Display, global: Bool = false) -> NSRect {
        let areas = d.areas(global: global)
        return NotchPanel.notchRect(frame: d.frame, topInset: d.topInset,
                                    leftArea: areas.left, rightArea: areas.right,
                                    fallbackHeight: 24)
    }

    /// The formula this replaced, verbatim: correct only when the auxiliary
    /// areas share `frame`'s coordinate space.
    private func legacyNotch(frame: NSRect, topInset: CGFloat,
                             leftArea: NSRect, rightArea: NSRect) -> NSRect {
        let center = frame.midX
        let halfWidth = min(center - leftArea.maxX, rightArea.minX - center) - 1.0
        return NSRect(x: center - halfWidth, y: frame.maxY - topInset,
                      width: halfWidth * 2, height: topInset)
    }

    // MARK: - Origin 0: regression against the measured rects

    func testBuiltInAtOriginMatchesTheMeasuredRects() {
        XCTAssertEqual(notch(defaultScale), NSRect(x: 647, y: 924, width: 176, height: 32))
        XCTAssertEqual(notch(moreSpace), NSRect(x: 752, y: 1074, width: 206, height: 38))
    }

    func testBuiltInAtOriginMatchesTheOldFormula() {
        // Includes the fractional inset macOS 27 reports at "more space"
        // (37.5, gap 751…959), measured 2026-10-13.
        let live = Display(frame: NSRect(x: 0, y: 0, width: 1710, height: 1112),
                           topInset: 37.5, gapStart: 751, gapEnd: 959)
        for d in [defaultScale, moreSpace, live] {
            let areas = d.areas(global: false)
            XCTAssertEqual(notch(d),
                           legacyNotch(frame: d.frame, topInset: d.topInset,
                                       leftArea: areas.left, rightArea: areas.right),
                           "\(d.frame)")
        }
    }

    // MARK: - Non-zero origin: an external monitor is primary

    func testBuiltInAtANonZeroOriginIsTheSameRectTranslated() {
        // Right of a 2560-wide primary and dropped below its top; below it;
        // and left of it (negative x).
        let origins: [NSPoint] = [NSPoint(x: 2560, y: -484),
                                  NSPoint(x: 545, y: -956),
                                  NSPoint(x: -1470, y: 240)]
        for d in [defaultScale, moreSpace] {
            let atZero = notch(d)
            for origin in origins {
                let moved = d.moved(toX: origin.x, y: origin.y)
                let expected = atZero.offsetBy(dx: origin.x, dy: origin.y)
                XCTAssertEqual(notch(moved, global: false), expected,
                               "screen-local auxiliary areas at \(origin)")
                XCTAssertEqual(notch(moved, global: true), expected,
                               "global auxiliary areas at \(origin)")
            }
        }
    }

    func testNonZeroOriginKeepsTheTopFlushAndTheRectOnItsScreen() {
        let moved = defaultScale.moved(toX: 2560, y: -484)
        let rect = notch(moved, global: true)
        XCTAssertEqual(rect.maxY, moved.frame.maxY)
        XCTAssertTrue(moved.frame.contains(rect), "\(rect) must sit on \(moved.frame)")
        XCTAssertEqual(rect.midX, moved.frame.midX)
    }

    // MARK: - Asymmetric auxiliary areas

    func testAsymmetricGapSymmetrizesOnTheTighterSide() {
        // Right side tighter: the gap reaches 95pt left of centre but only
        // 90pt right of it. The rect takes 90 - 1 on both sides.
        let d = Display(frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
                        topInset: 32, gapStart: 640, gapEnd: 825)
        let rect = notch(d)
        XCTAssertEqual(rect, NSRect(x: 646, y: 924, width: 178, height: 32))
        XCTAssertEqual(rect.midX, d.frame.midX)

        // Left side tighter (the 15" Air's 1pt-wider right), translated:
        // the same answer as at origin 0.
        let air = Display(frame: NSRect(x: 0, y: 0, width: 1470, height: 956),
                          topInset: 32, gapStart: 646, gapEnd: 826)
        XCTAssertEqual(notch(air), NSRect(x: 647, y: 924, width: 176, height: 32))
        XCTAssertEqual(notch(air.moved(toX: 1920, y: 100), global: true),
                       NSRect(x: 1920 + 647, y: 100 + 924, width: 176, height: 32))
    }

    // MARK: - Notchless fallback

    func testNoNotchFallsBackToAMenuBarHighStrip() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let rect = NotchPanel.notchRect(frame: frame, topInset: 0,
                                        leftArea: nil, rightArea: nil,
                                        fallbackHeight: 24)
        XCTAssertEqual(rect, NSRect(x: 860, y: 1056, width: 200, height: 24))
    }

    func testMissingAuxiliaryAreaTakesTheFallbackToo() {
        let d = defaultScale
        let areas = d.areas(global: false)
        for (left, right) in [(nil, areas.right), (areas.left, nil)] as [(NSRect?, NSRect?)] {
            let rect = NotchPanel.notchRect(frame: d.frame, topInset: d.topInset,
                                            leftArea: left, rightArea: right,
                                            fallbackHeight: 24)
            XCTAssertEqual(rect.width, NotchPanel.fallbackWidth)
            XCTAssertEqual(rect.height, 24)
        }
    }

    func testFallbackOnAnExternalDisplayAtANonZeroOrigin() {
        let frame = NSRect(x: 1470, y: -200, width: 2560, height: 1440)
        let rect = NotchPanel.notchRect(frame: frame, topInset: 0,
                                        leftArea: nil, rightArea: nil,
                                        fallbackHeight: 24)
        XCTAssertEqual(rect, NSRect(x: 1470 + 1280 - 100, y: -200 + 1440 - 24,
                                    width: 200, height: 24))
    }

    func testFallbackHeightIsTheScreensOwnMenuBar() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // Visible frame stops under a 24pt menu bar (a Dock at the bottom
        // moves its minY, never its maxY).
        XCTAssertEqual(NotchPanel.fallbackHeight(
            frame: frame, visibleFrame: NSRect(x: 0, y: 70, width: 1920, height: 986),
            statusBarThickness: 22), 24)
        // A taller bar is followed, not clamped to 24.
        XCTAssertEqual(NotchPanel.fallbackHeight(
            frame: frame, visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1050),
            statusBarThickness: 22), 30)
        // At a non-zero origin the difference is still of the tops.
        let moved = frame.offsetBy(dx: 1470, dy: -300)
        XCTAssertEqual(NotchPanel.fallbackHeight(
            frame: moved, visibleFrame: NSRect(x: 1470, y: -300, width: 1920, height: 1056),
            statusBarThickness: 22), 24)
    }

    func testFallbackHeightWithAnAutoHidingMenuBarUsesTheStatusBar() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        // Auto-hide (or no menu bar on this screen): no gap at the top.
        XCTAssertEqual(NotchPanel.fallbackHeight(frame: frame, visibleFrame: frame,
                                                 statusBarThickness: 26), 26)
        // The status bar reports the legacy 22 (measured); floored so the
        // 24pt chrome buttons still fit the chrome-only bar.
        XCTAssertEqual(NotchPanel.fallbackHeight(frame: frame, visibleFrame: frame,
                                                 statusBarThickness: 22),
                       NotchPanel.minimumFallbackHeight)
    }

    // MARK: - Compact and expanded, derived from the notch

    func testCompactRectMatchesTheMeasuredRect() {
        // PROJECT-CONTEXT.md: visible {{597, 924}, {272, 32}}.
        XCTAssertEqual(NotchPanel.compactRect(housing: notch(defaultScale)),
                       NSRect(x: 597, y: 924, width: 272, height: 32))
    }

    func testCompactAndExpandedTranslateWithTheScreen() {
        let atZero = notch(defaultScale)
        let moved = defaultScale.moved(toX: 2560, y: -484)
        let housing = notch(moved, global: true)
        XCTAssertEqual(NotchPanel.compactRect(housing: housing),
                       NotchPanel.compactRect(housing: atZero).offsetBy(dx: 2560, dy: -484))
        let size = CGSize(width: 520, height: 240)
        XCTAssertEqual(NotchPanel.expandedRect(housing: housing, contentSize: size),
                       NotchPanel.expandedRect(housing: atZero, contentSize: size)
                           .offsetBy(dx: 2560, dy: -484))
        // Top stays flush with the moved screen's top.
        XCTAssertEqual(NotchPanel.expandedRect(housing: housing, contentSize: size).maxY,
                       moved.frame.maxY)
    }

    func testCompactAndExpandedOnTheFallbackStripStayOnTheMenuBar() {
        let frame = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let strip = NotchPanel.notchRect(frame: frame, topInset: 0,
                                         leftArea: nil, rightArea: nil,
                                         fallbackHeight: 24)
        let compact = NotchPanel.compactRect(housing: strip)
        XCTAssertEqual(compact.minY, frame.maxY - 24, "no overhang below a 24pt menu bar")
        XCTAssertEqual(compact.maxY, frame.maxY)
        let chromeOnly = NotchPanel.expandedRect(housing: strip, contentSize: .zero,
                                                 chromeOnly: true)
        XCTAssertEqual(chromeOnly.height, 24)
    }
}
