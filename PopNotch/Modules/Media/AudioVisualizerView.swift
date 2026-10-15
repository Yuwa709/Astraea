import SwiftUI
import AppKit

/// The scrub bar, drawn as the 16-band spectrum.
///
/// The band magnitudes become 16 points along the track, joined by a smooth
/// curve and filled straight down to a flat base on the row's bottom edge — an
/// upward-only envelope. Toward each end it tapers down to the silent bar's
/// height and finishes in a round cap, like the old capsule's ends. Progress
/// is carried by colour: the accent left of the playhead, grey right of it,
/// with a hard edge between. Within each, brightness follows the spectrum
/// horizontally, and vertically fades from each column's crest down to the
/// base, which is what gives the wave body rather than a flat fill. The played
/// side also carries a soft bloom in the same accent; the grey carries none.
///
/// Always drawn, whatever the visualiser is doing, because it is the scrub
/// bar. Switched off, refused permission, paused, or between tracks, the
/// service's `bands` are all zero and the wave lies flat at its minimum
/// height: a plain progress bar. On a pause they get there over a short
/// settle rather than in one frame; see
/// `AudioVisualizerService.pauseSettleDuration`. Capture itself is still gated by the
/// service (enabled, playing, player screen visible); only the drawing is
/// unconditional.
///
/// Still 16 bands: `referenceDB` holds exactly 16 measured entries, and more
/// would need the reference curve re-measured against live audio.
struct AudioVisualizerSpectrumView: View {

    /// Nil where the visualiser is not wired up; the bar then lies flat.
    let service: AudioVisualizerService?
    /// The progress tint: the artwork accent, or the media accent.
    let accent: Color
    /// Playback position, 0...1.
    let progress: Double

    /// Brightness at silence and at full level. The played floor is what makes
    /// the wave legible — the old 0.42 floor left quiet stretches near
    /// invisible — and it sits well above the grey's ceiling, so played and
    /// unplayed stay distinct at any level.
    ///
    /// The unplayed side tops out at 25% so it recedes behind the title. At
    /// 0.25...0.45 it read as a grey slab and pulled the eye (2026-09-16).
    nonisolated private static let playedOpacity: ClosedRange<Double> = 0.6...1.0
    nonisolated private static let unplayedOpacity: ClosedRange<Double> = 0.15...0.25

    /// The played side's bloom: a blurred copy of the played fill, added on
    /// top of it. A copy of the fill rather than a flat accent silhouette, so
    /// it is brightest where the wave is — along the crest, fading down the
    /// body — and keeps the crest-to-base fade instead of flooding the dim
    /// base. Tinted by the same `accent`, so it retints per track.
    ///
    /// `glowRadius` is the blur radius in points: larger spreads the bloom
    /// further off the crest. `glowOpacity` is its strength: 0 turns it off.
    nonisolated private static let glowRadius: CGFloat = 3
    nonisolated private static let glowOpacity: Double = 0.35
    /// Fade steps in the blurred copy. Fewer than the sharp fill's
    /// `SpectrumEnvelope.fadeSteps`: the blur hides the steps, and each one is
    /// another fill every frame.
    nonisolated private static let glowFadeSteps: Int = 4
    /// How far the canvas reaches past the row, above and to the left, so the
    /// bloom off a tall crest or the left cap fades out instead of being cut
    /// by the canvas edge. Layout still sees the row alone. The base and the
    /// right end need none: the bloom is cut at the base and at the playhead
    /// anyway.
    nonisolated private static var glowBleed: CGFloat { glowRadius * 2 }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        let reduceMotion = reduceMotion
        let bands = service?.bands ?? []
        let progress = progress
        let accent = accent
        // Off means no wave is coming, so the bar carries the row on its own
        // and is drawn thicker. `isEnabled` is `@ObservationIgnored`, but
        // switching the visualiser off also zeroes `bands`, which is observed,
        // so the redraw that flattens the wave is the one that thickens it.
        let rest = SpectrumEnvelope.restHeight(visualizerOn: service?.isEnabled == true)
        return Canvas { context, size in
            // The row, inset from the canvas by the bleed above and left.
            let bleed = Self.glowBleed
            let rect = CGRect(x: bleed, y: bleed,
                              width: size.width - bleed, height: size.height - bleed)
            guard rect.width > 0, rect.height > 0 else { return }
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(stops: Self.gradientStops(bands: bands, progress: progress,
                                                   accent: accent, in: rect, rest: rest)),
                startPoint: CGPoint(x: rect.minX, y: rect.midY),
                endPoint: CGPoint(x: rect.maxX, y: rect.midY))
            let edge = SpectrumEnvelope.upperEdge(magnitudes: bands, in: rect, rest: rest)
            let outline = SpectrumEnvelope.path(
                SpectrumEnvelope.outline(edge: edge, in: rect, rest: rest))

