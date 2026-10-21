import XCTest
import CoreAudio
import os
@testable import Astraea

// V2 Phase 3: per-app bass boost. Every test here runs on synthesized
// buffers, fixtures or the fake HAL — none touches an audio device.

// MARK: - The curve

final class BassBoostCurveTests: XCTestCase {

    private let rates: [Double] = [44100, 48000, 96000]

    private func dB(_ linear: Double) -> Double { 20 * log10(linear) }

    /// The level's gain is bass *relative to the rest*: deep bass against
    /// the highs is +6, +12, +18 dB, and the shelf's midpoint at 120 Hz sits
    /// halfway (the RBJ definition of the shelf frequency).
    func testEachLevelLiftsTheBassByItsGainAgainstTheHighs() {
        for rate in rates {
            for level in BassBoost.levels {
                let c = BassBoost.coefficients(level: level, sampleRate: rate)
                let bass = BassBoost.magnitude(c, atHz: 20, sampleRate: rate)
                let highs = BassBoost.magnitude(c, atHz: 10_000, sampleRate: rate)
                let shelf = BassBoost.magnitude(c, atHz: BassBoost.shelfHz, sampleRate: rate)
                let expected = BassBoost.gainDB(level: level)
                XCTAssertEqual(dB(bass / highs), expected, accuracy: 0.25, "level \(level) at \(rate)")
                XCTAssertEqual(dB(shelf / highs), expected / 2, accuracy: 0.25,
                               "the shelf's midpoint is half the gain, level \(level) at \(rate)")
            }
        }
    }

    /// The absolute response: bass up by the full gain, mids and highs at
    /// 0 dB, the same at every rate. The 60 Hz figure is the S = 1 shelf's
    /// own slope, not a target.
    func testEachLevelRaisesTheBassAndLeavesTheRestAtUnity() {
        let at60: [Int: Double] = [1: 5.62, 2: 11.10, 3: 16.28]
        for rate in rates {
            for level in BassBoost.levels {
                let c = BassBoost.coefficients(level: level, sampleRate: rate)
                let gain = BassBoost.gainDB(level: level)
                let response = { (hz: Double) in self.dB(BassBoost.magnitude(c, atHz: hz, sampleRate: rate)) }
                let label = "level \(level) at \(rate)"
                XCTAssertEqual(response(1), gain, accuracy: 0.01, "DC, \(label)")
                XCTAssertEqual(response(60), at60[level] ?? 0, accuracy: 0.02, "60 Hz, \(label)")
                XCTAssertEqual(response(120), gain / 2, accuracy: 0.02, "120 Hz, \(label)")
                XCTAssertEqual(response(1000), 0, accuracy: 0.02, "1 kHz, \(label)")
                XCTAssertEqual(response(10_000), 0, accuracy: 0.01, "10 kHz, \(label)")
            }
        }
    }

    /// A boost, never a cut: no frequency drops below unity, and none
    /// rises past the level's gain. A sign error in the shelf would fail
    /// the first; a bump from the wrong slope, the second.
    func testNoFrequencyIsCutOrOvershoots() {
        for rate in rates {
            for level in BassBoost.levels {
                let c = BassBoost.coefficients(level: level, sampleRate: rate)
                let ceiling = pow(10, BassBoost.gainDB(level: level) / 20)
                var hz = 5.0
                while hz < rate / 2 {
                    let gain = BassBoost.magnitude(c, atHz: hz, sampleRate: rate)
                    XCTAssertGreaterThanOrEqual(gain, 1 - 1e-6, "level \(level) at \(hz) Hz, \(rate)")
                    XCTAssertLessThanOrEqual(gain, ceiling + 1e-9, "level \(level) at \(hz) Hz, \(rate)")
                    hz *= 1.05
                }
            }
        }
    }

    // The limiter's static curve.

    private var ceiling: Float { BassBoost.Limiter.ceiling }

    /// Below the knee (peaks up to −3 dBFS) the limiter does nothing.
    func testTheLimiterLeavesPeaksBelowTheKneeAlone() {
        for peak: Float in [0, 0.01, 0.25, 0.5, 0.7] {
            XCTAssertEqual(BassBoost.Limiter.gain(forPeak: peak), 1, "peak \(peak)")
        }
    }

    /// Past the knee (peaks from +1 dBFS) every peak lands on the ceiling.
    func testTheLimiterBringsLoudPeaksExactlyToTheCeiling() {
        XCTAssertEqual(ceiling, 0.8913, accuracy: 1e-4, "−1 dBFS")
        for peak: Float in [1.1221, 1.2, 1.5, 2, 2.82, 4, 10] {
            XCTAssertEqual(peak * BassBoost.Limiter.gain(forPeak: peak), ceiling, accuracy: 1e-5, "peak \(peak)")
        }
    }

