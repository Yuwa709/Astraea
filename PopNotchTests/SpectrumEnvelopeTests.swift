import XCTest
@testable import PopNotch

/// The scrub bar wave's geometry, fade and progress stops.
///
/// How the bar looks is user-verified. What is tested is what the geometry
/// can get wrong — the curve overshooting out of the row or below the silent
/// height, the taper not settling at the tips, an end cut off square, the base
/// leaving the bottom edge, fade bands with gaps or the wrong order — and
/// where the progress colours change. A cubic Bézier lies within its control
/// points, so checking those checks the curve.
@MainActor
final class SpectrumEnvelopeTests: XCTestCase {

    /// A track-sized row: the real width varies with the panel, the height
    /// does not.
    private let row = CGRect(x: 0, y: 0, width: 282, height: SpectrumEnvelope.maxHeight)

    private var cap: CGFloat { SpectrumEnvelope.capRadius(in: row) }

    // MARK: - Top edge

    private func edgePoints(_ magnitudes: [Float]) -> [CGPoint] {
        let edge = SpectrumEnvelope.upperEdge(magnitudes: magnitudes, in: row)
        var points = [edge.start]
        for segment in edge.segments {
            points.append(segment.control1)
            points.append(segment.control2)
            points.append(segment.end)
        }
        return points
    }

    private func assertEdgeInsideRow(_ magnitudes: [Float]) {
        let silentTop = row.maxY - SpectrumEnvelope.minHeight
        for point in edgePoints(magnitudes) {
            XCTAssertGreaterThanOrEqual(point.y, row.minY - 1e-6,
                                        "escapes the top of the row for \(magnitudes)")
            XCTAssertLessThanOrEqual(point.y, silentTop + 1e-6,
                                     "dips below the silent height for \(magnitudes)")
            XCTAssertGreaterThanOrEqual(point.x, row.minX + cap - 1e-6, "left of the left tip")
            XCTAssertLessThanOrEqual(point.x, row.maxX - cap + 1e-6, "right of the right tip")
        }
    }

    private func extremePatterns() -> [[Float]] {
        var alternatingLow: [Float] = []
        var alternatingHigh: [Float] = []
        var ramp: [Float] = []
        for band in 0..<16 {
            alternatingLow.append(band % 2 == 0 ? 0 : 1)
            alternatingHigh.append(band % 2 == 0 ? 1 : 0)
            ramp.append(Float(band) / 15)
        }
        let mixed: [Float] = [1, 0, 0, 1, 0.5, 0.9, 0.1, 1, 1, 0, 0.3, 0.7, 0, 1, 0.2, 1]
        return [
            alternatingLow, alternatingHigh, ramp, mixed,
            [Float](repeating: 1, count: 16),
            [Float](repeating: 0, count: 16),
        ]
    }

    /// Alternating silence and full level is where an overshooting curve
    /// fails worst; full level right beside a tip is where the taper does.
    func testExtremePatternsStayInsideTheRow() {
        for pattern in extremePatterns() {
            assertEdgeInsideRow(pattern)
        }
    }