            Self.drawBody(context, edge: edge, outline: outline, region: nil,
                          shading: shading, fadeBands: SpectrumEnvelope.fadeBands(), in: rect)

            let playheadX = rect.minX + rect.width * CGFloat(min(1, max(0, progress)))
            guard playheadX > rect.minX, Self.glowOpacity > 0 else { return }
            // Everything left of the playhead and above the base, bleed
            // included.
            let played = Path(CGRect(x: 0, y: 0, width: playheadX, height: rect.maxY))
            var bloom = context
            bloom.blendMode = .plusLighter
            bloom.drawLayer { glow in
                // Cut after the blur, so none of it spills past the playhead
                // onto the grey. The cut coincides with the fill's own hard
                // colour edge there.
                glow.clip(to: played)
                glow.drawLayer { blurred in
                    blurred.addFilter(.blur(radius: Self.glowRadius))
                    blurred.opacity = Self.glowOpacity
                    // Cut before the blur too, inside `drawBody`, so the grey
                    // never feeds the bloom.
                    Self.drawBody(blurred, edge: edge, outline: outline, region: played,
                                  shading: shading,
                                  fadeBands: SpectrumEnvelope.fadeBands(steps: Self.glowFadeSteps),
                                  in: rect)
                }
            }
        }
        // Drawing overflows the row by the bloom's bleed; see `glowBleed`.
        .padding(EdgeInsets(top: -Self.glowBleed, leading: -Self.glowBleed,
                            bottom: 0, trailing: 0))
        // No implicit animation: each publish lands as it is. The bands
        // arrive already smoothed — an eased rise and a slower fall, see
        // `AudioVisualizerService.barAttack` and `barRelease` — and at most
        // every `publishInterval`, so a view animation would be a second
        // smoother on top. It was `.animation(.linear(duration: 0.03),
        // value: bands)` on the earlier 16 bars, and with ~47 publishes a
        // second every update started a new animation over one still running.
        // Removing it saved 7.6 points of a core by Time Profiler (2026-09-16;
        // PROJECT-CONTEXT.md, *Performance findings*). A Canvas was also tried
        // for those bars and measured no cheaper by CPU time (8.5 points
        // against 8.6); it is used here because the crest fade needs many
        // fills per frame, not for cost. The sink on pause is not an
        // animation here either: the service publishes it as ordinary band
        // updates, only after a pause.
        .accessibilityLabel("Playback position")
        // Hard rule 8. The wave does not animate itself, but a transaction
        // inherited from an ancestor could still tween it. Under Reduce
        // Motion, nothing in this view animates.
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    /// The vertical fade, as bands from each column's crest down to the base,
    /// each at its own brightness, clipped to the wave and, when given, to
    /// `region`. They are drawn additively in their own layer: adjacent bands
    /// share an anti-aliased edge, and ordinary compositing would leave a
    /// faint dark seam along every one of them.
    nonisolated private static func drawBody(_ context: GraphicsContext,
                                             edge: SpectrumEnvelope.Edge, outline: Path,
                                             region: Path?, shading: GraphicsContext.Shading,
                                             fadeBands: [SpectrumEnvelope.FadeBand],
                                             in rect: CGRect) {
        context.drawLayer { layer in
            layer.clip(to: outline)
            if let region { layer.clip(to: region) }
            layer.blendMode = .plusLighter
            for band in fadeBands {
                var step = layer
                step.opacity = band.brightness
                step.fill(SpectrumEnvelope.path(SpectrumEnvelope.ribbon(
                              edge: edge, in: rect, from: band.from, to: band.to)),
                          with: shading)
            }
        }
    }

    /// One horizontal gradient carries brightness per band and progress by
    /// colour, with the accent and the grey meeting in a hard edge at the
    /// playhead. See `SpectrumEnvelope.progressStops`.
    nonisolated private static func gradientStops(bands: [Float], progress: Double,
                                                  accent: Color, in rect: CGRect,
                                                  rest: CGFloat) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        for stop in SpectrumEnvelope.progressStops(magnitudes: bands,
                                                   playhead: CGFloat(progress), in: rect,
                                                   rest: rest) {
            let magnitude = Double(stop.magnitude)
            let color = stop.played
                ? accent.opacity(playedOpacity.lowerBound
                    + (playedOpacity.upperBound - playedOpacity.lowerBound) * magnitude)
                : Color.white.opacity(unplayedOpacity.lowerBound
                    + (unplayedOpacity.upperBound - unplayedOpacity.lowerBound) * magnitude)
            stops.append(Gradient.Stop(color: color, location: stop.location))
        }
        return stops
    }
}