    /// Inside the knee the reduction eases in: louder in is never quieter
    /// out, nothing passes the ceiling, and the curve meets both straight
    /// segments without a step.
    func testTheKneeIsSoftAndContinuous() {
        var previous: Float = 0
        var peak: Float = 0.6
        while peak < 1.3 {
            let out = peak * BassBoost.Limiter.gain(forPeak: peak)
            XCTAssertGreaterThanOrEqual(out, previous - 1e-6, "monotone at \(peak), to float rounding")
            XCTAssertLessThanOrEqual(out, ceiling + 1e-6, "under the ceiling at \(peak)")
            previous = out
            peak += 0.001
        }
        let kneeStart = pow(10, (BassBoost.Limiter.ceilingDB - BassBoost.Limiter.kneeDB / 2) / 20)
        let kneeEnd = pow(10, (BassBoost.Limiter.ceilingDB + BassBoost.Limiter.kneeDB / 2) / 20)
        XCTAssertEqual(BassBoost.Limiter.gain(forPeak: kneeStart * 1.0001), 1, accuracy: 1e-4)
        XCTAssertEqual(kneeEnd * 0.9999 * BassBoost.Limiter.gain(forPeak: kneeEnd * 0.9999), ceiling, accuracy: 1e-4)
        XCTAssertLessThan(BassBoost.Limiter.gain(forPeak: 0.9), 1, "a −0.9 dBFS peak is already eased")
    }

    func testOffAndOutOfRangeLevelsAreIdentity() {
        for level in [0, -1, 4, 99] {
            XCTAssertEqual(BassBoost.coefficients(level: level, sampleRate: 48000), [1, 0, 0, 0, 0])
            XCTAssertEqual(BassBoost.gainDB(level: level), 0)
        }
    }

    func testTheCoefficientsAreStable() {
        for rate in rates {
            for level in BassBoost.levels {
                let c = BassBoost.coefficients(level: level, sampleRate: rate)
                // Jury's conditions for a second-order denominator.
                XCTAssertLessThan(abs(c[4]), 1)
                XCTAssertLessThan(abs(c[3]), 1 + c[4])
            }
        }
    }

    /// The badge: each click steps up, and past +18 wraps to off.
    func testAClickStepsUpAndWrapsToOff() {
        XCTAssertEqual(BassBoost.next(after: 0), 1)
        XCTAssertEqual(BassBoost.next(after: 1), 2)
        XCTAssertEqual(BassBoost.next(after: 2), 3)
        XCTAssertEqual(BassBoost.next(after: 3), 0)
        XCTAssertEqual(BassBoost.next(after: 7), 0, "a stray level resets rather than climbing")
    }
}

// MARK: - The render path

/// `TapRenderState.render` driven with synthesized buffers, the way the
/// IOProc calls it.
final class BassBoostRenderTests: XCTestCase {

    private let rate = 48000.0
    /// 512 frames, interleaved stereo: a typical HAL buffer.
    private let bufferSamples = 1024

    // Helpers

