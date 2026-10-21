import Foundation

/// Per-app bass boost (V2 Phase 3): one low shelf per app per channel in the
/// tap render path, then a lookahead peak limiter per app. Three fixed
/// levels plus off; no EQ, no bands, no presets.
///
/// **A real boost, limited.** The shelf lifts everything below ~120 Hz by
/// the full +6, +12 or +18 dB and leaves the mids and highs at 0 dB, so a
/// boosted app is as loud as before plus its bass. Bass that was already
/// near full scale now leaves it, and the limiter after the shelf catches
/// exactly those peaks (see `Limiter`).
///
/// Changed 2026-09-28 by the owner. The first build folded 1/A² and a 1/‖h‖₁
/// guard into the shelf so no sample could grow, which kept the bass flat
/// and cut everything above ~250 Hz by up to 9.6 dB: a treble cut, heard as
/// the app getting quieter rather than bassier. The steps were +3, +6 and
/// +9 dB until the owner heard the uncompensated boost as "almost
/// negligible" and doubled them, the same evening.
///
/// Settings store the level (1...3), never decibels, so the curve can be
/// retuned without a migration.
nonisolated enum BassBoost {

    /// The saved levels. 0 is off and is stored as absence.
    static let levels = 1...3
    /// The shelf's midpoint (half the gain, RBJ cookbook definition).
    static let shelfHz = 120.0

    /// +6, +12 or +18 dB of bass; 0 for off or anything outside `levels`.
    static func gainDB(level: Int) -> Double {
        levels.contains(level) ? Double(level) * 6 : 0
    }

    /// Biquad coefficients in `vDSP_biquad` order, `[b0, b1, b2, a1, a2]`,
    /// all divided by a0 so the recursion's own coefficient is 1 and
    /// `y = b·x − a·y`. RBJ low shelf, slope S = 1 (the steepest shelf with
    /// no bump), gain +level·6 dB: DC at +gain, the highs at 0 dB, the
    /// midpoint at 120 Hz at half the gain. Identity for level 0. Called
    /// off the realtime thread only.
    static func coefficients(level: Int, sampleRate: Double) -> [Double] {
        let dB = gainDB(level: level)
        guard dB > 0, sampleRate > 0 else { return [1, 0, 0, 0, 0] }
        let a = pow(10, dB / 40)
        let w0 = 2 * Double.pi * min(shelfHz, sampleRate * 0.45) / sampleRate
        let cosW = cos(w0)
        // alpha = sin(w0)/2 · sqrt((A + 1/A)(1/S − 1) + 2), which is
        // sin(w0)/√2 at S = 1.
        let twoRootAAlpha = 2 * sqrt(a) * sin(w0) / sqrt(2)
        let b0 = a * ((a + 1) - (a - 1) * cosW + twoRootAAlpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
        let b2 = a * ((a + 1) - (a - 1) * cosW - twoRootAAlpha)
        let a0 = (a + 1) + (a - 1) * cosW + twoRootAAlpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosW)
        let a2 = (a + 1) + (a - 1) * cosW - twoRootAAlpha
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }

    /// The filter's gain at `hz`, linear. For tests and the doc's figures;
    /// never on the audio thread.
    static func magnitude(_ c: [Double], atHz hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let numRe = c[0] + c[1] * c1 + c[2] * c2
        let numIm = -(c[1] * s1 + c[2] * s2)
        let denRe = 1 + c[3] * c1 + c[4] * c2
        let denIm = -(c[3] * s1 + c[4] * s2)
        return sqrt((numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm))
    }

    /// The next level for one click on the row's badge: up one step, and
    /// past +18 back to off.
    static func next(after level: Int) -> Int {
        levels.contains(level + 1) ? level + 1 : 0
    }

    /// The peak limiter after the shelf, before the app's volume. One per
    /// app, linked across its two channels; it runs only while the app is
    /// boosted, so an unboosted app's path is untouched.
    ///
    /// - **Ceiling −1 dBFS.** No sample leaves the limiter above it, by
    ///   construction (below). Not 0 dBFS: the DAC reconstructs between
    ///   samples, and a sample-peak ceiling at 0 lets those inter-sample
    ///   peaks clip; −1 is the usual true-peak allowance.
    /// - **Soft knee, 4 dB wide.** Gain reduction starts for peaks at
    ///   −3 dBFS and eases in (the quadratic knee, ratio ∞) until peaks at
    ///   +1 dBFS land exactly on the ceiling; above that it is a brick wall.
    ///   Loud-but-legal peaks are touched gently rather than slammed.
    /// - **Attack 1 ms, by lookahead.** The boosted audio is delayed 1 ms
    ///   and the gain ramps linearly over that time, so it is already down
    ///   when the peak arrives: no overshoot, no clipping, and no
    ///   instantaneous gain step to click.
    /// - **Hold 20 ms, then release 150 ms** (exponential time constant).
    ///   The hold spans half a period of anything above 25 Hz, so the gain
    ///   stays put between a bass note's own peaks instead of recovering and
    ///   re-attacking every cycle — that per-cycle chase is how limiters
    ///   distort bass. The release is slow enough not to pump audibly and
    ///   fast enough that a single hit doesn't duck the next bar.
    /// - **Linked.** One gain for both channels, from the louder one. Each
    ///   channel limited alone would duck only the channel carrying the
    ///   peak, and the image would lurch toward the other side on every
    ///   kick; linked, the image stays where the mix put it.
    ///
    /// **The guarantee.** The gain is a piecewise-linear ramp with a knot
    /// every block (≤ the lookahead), and each knot is at most the gain the
    /// knee allows for the peak over the block before it and the block
    /// after it. Every sample lies between two knots that both respect its
    /// block's peak, so gain × |sample| ≤ ceiling everywhere.
    nonisolated enum Limiter {
        static let ceilingDB: Float = -1
        static let kneeDB: Float = 4
        static let lookaheadSeconds = 0.001
        static let holdSeconds = 0.020
        static let releaseSeconds = 0.150
        /// A block whose peak needs a gain within 0.1 dB above the current
        /// one is still "at the peak": the gain settles onto exactly what
        /// it needs, and the hold re-arms.
        static let holdMargin: Float = 1.0116

        static var ceiling: Float { pow(10, ceilingDB / 20) }

        /// The static curve as a gain: 1 below the knee, and above it
        /// whatever brings `peak` to the knee's output level. Never more
        /// than 1, and never lets `peak × gain` past the ceiling.
        static func gain(forPeak peak: Float) -> Float {
            guard peak > 0 else { return 1 }
            let input = 20 * log10(peak)
            let kneeStart = ceilingDB - kneeDB / 2
            guard input > kneeStart else { return 1 }
            let output: Float
            if input >= ceilingDB + kneeDB / 2 {
                output = ceilingDB
            } else {
                let over = input - kneeStart
                output = input - over * over / (2 * kneeDB)
            }
            return min(1, pow(10, (output - input) / 20))
        }
    }
}