/// The scrub bar wave's geometry, fade and progress stops, as pure functions
/// so the bounds they must respect are a test rather than a look.
///
/// **Top edge.** Two tips at the silent height, one just inside each end, and
/// the 16 band points between them, `taperWidth` in from each tip. Each band
/// sits `minHeight + (row height − minHeight) × magnitude` above the base.
/// The curve leaves and meets each tip flat, so the taper settles into the
/// round caps instead of meeting them at an angle.
///
/// **Ends and base.** A semicircular cap at each end, radius half the tip's
/// height, and a flat base along the row's bottom edge between them.
///
/// **Monotone cubic interpolation (Fritsch–Carlson), not Catmull-Rom.**
/// Catmull-Rom overshoots between points, which would push the wave out of
/// the row or drag its top edge below the silent height. A monotone curve
/// never passes above or below the two points it joins.
enum SpectrumEnvelope {

    /// The scrub bar row's height (`MediaProgressBar`), which is the wave's
    /// height at full level. Raised from 24 with `minHeight` lowered from 4
    /// (2026-09-16), so loud passages visibly swell and quiet ones visibly dip.
    /// The artwork beside the header column is sized from this
    /// (`PlayerLayout.artworkSide`), so it follows any change here.
    nonisolated static let maxHeight: CGFloat = 30
    /// The wave's height at silence: a flat bar, so the scrub bar still reads
    /// as a progress bar with no spectrum behind it. Also the tips' height, so
    /// it sets the round caps' size.
    nonisolated static let minHeight: CGFloat = 2

    /// The flat bar's height when the visualiser is **off**, so no wave is
    /// coming. At `minHeight` the bar is a 2pt line — legible while a wave
    /// moves around it, thin and fiddly on its own. This is the pre-wave
    /// capsule's 6pt, so with the spectrum switched off the scrub bar reads as
    /// the progress bar it used to be. The row keeps `maxHeight`, so nothing
    /// around it moves and the artwork beside it does not resize.
    nonisolated static let restHeightVisualizerOff: CGFloat = 6

    /// The flat bar's height for the state the visualiser is in. One place, so
    /// the drawing and any test cannot disagree about which height applies.
    nonisolated static func restHeight(visualizerOn: Bool) -> CGFloat {
        visualizerOn ? minHeight : restHeightVisualizerOff
    }

    /// Horizontal run at each end from the round tip to the first (or last)
    /// band's point, over which the wave tapers down to the silent height.
    nonisolated static let taperWidth: CGFloat = 16

    /// Steps the vertical fade is drawn in, crest to base. Each step is the
    /// same fraction of its column's height, so every part of the wave fades
    /// from its own crest to the base, however tall it is.
    nonisolated static let fadeSteps: Int = 12
    /// Brightness at the base, as a fraction of full brightness at the crest.
    /// Lower makes the crest stand out more. The flat silent bar fades across
    /// its own 2pt too, averaging about two-thirds of full.
    nonisolated static let baselineBrightness: Double = 0.35

    /// A quarter circle's cubic control distance, as a fraction of its radius.
    nonisolated private static let kappa: CGFloat = 0.552_284_75

    /// One cubic Bézier piece of the top edge.
    struct Segment: Equatable {
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint
    }

    /// The top edge, left to right: its first point and one segment per gap
    /// between points.
    struct Edge: Equatable {
        var start: CGPoint
        var segments: [Segment]
    }