    /// One callback: `streams` as the input buffers, one output buffer.
    private func callback(_ state: TapRenderState, _ streams: [[Float]]) -> [Float] {
        let count = streams.first?.count ?? 0
        let inputs = AudioBufferList.allocate(maximumBuffers: streams.count)
        let outputs = AudioBufferList.allocate(maximumBuffers: 1)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: count)
        var owned: [UnsafeMutablePointer<Float>] = []
        defer {
            owned.forEach { $0.deallocate() }
            out.deallocate()
            free(inputs.unsafeMutablePointer)
            free(outputs.unsafeMutablePointer)
        }
        for (index, samples) in streams.enumerated() {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
            pointer.initialize(from: samples, count: samples.count)
            owned.append(pointer)
            inputs[index] = AudioBuffer(mNumberChannels: 2,
                                        mDataByteSize: UInt32(samples.count * 4), mData: pointer)
        }
        outputs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(count * 4), mData: out)
        state.render(inputs: inputs, outputs: outputs)
        return Array(UnsafeBufferPointer(start: out, count: count))
    }

    /// A whole signal per stream, cut into callbacks of `bufferSamples`,
    /// with `between` run before each callback (a level change, say).
    private func run(_ state: TapRenderState, _ streams: [[Float]],
                     buffer: Int? = nil, between: ((Int) -> Void)? = nil) -> [Float] {
        let size = buffer ?? bufferSamples
        var output: [Float] = []
        var start = 0
        var index = 0
        while start < streams[0].count {
            let end = min(start + size, streams[0].count)
            between?(index)
            output += callback(state, streams.map { Array($0[start..<end]) })
            start = end
            index += 1
        }
        return output
    }

    private func state(slots: [Int32], bass: [Int], gain: Float = 1) -> TapRenderState {
        let state = TapRenderState(sampleRate: rate)
        for (slot, level) in zip(slots, bass) {
            state.prepareSlot(Int(slot), targetGain: gain, bass: level)
        }
        state.setMapping(bufferCount: slots.count, slots: slots)
        return state
    }

    /// Interleaved stereo: `left` and `right` sample generators.
    private func stereo(frames: Int, left: (Int) -> Float, right: (Int) -> Float) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            samples[2 * frame] = left(frame)
            samples[2 * frame + 1] = right(frame)
        }
        return samples
    }

    private func sine(_ hz: Double, amplitude: Float = 0.5, phase: Double = 0) -> (Int) -> Float {
        { frame in amplitude * Float(sin(2 * .pi * hz * Double(frame) / self.rate + phase)) }
    }

    /// The difference equation in Double, per channel from silence: what
    /// the filter should produce, independent of vDSP.
    private func reference(_ samples: [Float], level: Int) -> [Float] {
        let c = BassBoost.coefficients(level: level, sampleRate: rate)
        var output = [Float](repeating: 0, count: samples.count)
        for channel in 0..<2 {
            var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
            for index in stride(from: channel, to: samples.count, by: 2) {
                let x = Double(samples[index])
                let y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2
                (x2, x1, y2, y1) = (x1, x, y1, y)
                output[index] = Float(y)
            }
        }
        return output
    }

    /// The limiter's lookahead at this rate, in frames: the boosted path
    /// comes out this late.
    private var lookahead: Int { TapRenderState(sampleRate: rate).limiterLookahead }

    /// `samples` as the boosted path plays them: one lookahead late.
    private func delayed(_ samples: [Float]) -> [Float] {
        let shift = 2 * lookahead
        return [Float](repeating: 0, count: shift) + samples.dropLast(shift)
    }

    /// The default tolerance is for vDSP against the Double reference:
    /// `vDSP_biquad` runs in single precision, and a pole pair at 120 Hz
    /// sits so close to the unit circle at 48 kHz that float rounding grows
    /// to ~2e-4 — about −68 dB under these 0.5-amplitude signals, and far
    /// below anything a logic error would produce.
    private func assertClose(_ a: ArraySlice<Float>, _ b: ArraySlice<Float>, _ message: String,
                             tolerance: Float = 5e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, message, file: file, line: line)
        let worst = zip(a, b).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, tolerance, "\(message) (worst \(worst))", file: file, line: line)
    }

    /// The largest sample-to-sample step within a channel: a click shows up
    /// as a jump far above what the signal itself does.
    private func largestStep(_ samples: [Float]) -> Float {
        var worst: Float = 0
        for index in 2..<samples.count { worst = max(worst, abs(samples[index] - samples[index - 2])) }
        return worst
    }

    // Tests

    /// Off is exactly the Phase 5 path: not one sample differs.
    func testOffRendersBitIdenticalToTheUnboostedPath() {
        let signal = stereo(frames: 4096, left: sine(50), right: sine(3000))
        let output = run(state(slots: [0], bass: [0]), [signal])
        XCTAssertEqual(output, signal)
    }

    /// Once engaged, the filter is the difference equation, per channel,
    /// one lookahead late. The first callback is the engage crossfade from
    /// dry; after it, every sample matches the reference run from silence.
    /// Quiet enough that even +18 dB stays under the limiter's knee.
    func testSteadyBoostIsTheReferenceFilter() {
        let signal = stereo(frames: 8192, left: sine(60, amplitude: 0.05), right: sine(2000, amplitude: 0.3))
        for level in BassBoost.levels {
            let output = run(state(slots: [0], bass: [level]), [signal])
            assertClose(output[bufferSamples...], delayed(reference(signal, level: level))[bufferSamples...],
                        "level \(level)")
        }
    }

    /// A buffer bigger than the scratch is filtered in chunks with the
    /// history carried across them: indistinguishable from the reference.
    func testBuffersLargerThanTheScratchAreFilteredWhole() {
        let big = 4 * TapRenderState.chunkSamples + 6
        let signal = stereo(frames: (bufferSamples + 2 * big) / 2,
                            left: sine(45, amplitude: 0.05), right: sine(700, amplitude: 0.2))
        let render = state(slots: [0], bass: [3])
        var output = callback(render, [Array(signal[..<bufferSamples])])
        output += callback(render, [Array(signal[bufferSamples..<(bufferSamples + big)])])
        output += callback(render, [Array(signal[(bufferSamples + big)...])])
        assertClose(output[bufferSamples...], delayed(reference(signal, level: 3))[bufferSamples...],
                    "chunked across a \(big)-sample buffer, the limiter's delay carried too")
    }

    /// Left's history never reaches right's filter, nor its lane of the
    /// limiter's delay line — though left here is loud enough to limit.
    func testChannelsKeepTheirOwnHistory() {
        let signal = stereo(frames: 4096, left: sine(40, amplitude: 0.9), right: { _ in 0 })
        let output = run(state(slots: [0], bass: [3]), [signal])
        let right = stride(from: 1, to: output.count, by: 2).map { output[$0] }
        XCTAssertEqual(right.max(), 0)
        XCTAssertEqual(right.min(), 0)
    }

    /// Two apps on one aggregate: each renders exactly as it would alone,
    /// so neither's filter or limiter touches the other's. `a` is boosted
    /// hard enough to limit throughout; `b` stays under the knee, so a
    /// shared limiter would duck it and fail the sum.
    func testEachAppKeepsItsOwnFilter() {
        let a = stereo(frames: 8192, left: sine(50), right: sine(55))
        let b = stereo(frames: 8192, left: sine(90, amplitude: 0.3), right: sine(4000, amplitude: 0.2))
        let together = run(state(slots: [2, 5], bass: [3, 1]), [a, b])
        let aAlone = run(state(slots: [2], bass: [3]), [a])
        let bAlone = run(state(slots: [5], bass: [1]), [b])
        assertClose(together[...], zip(aAlone, bAlone).map { $0 + $1 }[...],
                    "the mix is the sum of each app filtered alone", tolerance: 1e-5)
        XCTAssertGreaterThan(reference(a, level: 3).map(abs).max() ?? 0, 1.2, "a needs limiting")
        XCTAssertLessThan(reference(b, level: 1).map(abs).max() ?? 0, 0.7, "b stays under the knee")
    }

    /// Linked: both channels get one gain, from the louder. Right is left
    /// at a quarter, and stays exactly a quarter while left is limited —
    /// independent limiters would leave right alone and pull the image.
    func testTheLimiterIsLinkedAcrossChannels() {
        let loud = sine(40, amplitude: 0.9)
        let signal = stereo(frames: 8192, left: loud, right: { frame in 0.25 * loud(frame) })
        let output = run(state(slots: [0], bass: [3]), [signal])
        let steady = bufferSamples..<output.count
        let left = stride(from: steady.lowerBound, to: steady.upperBound, by: 2).map { output[$0] }
        let right = stride(from: steady.lowerBound + 1, to: steady.upperBound, by: 2).map { output[$0] }
        XCTAssertGreaterThan(left.map(abs).max() ?? 0, 0.85, "left is on the ceiling")
        let worst = zip(left, right).map { abs($0 * 0.25 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 1e-6, "right keeps its place in the image")
    }

    /// The threshold in the render path, at 1 kHz where the shelf is flat:
    /// a −6 dBFS peak passes untouched, −1.4 and 0 dBFS peaks are eased by
    /// the knee's curve, and a +3.5 dBFS peak settles on the ceiling. Read
    /// over the last quarter of a second: engaging from silence sends a
    /// start-up transient through the shelf, which the limiter ducks and
    /// then releases over its 150 ms.
    func testTheLimiterThresholdInTheRenderPath() {
        for amplitude: Float in [0.5, 0.85, 1.0, 1.5] {
            let signal = stereo(frames: 48000, left: sine(1000, amplitude: amplitude),
                                right: sine(1000, amplitude: amplitude))
            let output = run(state(slots: [0], bass: [3]), [signal])
            let peak = output[(3 * output.count / 4)...].map(abs).max() ?? 0
            let expected = amplitude * BassBoost.Limiter.gain(forPeak: amplitude)
            XCTAssertEqual(peak, expected, accuracy: 2e-3, "amplitude \(amplitude)")
            XCTAssertLessThanOrEqual(peak, BassBoost.Limiter.ceiling + 1e-5)
        }
    }

    /// Reset on engage: a slot handed to a new leg starts from silence,
    /// whatever the previous leg left in its history.
    func testANewLegInASlotStartsFromCleanHistory() {
        let previous = stereo(frames: 8192, left: sine(35, amplitude: 0.9), right: sine(35, amplitude: 0.9))
        let next = stereo(frames: 4096, left: sine(80), right: sine(200))

        let reused = state(slots: [0], bass: [3])
        _ = run(reused, [previous])
        XCTAssertLessThan(reused.limiterGains[0], 0.5, "the previous leg left the limiter deep in reduction")
        reused.prepareSlot(0, targetGain: 1, bass: 3)  // the next leg takes slot 0
        let fresh = state(slots: [0], bass: [3])
        XCTAssertEqual(run(reused, [next]), run(fresh, [next]),
                       "a stale filter carried across apps is a bug")

        // The test has teeth: without the handover, the history does ring on.
        let stale = state(slots: [0], bass: [3])
        _ = run(stale, [previous])
        XCTAssertNotEqual(run(stale, [next]), run(state(slots: [0], bass: [3]), [next]))
    }

    /// Reset on teardown: a released slot plays dry to any straggling
    /// callback, and keeps nothing for the leg that takes it next.
    func testAReleasedSlotForgetsItsLeg() {
        let previous = stereo(frames: 8192, left: sine(35, amplitude: 0.9), right: sine(35, amplitude: 0.9))
        let next = stereo(frames: 4096, left: sine(80), right: sine(200))
        let render = state(slots: [0], bass: [3])
        _ = run(render, [previous])
        XCTAssertLessThan(render.limiterGains[0], 0.5)

        render.releaseSlot(0)
        XCTAssertEqual(render.bassLevels[0], 0)
        let straggler = callback(render, [Array(next[..<bufferSamples])])
        XCTAssertEqual(straggler, Array(next[..<bufferSamples]), "a released slot is not filtered")

        render.prepareSlot(0, targetGain: 1, bass: 2)
        XCTAssertEqual(run(render, [next]), run(state(slots: [0], bass: [2]), [next]))
    }

    /// A level change crossfades over one callback: no step anywhere is
    /// larger than the signal's own steepest step allows. An instant switch
    /// onto a fresh filter would jump by (1 − b0)·x — about 0.25 at this
    /// signal's level, against a dry step of 0.003.
    func testLevelChangesNeverClick() {
        let signal = stereo(frames: 16 * 512, left: sine(50), right: sine(70, phase: 1))
        let render = state(slots: [0], bass: [0])
        let levels = [0, 0, 0, 0, 3, 3, 3, 3, 1, 1, 2, 2, 0, 0, 3, 3]
        let output = run(render, [signal]) { index in render.setBass(levels[index], slot: 0) }
        let dryStep = largestStep(signal)
        XCTAssertLessThan(largestStep(output), 2 * dryStep,
                          "dry step \(dryStep), boosted \(largestStep(output))")
    }

    /// Every level at full scale, against the worst signal there is for
    /// the shelf: ±1 aligned with the sign of its impulse response, which
    /// drives one output sample to ‖h‖₁ — 8.6 at +18 dB — and a 40 Hz
    /// square, a clipped 808. The limiter keeps both under −1 dBFS.
    func testTheLimiterHoldsEveryLevelUnderTheCeiling() {
        let silence = [Float](repeating: 0, count: bufferSamples)
        for level in BassBoost.levels {
            let c = BassBoost.coefficients(level: level, sampleRate: rate)
            var h: [Double] = []
            var (x1, x2, y1, y2) = (0.0, 0.0, 0.0, 0.0)
            for n in 0..<4096 {
                let x = n == 0 ? 1.0 : 0.0
                let y = c[0] * x + c[1] * x1 + c[2] * x2 - c[3] * y1 - c[4] * y2
                (x2, x1, y2, y1) = (x1, x, y1, y)
                h.append(y)
            }
            let worst: (Int) -> Float = { frame in h[4095 - frame] < 0 ? -1 : 1 }
            let square: (Int) -> Float = { frame in (frame / 600) % 2 == 0 ? 1 : -1 }
            for (name, generator) in [("worst case", worst), ("40 Hz square", square)] {
                let signal = silence + stereo(frames: 4096, left: generator, right: generator)
                let output = run(state(slots: [0], bass: [level]), [signal])
                let peak = output.map(abs).max() ?? 0
                XCTAssertLessThanOrEqual(peak, BassBoost.Limiter.ceiling + 1e-5, "\(name), level \(level)")
                XCTAssertGreaterThan(peak, 0.85, "\(name), level \(level): limited, not silenced")
                let unlimited = reference(signal, level: level).map(abs).max() ?? 0
                XCTAssertGreaterThan(unlimited, 1, "\(name), level \(level): the shelf alone clips")
            }
        }
    }
}

