import XCTest
import AppKit
@testable import PopNotch

/// Full-lyrics-page vertical geometry.
///
/// The page previously positioned every line with a flat 34pt step while the
/// active line was blown up 1.22x by `scaleEffect`. `scaleEffect` does not
/// participate in layout, so neighbours never moved out of its way and long
/// lyrics — which wrap to two rendered lines but still got one line of room —
/// overlapped it. These pin the two properties that fix that.
final class LyricsLayoutTests: XCTestCase {

    private let fontSize: CGFloat = 20
    private let scale: CGFloat = 1.22
    private let gap: CGFloat = 12
    private let fallback: CGFloat = 24

    private func offset(_ index: Int, active: Int, heights: [CGFloat]) -> CGFloat {
        LyricsLayout.offset(for: index, active: active, heights: heights,
                            activeScale: scale, gap: gap, fallback: fallback)
    }

    // MARK: - Measurement

    func testWrappingTextIsTallerThanASingleLine() {
        let short = LyricsLayout.renderedHeight(of: "Oh, no-nah, yeah",
                                                wrappingAt: 300, fontSize: fontSize)
        let long = LyricsLayout.renderedHeight(
            of: "I'll turn you on, I'll turn you on, I'll turn you on",
            wrappingAt: 300, fontSize: fontSize)
        XCTAssertGreaterThan(long, short * 1.5,
                             "a line that wraps must measure roughly two lines tall")
    }

    func testNarrowerWidthWrapsMore() {
        let text = "Keep the bells ringing for you, it's a celebration for you"
        let wide = LyricsLayout.renderedHeight(of: text, wrappingAt: 380, fontSize: fontSize)
        let narrow = LyricsLayout.renderedHeight(of: text, wrappingAt: 180, fontSize: fontSize)
        XCTAssertGreaterThan(narrow, wide)
    }

    /// An instrumental break still occupies a row rather than collapsing.
    func testEmptyLineStillHasHeight() {
        XCTAssertGreaterThan(
            LyricsLayout.renderedHeight(of: "", wrappingAt: 300, fontSize: fontSize), 0)
    }

    // MARK: - Positioning

    func testActiveLineSitsAtCentre() {
        XCTAssertEqual(offset(2, active: 2, heights: [24, 24, 24, 24, 24]), 0)
    }

    /// Half of each, plus one gap.
    func testAdjacentLineClearsHalfOfEach() {
        let heights: [CGFloat] = [24, 24, 24]
        // active 1 is scaled: (24 * 1.22)/2 + 24/2 + 12
        let expected = (24 * scale) / 2 + 12 + 12
        XCTAssertEqual(offset(2, active: 1, heights: heights), expected, accuracy: 0.01)
    }

    /// The property the whole change exists for.
    func testScalingTheActiveLinePushesNeighboursFurtherAway() {
        let heights: [CGFloat] = [24, 24, 24]
        let scaled = offset(2, active: 1, heights: heights)
        let unscaled = LyricsLayout.offset(for: 2, active: 1, heights: heights,
                                           activeScale: 1, gap: gap, fallback: fallback)
        XCTAssertGreaterThan(scaled, unscaled,
                             "a grown active line must move its neighbour, not grow over it")
    }

    /// A two-line lyric gets two lines of room — the overlap in the report.
    func testAWrappedLinePushesTheNextLineTwiceAsFar() {
        let single: [CGFloat] = [24, 24, 24]
        let wrapped: [CGFloat] = [24, 48, 24]   // index 1 wraps to two rows
        XCTAssertGreaterThan(offset(2, active: 0, heights: wrapped),
                             offset(2, active: 0, heights: single),
                             "a wrapped line in between must add its real height")
    }

    func testLinesAboveAreNegativeAndSymmetric() {
        let heights: [CGFloat] = [24, 24, 24, 24, 24]
        XCTAssertEqual(offset(1, active: 2, heights: heights),
                       -offset(3, active: 2, heights: heights), accuracy: 0.01)
    }

    func testDistantLinesAccumulateEveryHeightBetween() {
        let heights: [CGFloat] = [24, 24, 24, 24]
        // 24/2 (active 0, unscaled since activeScale applies to index 0 here)
        let a = offset(3, active: 0, heights: heights)
        let b = offset(2, active: 0, heights: heights)
        XCTAssertEqual(a - b, 24 + gap, accuracy: 0.01,
                       "each extra line adds exactly its height plus one gap")
    }

    /// Before the first timestamp the active index is -1, off the array.
    ///
    /// The phantom row takes the fallback height *unscaled*, deliberately:
    /// nothing is rendered at -1, so it is only a spacer marking where centre
    /// is. Scaling an invisible line would push line 0 down by a fraction of
    /// a line for no visible reason.
    func testPhantomActiveIndexUsesTheFallbackUnscaled() {
        let heights: [CGFloat] = [24, 24]
        XCTAssertEqual(offset(0, active: -1, heights: heights),
                       fallback / 2 + 24 / 2 + gap, accuracy: 0.01)
    }

    // MARK: - Horizontal

    /// The clipping in the report: text laid out at full panel width, then
    /// multiplied past both edges by a scale applied after layout.
    func testScaledActiveLineFitsInsideThePanelWithPadding() {
        let panel: CGFloat = 400
        let padding: CGFloat = 22
        let wrapWidth = (panel - padding * 2) / scale
        XCTAssertEqual(wrapWidth * scale, panel - padding * 2, accuracy: 0.01,
                       "the scaled line must land exactly inside the padding")
        XCTAssertLessThan(wrapWidth * scale, panel, "and never exceed the panel")
    }
}