    /// One step of a closed outline, in drawing order.
    enum Element: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    }

    /// One colour stop of the scrub bar's fill, before it is given a colour.
    struct ProgressStop: Equatable {
        var location: CGFloat
        var played: Bool
        var magnitude: CGFloat
    }

    /// One band of the vertical fade: how far it runs from the crest (0) to
    /// the base (1), and its brightness.
    struct FadeBand: Equatable {
        var from: CGFloat
        var to: CGFloat
        var brightness: Double
    }

    // MARK: - Geometry

    /// The round caps' radius: half the tip's height, kept inside the row.
    nonisolated static func capRadius(in rect: CGRect, rest: CGFloat = minHeight) -> CGFloat {
        max(0, min(min(rest, rect.height) / 2, rect.width / 2))
    }

    /// Where the 16 band points sit: `taperWidth` in from each tip, evenly
    /// spaced between. The taper shrinks on a row too narrow to hold it.
    nonisolated static func bandXs(in rect: CGRect, rest: CGFloat = minHeight) -> [CGFloat] {
        let count = AudioVisualizerService.bandCount
        let cap = capRadius(in: rect, rest: rest)
        let taper = min(taperWidth, max(0, (rect.width - 2 * cap) / 4))
        let first = rect.minX + cap + taper
        let last = rect.maxX - cap - taper
        var xs: [CGFloat] = []
        for band in 0..<count {
            xs.append(first + (last - first) * CGFloat(band) / CGFloat(count - 1))
        }
        return xs
    }

    /// The top edge for these magnitudes: tip, 16 bands, tip.
    nonisolated static func upperEdge(magnitudes: [Float], in rect: CGRect,
                                      rest: CGFloat = minHeight) -> Edge {
        let floor = min(rest, rect.height)
        let cap = capRadius(in: rect, rest: rest)
        var xs: [CGFloat] = [rect.minX + cap]
        var heights: [CGFloat] = [floor]
        let bandPoints = bandXs(in: rect, rest: rest)
        for band in 0..<bandPoints.count {
            xs.append(bandPoints[band])
            heights.append(floor + (rect.height - floor) * magnitude(of: magnitudes, band: band))
        }
        xs.append(rect.maxX - cap)
        heights.append(floor)

        var tangents = monotoneTangents(xs: xs, ys: heights)
        // Flat at both tips, so the taper settles into the caps. A zero
        // tangent never breaks monotonicity.
        tangents[0] = 0
        tangents[tangents.count - 1] = 0

        var segments: [Segment] = []
        for index in 0..<(xs.count - 1) {
            let dx = xs[index + 1] - xs[index]
            segments.append(Segment(
                control1: CGPoint(x: xs[index] + dx / 3,
                                  y: rect.maxY - (heights[index] + tangents[index] * dx / 3)),
                control2: CGPoint(x: xs[index + 1] - dx / 3,
                                  y: rect.maxY - (heights[index + 1] - tangents[index + 1] * dx / 3)),
                end: CGPoint(x: xs[index + 1], y: rect.maxY - heights[index + 1])))
        }
        return Edge(start: CGPoint(x: xs[0], y: rect.maxY - heights[0]), segments: segments)
    }

    /// The closed wave: the top edge, a round cap at the right, the flat base
    /// back to the left, and a round cap there.
    nonisolated static func outline(edge: Edge, in rect: CGRect,
                                    rest: CGFloat = minHeight) -> [Element] {
        guard rect.width > 0, rect.height > 0 else { return [] }
        let base = rect.maxY
        let radius = capRadius(in: rect, rest: rest)
        let curl = kappa * radius
        let right = rect.maxX - radius
        let left = rect.minX + radius

        var elements: [Element] = [.move(edge.start)]
        for segment in edge.segments {
            elements.append(.curve(to: segment.end, control1: segment.control1,
                                   control2: segment.control2))
        }
        elements.append(.curve(to: CGPoint(x: rect.maxX, y: base - radius),
                               control1: CGPoint(x: right + curl, y: base - 2 * radius),
                               control2: CGPoint(x: rect.maxX, y: base - radius - curl)))
        elements.append(.curve(to: CGPoint(x: right, y: base),
                               control1: CGPoint(x: rect.maxX, y: base - radius + curl),
                               control2: CGPoint(x: right + curl, y: base)))
        elements.append(.line(CGPoint(x: left, y: base)))
        elements.append(.curve(to: CGPoint(x: rect.minX, y: base - radius),
                               control1: CGPoint(x: left - curl, y: base),
                               control2: CGPoint(x: rect.minX, y: base - radius + curl)))
        elements.append(.curve(to: CGPoint(x: left, y: base - 2 * radius),
                               control1: CGPoint(x: rect.minX, y: base - radius - curl),
                               control2: CGPoint(x: left - curl, y: base - 2 * radius)))
        return elements
    }

    /// The part of the wave from `top` to `bottom` of the way down from the
    /// crest to the base (0 is the crest, 1 the base): the top edge lowered by
    /// each fraction, run out flat to the row's ends, and joined into a closed
    /// band. Lowering by a fraction scales the edge toward the base, which
    /// maps a Bézier's control points exactly, so each band boundary is itself
    /// a smooth curve. Clipped to `outline` when drawn, which trims it to the
    /// caps and the base.
    nonisolated static func ribbon(edge: Edge, in rect: CGRect,
                                   from top: CGFloat, to bottom: CGFloat) -> [Element] {
        let base = rect.maxY
        let last = edge.segments.last?.end ?? edge.start
        var elements: [Element] = [
            .move(CGPoint(x: rect.minX, y: lowered(edge.start, by: top, toward: base).y)),
            .line(lowered(edge.start, by: top, toward: base)),
        ]
        for segment in edge.segments {
            elements.append(.curve(to: lowered(segment.end, by: top, toward: base),
                                   control1: lowered(segment.control1, by: top, toward: base),
                                   control2: lowered(segment.control2, by: top, toward: base)))
        }
        elements.append(.line(CGPoint(x: rect.maxX, y: lowered(last, by: top, toward: base).y)))
        elements.append(.line(CGPoint(x: rect.maxX, y: lowered(last, by: bottom, toward: base).y)))
        elements.append(.line(lowered(last, by: bottom, toward: base)))
        for index in edge.segments.indices.reversed() {
            let segment = edge.segments[index]
            let target = index == 0 ? edge.start : edge.segments[index - 1].end
            elements.append(.curve(to: lowered(target, by: bottom, toward: base),
                                   control1: lowered(segment.control2, by: bottom, toward: base),
                                   control2: lowered(segment.control1, by: bottom, toward: base)))
        }
        elements.append(.line(CGPoint(x: rect.minX, y: lowered(edge.start, by: bottom, toward: base).y)))
        return elements
    }

    nonisolated static func path(_ elements: [Element]) -> Path {
        var path = Path()
        guard !elements.isEmpty else { return path }
        for element in elements {
            switch element {
            case .move(let point):
                path.move(to: point)
            case .line(let point):
                path.addLine(to: point)
            case .curve(let point, let control1, let control2):
                path.addCurve(to: point, control1: control1, control2: control2)
            }
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Fade

    /// How far the first and last bands reach past the crest and the base, as
    /// a fraction of the column, so anti-aliasing at the clip's edge never
    /// leaves an unpainted sliver.
    nonisolated private static let fadeOverreach: CGFloat = 0.1

    /// The vertical fade, crest to base: `steps` equal bands (`fadeSteps`
    /// unless asked for fewer, as the blurred bloom does), each the same
    /// fraction of its column's height, brightness falling from full at the
    /// crest to `baselineBrightness` at the base.
    ///
    /// Proportional since 2026-09-16. It was measured in points below the
    /// crest, fading over 14pt, which left every part of the wave shorter
    /// than that fully bright down to the base — most of the wave, most of the
    /// time — so the row read bottom-heavy.
    nonisolated static func fadeBands(steps requested: Int = fadeSteps) -> [FadeBand] {
        let steps = max(2, requested)
        var bands: [FadeBand] = []
        for index in 0..<steps {
            let fraction = Double(index) / Double(steps - 1)
            bands.append(FadeBand(
                from: index == 0 ? -fadeOverreach : CGFloat(index) / CGFloat(steps),
                to: index == steps - 1 ? 1 + fadeOverreach : CGFloat(index + 1) / CGFloat(steps),
                brightness: 1 - (1 - baselineBrightness) * fraction))
        }
        return bands
    }

    // MARK: - Progress

    /// Stops for the horizontal gradient: one per band at its point, played
    /// if it is left of the playhead and unplayed if right of it, plus a pair
    /// at the playhead itself — played, then unplayed, at the same location
    /// and magnitude — which makes the colour change a hard edge instead of a
    /// blend. The pair's magnitude is interpolated between the band stops
    /// either side, and held at the end band's inside the taper. Past the
    /// first and last stops the gradient holds their colours.
    nonisolated static func progressStops(magnitudes: [Float], playhead: CGFloat,
                                          in rect: CGRect,
                                          rest: CGFloat = minHeight) -> [ProgressStop] {
        let count = AudioVisualizerService.bandCount
        let head = min(1, max(0, playhead))
        var locations: [CGFloat] = []
        if rect.width > 0 {
            for x in bandXs(in: rect, rest: rest) {
                locations.append((x - rect.minX) / rect.width)
            }
        } else {
            for band in 0..<count {
                locations.append(CGFloat(band) / CGFloat(count - 1))
            }
        }

        var atHead = magnitude(of: magnitudes, band: 0)
        if head >= locations[count - 1] {
            atHead = magnitude(of: magnitudes, band: count - 1)
        } else if head > locations[0] {
            for band in 0..<(count - 1) where head >= locations[band] && head < locations[band + 1] {
                let span = locations[band + 1] - locations[band]
                let fraction = span > 0 ? (head - locations[band]) / span : 0
                let lower = magnitude(of: magnitudes, band: band)
                atHead = lower + (magnitude(of: magnitudes, band: band + 1) - lower) * fraction
            }
        }

        var stops: [ProgressStop] = []
        var edgePlaced = false
        for band in 0..<count {
            let location = locations[band]
            if !edgePlaced && location >= head {
                stops.append(ProgressStop(location: head, played: true, magnitude: atHead))
                stops.append(ProgressStop(location: head, played: false, magnitude: atHead))
                edgePlaced = true
            }
            if location < head {
                stops.append(ProgressStop(location: location, played: true,
                                          magnitude: magnitude(of: magnitudes, band: band)))
            } else if location > head {
                stops.append(ProgressStop(location: location, played: false,
                                          magnitude: magnitude(of: magnitudes, band: band)))
            }
        }
        if !edgePlaced {
            stops.append(ProgressStop(location: head, played: true, magnitude: atHead))
            stops.append(ProgressStop(location: head, played: false, magnitude: atHead))
        }
        return stops
    }

    // MARK: - Helpers

    /// A band's magnitude, 0 when absent. Bands are 0...1 by construction;
    /// clamped so the geometry's bounds do not depend on that.
    nonisolated private static func magnitude(of magnitudes: [Float], band: Int) -> CGFloat {
        guard band >= 0, band < magnitudes.count else { return 0 }
        return min(1, max(0, CGFloat(magnitudes[band])))
    }

    /// `point` moved `fraction` of the way down to `base`.
    nonisolated private static func lowered(_ point: CGPoint, by fraction: CGFloat,
                                            toward base: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: point.y + (base - point.y) * fraction)
    }

    /// Fritsch–Carlson tangents: secant averages, zeroed at local extrema and
    /// on flat stretches, then scaled back wherever they would let a segment
    /// overshoot. With every tangent within three times its segment's slope,
    /// each Bézier control point stays between the two values it joins.
    nonisolated static func monotoneTangents(xs: [CGFloat], ys: [CGFloat]) -> [CGFloat] {
        let count = ys.count
        guard count > 1 else { return Array(repeating: 0, count: count) }

        var slopes = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = xs[index + 1] - xs[index]
            slopes[index] = dx > 0 ? (ys[index + 1] - ys[index]) / dx : 0
        }

        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = slopes[0]
        tangents[count - 1] = slopes[count - 2]
        for index in 1..<(count - 1) {
            tangents[index] = slopes[index - 1] * slopes[index] <= 0
                ? 0
                : (slopes[index - 1] + slopes[index]) / 2
        }

        for index in 0..<(count - 1) {
            let slope = slopes[index]
            guard slope != 0 else {
                tangents[index] = 0
                tangents[index + 1] = 0
                continue
            }
            let a = tangents[index] / slope
            let b = tangents[index + 1] / slope
            let magnitude = a * a + b * b
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                tangents[index] = scale * a * slope
                tangents[index + 1] = scale * b * slope
            }
        }
        return tangents
    }
}

/// The visualiser's denied path in the panel: one line in the header corner
/// the bars used to occupy, shown only when capture was refused.
///
/// The scrub bar has no room for text, and with capture refused it simply
/// lies flat. Without this hint a refused System Audio Recording grant would
/// look exactly like the feature being off.
struct AudioVisualizerPermissionHint: View {

    let service: AudioVisualizerService

    var body: some View {
        // Enabled but not capturing: almost always the permission. A hint
        // beats a spectrum that silently never moves.
        if service.isEnabled, service.lastError != nil {
            Text("Allow System Audio Recording")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
        }
    }
}