// MARK: - Volume above the app's own

/// The mixer's boost runs through the bass boost's limiter with no shelf
/// (`TapRenderState.flatLevel`). Separate from the class above for its
/// helpers' sake only; the signals are built the same way.
final class VolumeBoostRenderTests: XCTestCase {

    private let rate = 48000.0
    private let bufferSamples = 1024

    private func run(_ state: TapRenderState, _ signal: [Float],
                     between: ((Int) -> Void)? = nil) -> [Float] {
        var output: [Float] = []
        var start = 0
        var index = 0
        while start < signal.count {
            let end = min(start + bufferSamples, signal.count)
            let count = end - start
            between?(index)
            let inputs = AudioBufferList.allocate(maximumBuffers: 1)
            let outputs = AudioBufferList.allocate(maximumBuffers: 1)
            let input = UnsafeMutablePointer<Float>.allocate(capacity: count)
            let out = UnsafeMutablePointer<Float>.allocate(capacity: count)
            input.initialize(from: Array(signal[start..<end]), count: count)
            inputs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(count * 4), mData: input)
            outputs[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(count * 4), mData: out)
            state.render(inputs: inputs, outputs: outputs)
            output += Array(UnsafeBufferPointer(start: out, count: count))
            input.deallocate()
            out.deallocate()
            free(inputs.unsafeMutablePointer)
            free(outputs.unsafeMutablePointer)
            start = end
            index += 1
        }
        return output
    }

    private func state(gain: Float, bass: Int = 0) -> TapRenderState {
        let state = TapRenderState(sampleRate: rate)
        state.prepareSlot(0, targetGain: gain, bass: bass)
        state.setMapping(bufferCount: 1, slots: [0])
        return state
    }

    private func sine(frames: Int, hz: Double, amplitude: Float) -> [Float] {
        (0..<frames * 2).map { index in
            amplitude * Float(sin(2 * .pi * hz * Double(index / 2) / rate))
        }
    }

    /// A loud app at twice its volume would reach 1.8 — far past full
    /// scale. The limiter holds it under −1 dBFS, and it is limited, not
    /// silenced.
    func testTwiceALoudAppStaysUnderTheCeiling() {
        let output = run(state(gain: 2), sine(frames: 24000, hz: 440, amplitude: 0.9))
        let settled = output.suffix(24000)
        let peak = settled.map(abs).max() ?? 0
        XCTAssertLessThanOrEqual(peak, BassBoost.Limiter.ceiling + 1e-5)
        XCTAssertGreaterThan(peak, 0.85)
    }

    /// A quiet app boosted stays under the knee, so the limiter leaves it
    /// alone: once the ramp settles it is exactly louder, one lookahead late.
    func testAQuietAppIsBoostedCleanly() {
        let input = sine(frames: 24000, hz: 440, amplitude: 0.2)
        let output = run(state(gain: 1.5), input)
        let shift = 2 * TapRenderState(sampleRate: rate).limiterLookahead
        let worst = (24000..<48000).map { abs(output[$0] - 1.5 * input[$0 - shift]) }.max() ?? 0
        XCTAssertLessThan(worst, 1e-5)
    }

    /// Dragging up past the middle and back never clicks: the limiter's
    /// delay is crossfaded in and out, like a bass level change.
    func testCrossingUnityNeverClicks() {
        let input = sine(frames: 16 * 512, hz: 60, amplitude: 0.3)
        let render = state(gain: 1)
        let gains: [Float] = [1, 1, 1.2, 1.2, 1.5, 1.5, 1, 1, 1, 1, 0.8, 1.3, 1.3, 1, 1, 1]
        let output = run(render, input) { index in render.setTarget(gains[index], slot: 0) }
        func largestStep(_ samples: [Float]) -> Float {
            (2..<samples.count).map { abs(samples[$0] - samples[$0 - 2]) }.max() ?? 0
        }
        let dryStep = largestStep(input)
        XCTAssertLessThan(largestStep(output), 2 * 1.5 * dryStep,
                          "dry step \(dryStep), rendered \(largestStep(output))")
    }

    /// Back at the app's own volume the limiter lets go and the leg is
    /// exactly the unprocessed path again: not one sample differs.
    func testBackAtUnityIsBitIdenticalAgain() {
        let input = sine(frames: 16 * 1024, hz: 440, amplitude: 0.5)
        let render = state(gain: 1.6)
        let output = run(render, input) { index in if index == 4 { render.setTarget(1, slot: 0) } }
        XCTAssertEqual(Array(output.suffix(4 * 2048)), Array(input.suffix(4 * 2048)))
    }
}