    /// Deterministic pseudo-random spectra, so a failure is reproducible.
    func testArbitrarySpectraStayInsideTheRow() {
        var generator = SeededGenerator(state: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<500 {
            assertEdgeInsideRow(generator.spectrum())
        }
    }

    /// Out-of-range input must not break the bounds either.
    func testOutOfRangeMagnitudesAreClamped() {
        assertEdgeInsideRow([-2, 5, 1.5, -0.5, 0, 1, 3, -1, 0.5, 9, -9, 0, 1, 2, -3, 0.2])
    }

    /// Same 16 band values, each at its height, between the two tips.
    func testPassesThroughEveryBandBetweenTheTips() {
        let magnitudes: [Float] = [0, 0.25, 1, 0.5, 0.75, 0.1, 0.9, 0.3,
                                   0.6, 0.05, 0.95, 0.4, 0.2, 0.8, 0.15, 0.7]
        let edge = SpectrumEnvelope.upperEdge(magnitudes: magnitudes, in: row)
        let bandXs = SpectrumEnvelope.bandXs(in: row)
        XCTAssertEqual(edge.segments.count, AudioVisualizerService.bandCount + 1)
        for band in 0..<AudioVisualizerService.bandCount {
            let point = edge.segments[band].end
            let height = SpectrumEnvelope.minHeight
                + (row.height - SpectrumEnvelope.minHeight) * CGFloat(magnitudes[band])
            XCTAssertEqual(point.x, bandXs[band], accuracy: 1e-6, "band \(band) x")
            XCTAssertEqual(point.y, row.maxY - height, accuracy: 1e-6, "band \(band) height")
        }
    }

    /// Whatever the level, the wave tapers to the silent height at each tip,
    /// and the first and last bands sit a taper's width inside them.
    func testTaperSettlesAtTheTipsAtAnyLevel() {
        let edge = SpectrumEnvelope.upperEdge(magnitudes: [Float](repeating: 1, count: 16), in: row)
        let silentTop = row.maxY - SpectrumEnvelope.minHeight
        guard let last = edge.segments.last else { return XCTFail("no segments") }
        XCTAssertEqual(edge.start.y, silentTop, accuracy: 1e-6)
        XCTAssertEqual(last.end.y, silentTop, accuracy: 1e-6)
        XCTAssertEqual(edge.start.x, row.minX + cap, accuracy: 1e-6)
        XCTAssertEqual(last.end.x, row.maxX - cap, accuracy: 1e-6)

        let bandXs = SpectrumEnvelope.bandXs(in: row)
        XCTAssertEqual(bandXs[0] - edge.start.x, SpectrumEnvelope.taperWidth, accuracy: 1e-6)
        XCTAssertEqual(last.end.x - bandXs[bandXs.count - 1], SpectrumEnvelope.taperWidth, accuracy: 1e-6)
        // The curve leaves each tip flat: its first control point is level.
        XCTAssertEqual(edge.segments[0].control1.y, silentTop, accuracy: 1e-6)
        XCTAssertEqual(last.control2.y, silentTop, accuracy: 1e-6)
    }

    /// Silence is a flat bar at the silent height, not nothing.
    func testSilenceIsAFlatMinimumBar() {
        for point in edgePoints([]) {
            XCTAssertEqual(point.y, row.maxY - SpectrumEnvelope.minHeight, accuracy: 1e-6)
        }
    }

    // MARK: - Outline

    private func allPoints(_ elements: [SpectrumEnvelope.Element]) -> [CGPoint] {
        var points: [CGPoint] = []
        for element in elements {
            switch element {
            case .move(let point):
                points.append(point)
            case .line(let point):
                points.append(point)
            case .curve(let point, let control1, let control2):
                points.append(control1)
                points.append(control2)
                points.append(point)
            }
        }
        return points
    }

    /// Upward only, on a flat base along the bottom edge, with round caps
    /// reaching the row's ends — and no straight vertical cut anywhere.
    func testOutlineHasRoundCapsAFlatBaseAndNoVerticalCut() {
        var generator = SeededGenerator(state: 0xD1B5_4A32_D192_ED03)
        var spectra = extremePatterns()
        for _ in 0..<60 {
            spectra.append(generator.spectrum())
        }
        for magnitudes in spectra {
            let edge = SpectrumEnvelope.upperEdge(magnitudes: magnitudes, in: row)
            let elements = SpectrumEnvelope.outline(edge: edge, in: row)
            var lowest = -CGFloat.infinity
            var leftmost = CGFloat.infinity
            var rightmost = -CGFloat.infinity
            for point in allPoints(elements) {
                XCTAssertGreaterThanOrEqual(point.y, row.minY - 1e-6, "above the row")
                XCTAssertLessThanOrEqual(point.y, row.maxY + 1e-6, "below the base")
                lowest = max(lowest, point.y)
                leftmost = min(leftmost, point.x)
                rightmost = max(rightmost, point.x)
            }
            XCTAssertEqual(lowest, row.maxY, accuracy: 1e-6, "the base is the row's bottom edge")
            XCTAssertEqual(leftmost, row.minX, accuracy: 1e-6, "the left cap reaches the end")
            XCTAssertEqual(rightmost, row.maxX, accuracy: 1e-6, "the right cap reaches the end")

            var flatBase = false
            var previous = CGPoint.zero
            for element in elements {
                switch element {
                case .move(let point):
                    previous = point
                case .line(let point):
                    XCTAssertFalse(abs(point.x - previous.x) < 1e-9 && abs(point.y - previous.y) > 1e-9,
                                   "a straight vertical cut at x \(point.x)")
                    if abs(point.y - row.maxY) < 1e-6, abs(point.x - (row.minX + cap)) < 1e-6 {
                        flatBase = true
                    }
                    previous = point
                case .curve(let point, _, _):
                    previous = point
                }
            }
            XCTAssertTrue(flatBase, "a straight line along the base")
        }
    }

    func testNothingIsDrawnInAnEmptyRow() {
        let edge = SpectrumEnvelope.upperEdge(magnitudes: [1, 1], in: .zero)
        XCTAssertTrue(SpectrumEnvelope.outline(edge: edge, in: .zero).isEmpty)
    }

    // MARK: - Fade

    /// Contiguous from the crest to the base, darker with every step: full at
    /// the crest, the baseline brightness at the base.
    func testFadeRunsFromFullAtTheCrestToBaselineAtTheBase() {
        let bands = SpectrumEnvelope.fadeBands()
        guard let first = bands.first, let last = bands.last else { return XCTFail("no bands") }
        XCTAssertLessThanOrEqual(first.from, 0, "starts at or above the crest")
        XCTAssertGreaterThanOrEqual(last.to, 1, "reaches the base")
        XCTAssertEqual(first.brightness, 1, accuracy: 1e-9, "brightest along the crest")
        XCTAssertEqual(last.brightness, SpectrumEnvelope.baselineBrightness, accuracy: 1e-9,
                       "dimmest at the base")
        for index in 1..<bands.count {
            XCTAssertEqual(bands[index].from, bands[index - 1].to, accuracy: 1e-9,
                           "a gap at band \(index)")
            XCTAssertLessThan(bands[index].brightness, bands[index - 1].brightness,
                              "band \(index) is not darker than the one above it")
        }
    }

    /// A band sits the same fraction of the way down every column, short or
    /// tall, so the base of every part of the wave is dimmer than its crest —
    /// not only of the parts taller than some fixed depth.
    func testRibbonScalesTheCrestTowardTheBase() {
        let edge = SpectrumEnvelope.upperEdge(magnitudes: [0.3, 0.9, 0.1, 1, 0.5, 0.7, 0, 0.6,
                                                           0.8, 0.2, 1, 0.4, 0.9, 0.05, 0.65, 0.35],
                                              in: row)
        let elements = SpectrumEnvelope.ribbon(edge: edge, in: row, from: 0.25, to: 0.5)
        for point in allPoints(elements) {
            XCTAssertGreaterThanOrEqual(point.x, row.minX - 1e-6)
            XCTAssertLessThanOrEqual(point.x, row.maxX + 1e-6)
            XCTAssertGreaterThanOrEqual(point.y, row.minY - 1e-6, "above the row")
            XCTAssertLessThanOrEqual(point.y, row.maxY + 1e-6, "below the base")
        }
        guard elements.count > 2, case .line(let tip) = elements[1] else { return XCTFail("no tip") }
        XCTAssertEqual(tip.y, row.maxY - (row.maxY - edge.start.y) * 0.75, accuracy: 1e-6)
        guard case .curve(let firstEnd, _, _) = elements[2] else { return XCTFail("no curve") }
        XCTAssertEqual(firstEnd.y, row.maxY - (row.maxY - edge.segments[0].end.y) * 0.75,
                       accuracy: 1e-6)
    }

    // MARK: - Progress stops

    private let mixed: [Float] = [0.2, 0.9, 0.4, 1, 0.1, 0.7, 0.3, 0.8,
                                  0.5, 0.6, 0, 1, 0.45, 0.25, 0.85, 0.15]

    /// Stops rise in location; every stop before the playhead is played and
    /// every stop after it unplayed; and exactly one played-then-unplayed pair
    /// sits at the playhead — including inside the taper at either end.
    func testStopsSplitAtThePlayheadWithAHardEdge() {
        let playheads: [CGFloat] = [0, 0.01, 0.03, 0.1, 1.0 / 3, 0.5, 0.52, 0.8, 0.97, 0.995, 1]
        for head in playheads {
            let stops = SpectrumEnvelope.progressStops(magnitudes: mixed, playhead: head, in: row)
            var edgePairs = 0
            for index in 0..<stops.count {
                let stop = stops[index]
                if index > 0 {
                    XCTAssertGreaterThanOrEqual(stop.location, stops[index - 1].location - 1e-9,
                                                "locations out of order at \(head)")
                }
                if stop.location < head - 1e-9 {
                    XCTAssertTrue(stop.played, "unplayed stop before the playhead at \(head)")
                } else if stop.location > head + 1e-9 {
                    XCTAssertFalse(stop.played, "played stop after the playhead at \(head)")
                }
                if index > 0, stops[index - 1].played, !stop.played,
                   abs(stops[index - 1].location - head) < 1e-9, abs(stop.location - head) < 1e-9 {
                    edgePairs += 1
                    XCTAssertEqual(stops[index - 1].magnitude, stop.magnitude, accuracy: 1e-9,
                                   "the edge is a colour change, not a brightness jump")
                }
            }
            XCTAssertEqual(edgePairs, 1, "one hard edge at \(head)")
        }
    }

    /// The edge's brightness is interpolated between the bands either side.
    func testEdgeMagnitudeInterpolatesTheNeighbouringBands() {
        let bandXs = SpectrumEnvelope.bandXs(in: row)
        let head = ((bandXs[7] + bandXs[8]) / 2 - row.minX) / row.width
        let stops = SpectrumEnvelope.progressStops(magnitudes: mixed, playhead: head, in: row)
        var edge: SpectrumEnvelope.ProgressStop?
        for stop in stops where abs(stop.location - head) < 1e-9 {
            edge = stop
        }
        guard let edge else { return XCTFail("no stop at the playhead") }
        XCTAssertEqual(edge.magnitude, CGFloat(mixed[7] + mixed[8]) / 2, accuracy: 1e-6)
    }

    /// At the very start nothing is played; at the very end, everything is.
    func testStartIsAllUnplayedAndEndIsAllPlayed() {
        for stop in SpectrumEnvelope.progressStops(magnitudes: mixed, playhead: 0, in: row)
        where stop.location > 0 {
            XCTAssertFalse(stop.played)
        }
        for stop in SpectrumEnvelope.progressStops(magnitudes: mixed, playhead: 1, in: row)
        where stop.location < 1 {
            XCTAssertTrue(stop.played)
        }
    }

    // MARK: - The visible bar

    /// With the visualiser off there is never a wave, so the flat bar carries
    /// the row alone and is drawn thicker. With it on the silent height is
    /// unchanged, or the wave's whole lower range would move with it.
    func testTheFlatBarIsThickerOnlyWithTheVisualiserOff() {
        XCTAssertEqual(SpectrumEnvelope.restHeight(visualizerOn: true),
                       SpectrumEnvelope.minHeight)
        XCTAssertGreaterThan(SpectrumEnvelope.restHeight(visualizerOn: false),
                             SpectrumEnvelope.restHeight(visualizerOn: true))
        XCTAssertLessThan(SpectrumEnvelope.restHeight(visualizerOn: false), row.height,
                          "the resting bar must still sit inside the row")

        // Silence, drawn at the off-state height: every point of the outline
        // sits between the base and that height, tips and caps included.
        let rest = SpectrumEnvelope.restHeight(visualizerOn: false)
        let edge = SpectrumEnvelope.upperEdge(magnitudes: [Float](repeating: 0, count: 16),
                                              in: row, rest: rest)
        for point in allPoints(SpectrumEnvelope.outline(edge: edge, in: row, rest: rest)) {
            XCTAssertLessThanOrEqual(point.y, row.maxY + 1e-6)
            XCTAssertGreaterThanOrEqual(point.y, row.maxY - rest - 1e-6,
                                        "the resting bar must not exceed its own height")
        }
    }
}

/// A linear congruential generator: enough spread for bounds testing, and
/// the same sequence on every run.
private struct SeededGenerator {
    var state: UInt64

    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }

    mutating func spectrum() -> [Float] {
        var magnitudes: [Float] = []
        for _ in 0..<16 {
            magnitudes.append(nextUnit())
        }
        return magnitudes
    }
}

/// Where a click on the scrub bar lands. Linear across the whole row, edge to
/// edge: the wave's taper is drawing only and sets nothing aside.
final class ScrubGeometryTests: XCTestCase {

    func testEdgesMapToTheStartAndEndOfTheTrack() {
        for width: CGFloat in [120, 282, 400] {
            XCTAssertEqual(ScrubGeometry.fraction(atX: 0, width: width), 0, accuracy: 1e-9)
            XCTAssertEqual(ScrubGeometry.fraction(atX: width, width: width), 1, accuracy: 1e-9)
            XCTAssertEqual(ScrubGeometry.fraction(atX: width / 2, width: width), 0.5, accuracy: 1e-9)
        }
    }

    /// Inside the taper, a point of travel is still a point of travel.
    func testTheTaperedEndsAreNotSetAside() {
        let width: CGFloat = 282
        let taper = SpectrumEnvelope.taperWidth
        XCTAssertEqual(ScrubGeometry.fraction(atX: 1, width: width), Double(1 / width), accuracy: 1e-9)
        XCTAssertEqual(ScrubGeometry.fraction(atX: taper / 2, width: width),
                       Double(taper / 2 / width), accuracy: 1e-9)
        XCTAssertEqual(ScrubGeometry.fraction(atX: width - 1, width: width),
                       Double((width - 1) / width), accuracy: 1e-9)
    }

    func testOutsideTheRowClampsAndAZeroWidthIsSafe() {
        XCTAssertEqual(ScrubGeometry.fraction(atX: -20, width: 282), 0)
        XCTAssertEqual(ScrubGeometry.fraction(atX: 400, width: 282), 1)
        XCTAssertEqual(ScrubGeometry.fraction(atX: 10, width: 0), 0)
    }


    // MARK: - The grab zone

    /// Taller than the row at both edges, so hitting the bar never depends on
    /// hitting what is drawn.
    func testTheGrabZoneReachesPastTheRow() {
        let row = SpectrumEnvelope.maxHeight
        let height = ScrubGeometry.hitHeight(rowHeight: row)
        XCTAssertGreaterThan(height, row)
        XCTAssertEqual(height - row, 2 * ScrubGeometry.hitOverhang, accuracy: 1e-9,
                       "the overhang is symmetric, so an overlay centres on the row")
        XCTAssertGreaterThan(ScrubGeometry.hitOverhang,
                             SpectrumEnvelope.restHeight(visualizerOn: false),
                             "a miss by more than the bar's own height must still land")
    }
}