// MARK: - Planning

final class BassBoostPlanTests: XCTestCase {

    private let devices = [
        TapHALDevice(uid: "spk", name: "Speakers", sampleRate: 48000,
                     isStereoOut: true, isAirPlay: false, hasInputStreams: false),
        TapHALDevice(uid: "air", name: "Room", sampleRate: 48000,
                     isStereoOut: true, isAirPlay: true, hasInputStreams: false),
        TapHALDevice(uid: "hdmi", name: "Receiver", sampleRate: 48000,
                     isStereoOut: false, isAirPlay: false, hasInputStreams: false),
        TapHALDevice(uid: "pods", name: "AirPods", sampleRate: 48000,
                     isStereoOut: true, isAirPlay: false, hasInputStreams: true),
    ]

    private func plan(_ desires: [TapDesire], legs: [TapLegFacts] = [], tapsEnabled: Bool = true,
                      permissionDenied: Bool = false, legsOnDevice: Int = 0)
        -> (ops: [TapPlanOp], states: [String: TapRowState]) {
        TapReconciler.plan(desires: desires, legs: legs, tapsEnabled: tapsEnabled,
                           permissionDenied: permissionDenied,
                           legsOnDevice: { _ in legsOnDevice },
                           device: { uid in self.devices.first { $0.uid == uid } })
    }

    private func boosted(_ level: Int = 3, position: Int = 100, device: String = "spk") -> TapDesire {
        TapDesire(key: "a", position: position, isPlaying: true, pids: [1],
                  deviceUIDs: [device], bass: level)
    }

    private func leg(gain: Float = 1, bass: Int = 3) -> TapLegFacts {
        TapLegFacts(key: "a", deviceUID: "spk", pids: [1], gain: gain, bass: bass)
    }

    func testABoostAloneAtFullVolumeEngagesAtUnity() {
        let result = plan([boosted(2)])
        XCTAssertEqual(result.ops, [.engage(key: "a", deviceUID: "spk", pids: [1], gain: 1, bass: 2)])
        XCTAssertEqual(result.states["a"], .engaged)
    }

    func testChangingTheLevelOnALiveLegIsOneOpNotARebuild() {
        XCTAssertEqual(plan([boosted(1)], legs: [leg(bass: 3)]).ops, [.setBass(key: "a", level: 1)])
        XCTAssertEqual(plan([boosted(3)], legs: [leg(bass: 3)]).ops, [], "unchanged plans nothing")
    }

    func testVolumeAndLevelChangingTogetherAreBothApplied() {
        let ops = plan([boosted(2, position: 40)], legs: [leg(gain: 0.7, bass: 1)]).ops
        XCTAssertEqual(ops, [.setGain(key: "a", gain: 0.4), .setBass(key: "a", level: 2)])
    }

    func testTurningTheBoostOffAtFullVolumeReleasesTheTap() {
        let result = plan([boosted(0)], legs: [leg(bass: 3)])
        XCTAssertEqual(result.ops, [.disengage(key: "a", afterGrace: false)])
        XCTAssertEqual(result.states["a"], .notTapped)
    }

    func testTurningTheBoostOffWhileTurnedDownKeepsTheLeg() {
        let ops = plan([boosted(0, position: 40)], legs: [leg(gain: 0.4, bass: 3)]).ops
        XCTAssertEqual(ops, [.setBass(key: "a", level: 0)])
    }

    func testAnOutOfRangeLevelIsOff() {
        XCTAssertEqual(plan([boosted(9)]).ops, [])
        XCTAssertEqual(plan([boosted(9)]).states["a"], .notTapped)
    }

    func testANewPidSetRebuildsWithTheLevel() {
        var desire = boosted(2)
        desire.pids = [2]
        XCTAssertEqual(plan([desire], legs: [leg(bass: 2)]).ops,
                       [.rebuild(key: "a", deviceUID: "spk", pids: [2], gain: 1, bass: 2)])
    }

    /// The same gates as volume and routing, with the same reasons.
    func testTheVolumeGatesApply() {
        XCTAssertEqual(plan([boosted(device: "air")]).states["a"], .inert(reason: "AirPlay output"))
        XCTAssertEqual(plan([boosted(device: "pods")]).states["a"], .inert(reason: "output has a microphone"))
        XCTAssertEqual(plan([boosted(device: "hdmi")]).states["a"], .inert(reason: "not a stereo output"))
        XCTAssertEqual(plan([boosted()], tapsEnabled: false).states["a"], .notTapped)
        XCTAssertEqual(plan([boosted()], permissionDenied: true).states["a"],
                       .inert(reason: "permission needed"))
        XCTAssertEqual(plan([boosted()], legsOnDevice: TapRenderState.maxLegs).states["a"],
                       .inert(reason: "too many adjusted apps"))
        for gated in [plan([boosted(device: "air")]), plan([boosted()], tapsEnabled: false)] {
            XCTAssertEqual(gated.ops, [])
        }
    }
}

// MARK: - The engine

@MainActor
final class BassBoostEngineTests: XCTestCase {

    private var hal: FakeTapHAL!
    private var engine: TapEngine!
    private var pending: [() -> Void] = []

    override func setUp() {
        super.setUp()
        hal = FakeTapHAL()
        pending = []
        engine = TapEngine(hal: hal, queue: nil,
                           schedule: { [weak self] _, block in
                               self?.pending.append(block)
                               return {}
                           },
                           notify: { block in block() })
        engine.setTapsEnabled(true, probing: false)
        hal.calls = []
    }

    private func firePending() {
        while !pending.isEmpty { pending.removeFirst()() }
    }

    private func desire(_ key: String = "com.example.app", position: Int = 100, bass: Int = 3,
                        pids: [pid_t] = [42]) -> TapDesire {
        TapDesire(key: key, position: position, isPlaying: true, pids: pids,
                  deviceUIDs: ["spk"], bass: bass)
    }

    private var render: TapRenderState? { hal.renders.values.first }

    func testEngagingSetsTheSlotsLevelAndStartsItClean() throws {
        engine.apply(desires: [desire(bass: 2)])
        let render = try XCTUnwrap(render)
        XCTAssertEqual(render.bassLevels[0], 2)
        XCTAssertNotEqual(render.generations[0], render.seenGenerations[0],
                          "the IO thread resets the slot's history at its first callback")
    }

    func testALevelChangeTouchesNoCoreAudioObject() throws {
        engine.apply(desires: [desire(bass: 3)])
        hal.calls = []
        engine.apply(desires: [desire(bass: 1)])
        XCTAssertEqual(hal.calls, [], "no tap, list edit or restart for a level change")
        XCTAssertEqual(try XCTUnwrap(render).bassLevels[0], 1)
    }

    /// Disengage hands back to the app's unboosted original: the filter
    /// goes as the unity ramp starts, well before the leg is removed.
    func testTurningOffFadesTheFilterOutBeforeRemoval() throws {
        engine.apply(desires: [desire(bass: 3)])
        let render = try XCTUnwrap(render)
        hal.calls = []
        engine.apply(desires: [desire(bass: 0)])
        XCTAssertEqual(render.bassLevels[0], 0, "the curve is off while the leg still renders")
        XCTAssertEqual(hal.calls, [], "removal waits for the ramp")
        firePending()
        XCTAssertTrue(hal.calls.contains(.destroyAggregate(102)))
    }

    /// Reset on teardown within a shared aggregate: the departing leg's slot
    /// is released, so whoever takes it next inherits nothing.
    func testALegLeavingASharedAggregateReleasesItsSlot() throws {
        engine.apply(desires: [desire(bass: 3), desire("org.other", position: 30, bass: 0, pids: [43])])
        let render = try XCTUnwrap(render)
        let before = render.generations[0]
        engine.apply(desires: [desire("org.other", position: 30, bass: 0, pids: [43])])
        firePending()
        XCTAssertEqual(render.bassLevels[0], 0)
        XCTAssertNotEqual(render.generations[0], before, "the slot changed hands")
        XCTAssertEqual(hal.renders.count, 1, "the other leg's aggregate lives on")
    }

    /// Reset on teardown of the whole aggregate: the next engage gets a new
    /// render state, so no history can survive it.
    func testTheNextAggregateStartsFromANewRenderState() throws {
        engine.apply(desires: [desire(bass: 3)])
        let first = try XCTUnwrap(render)
        engine.apply(desires: [desire(bass: 0)])
        firePending()
        engine.apply(desires: [desire(bass: 1)])
        let second = try XCTUnwrap(hal.renders.values.first { $0 !== first })
        XCTAssertEqual(second.bassLevels[0], 1)
    }

    func testARevivedLegTakesTheNewLevel() throws {
        engine.apply(desires: [desire(position: 50, bass: 3)])
        let render = try XCTUnwrap(render)
        engine.apply(desires: [desire(position: 100, bass: 0)])  // ramping out
        hal.calls = []
        engine.apply(desires: [desire(position: 50, bass: 2)])   // back before removal
        XCTAssertEqual(hal.calls, [], "revived in place")
        XCTAssertEqual(render.bassLevels[0], 2)
    }
}

// MARK: - The service

@MainActor
final class BassBoostServiceTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    /// Strong: the service holds the store weakly.
    private var store: SettingsStore!

    override func setUp() {
        super.setUp()
        // A scratch suite per test: the real settings are never touched.
        suiteName = "com.techie.Astraea.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SettingsStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    private func service() -> AppVolumeService {
        let service = AppVolumeService(source: StubAudioProcessSource(), resolve: { _ in nil },
                                       isAppRunning: { _ in false },
                                       logger: Logger(OSLog.disabled))
        service.settingsStore = store
        return service
    }

    private func row(_ key: String, neverTap: String? = nil) -> MixerRow {
        MixerRow(owner: AudioOwner(key: key, name: key, kind: .app, resolution: .ownApp),
                 pids: [7], isPlaying: true, neverTapReason: neverTap,
                 deviceUIDs: ["spk"], engineState: .notTapped)
    }

    func testALevelIsSavedPerAppAndOffIsAbsence() {
        let sut = service()
        sut.setBass(2, for: "com.hnc.Discord")
        XCTAssertEqual(store.settings.appVolume.bass, ["com.hnc.Discord": 2])
        XCTAssertEqual(sut.bass(for: "com.hnc.Discord"), 2)
        XCTAssertEqual(sut.bass(for: "org.chromium"), 0, "never boosted reads as off")
        sut.setBass(0, for: "com.hnc.Discord")
        XCTAssertNil(store.settings.appVolume.bass, "off is stored as absence")
        sut.setBass(5, for: "org.chromium")
        XCTAssertNil(store.settings.appVolume.bass, "an invalid level is off")
    }

    /// Spotify and Music reach the engine when boosted, at unity: their
    /// volume stays their own AppleScript `sound volume`.
    func testBoostedScriptedPlayersReachTheEngineAtUnity() {
        let levels = [SpotifyAdapter.bundleID: 3, "org.chromium": 1]
        let desires = AppVolumeService.desires(
            from: [row(SpotifyAdapter.bundleID), row(MusicAdapter.bundleID), row("org.chromium")],
            position: { _ in 30 },
            bass: { levels[$0] ?? 0 })
        XCTAssertEqual(desires.map(\.key), [SpotifyAdapter.bundleID, "org.chromium"],
                       "Music, neither routed nor boosted, stays AppleScript's alone")
        XCTAssertEqual(desires.first?.position, 100)
        XCTAssertEqual(desires.first?.bass, 3)
        XCTAssertNil(desires.first?.outputUID)
        XCTAssertEqual(desires.last?.position, 30)
        XCTAssertEqual(desires.last?.bass, 1)
    }

    func testANeverTapAppIsNeverBoosted() {
        let desires = AppVolumeService.desires(
            from: [row("com.finetuneapp.FineTune", neverTap: "audio mixer")],
            position: { _ in 100 }, bass: { _ in 3 })
        XCTAssertEqual(desires, [])
    }

    func testABoostedScriptedRowSaysWhyTheBoostIsNotWorking() {
        var r = row(SpotifyAdapter.bundleID)
        XCTAssertEqual(AppVolumeService.caption(for: r, scripted: true, tapsEnabled: false,
                                                route: .systemDefault, boosted: true),
                       "Bass boost needs taps on")
        r.engineState = .inert(reason: "AirPlay output")
        XCTAssertEqual(AppVolumeService.caption(for: r, scripted: true, tapsEnabled: true,
                                                route: .systemDefault, boosted: true),
                       "Can't boost — AirPlay output")
        XCTAssertEqual(AppVolumeService.caption(for: row(SpotifyAdapter.bundleID), scripted: true,
                                                tapsEnabled: false, route: .systemDefault),
                       "Playing", "an unboosted Spotify needs no taps")
    }
}
