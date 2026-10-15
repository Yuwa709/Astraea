import XCTest
@testable import PopNotch

/// The capture path needs a real audio stream and Screen Recording, so what
/// is tested here is the pure part: folding FFT bins into the bands a view
/// would draw.
final class AudioVisualizerBandTests: XCTestCase {

    private let bandCount = AudioVisualizerService.bandCount

    func testProducesExactlyTheRequestedBandCount() {
        let bins = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(AudioVisualizerService.fold(magnitudes: bins, into: bandCount).count, bandCount)
        XCTAssertEqual(AudioVisualizerService.fold(magnitudes: bins, into: 4).count, 4)
    }

    func testEmptyInputIsSafeAndSilent() {
        // A dropped or malformed buffer must yield silence, not a crash and
        // not stale bars.
        let bands = AudioVisualizerService.fold(magnitudes: [], into: bandCount)
        XCTAssertEqual(bands.count, bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 })
    }

    func testZeroBandsRequestedIsSafe() {
        XCTAssertTrue(AudioVisualizerService.fold(magnitudes: [1, 2, 3], into: 0).isEmpty)
    }

    func testSilenceFloorsAllBands() {
        // log10 of ~0 must clamp, not produce -inf or NaN in a view.
        let bands = AudioVisualizerService.fold(magnitudes: [Float](repeating: 0, count: 512),
                                                into: bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 == 0 }, "digital silence must read as zero")
        XCTAssertTrue(bands.allSatisfy { $0.isFinite }, "no -inf or NaN may reach the view")
    }

    func testEveryBandStaysInUnitRange() {
        // Deliberately absurd magnitudes: the view draws bar heights from
        // these, so anything outside 0...1 would overdraw the panel.
        let loud = [Float](repeating: 10_000, count: 512)
        let bands = AudioVisualizerService.fold(magnitudes: loud, into: bandCount)
        XCTAssertTrue(bands.allSatisfy { $0 >= 0 && $0 <= 1 }, "bands must be normalised")
    }

    func testBandsAreLogSpacedNotLinear() {
        // Energy only in the lowest bins must light the low bands and leave
        // the high ones dark. With linear spacing it would all land in band 0.
        //
        // Asserted on band dB rather than on bar heights: the folding is what
        // this test is about, and heights depend on dynamicWindow, so an
        // arbitrary synthetic magnitude would silently couple this to a
        // tuning constant. It did — the original used magnitude 1.0, which
        // sat inside a 45 dB window and outside a 35 dB one.
        var bins = [Float](repeating: 0, count: 512)
        for i in 0..<8 { bins[i] = 1 }
        let decibels = AudioVisualizerService.bandDecibels(magnitudes: bins, into: bandCount)
        XCTAssertTrue(decibels[0].isFinite, "low-frequency energy must reach the first band")
        XCTAssertGreaterThan(decibels[0], decibels[bandCount - 1] + 60,
                             "and must dwarf the top band, which sees nothing")

        // The bar heights still honour it once the signal is in range.
        let loud = bins.map { $0 * 1000 }
        let bands = AudioVisualizerService.fold(magnitudes: loud, into: bandCount)
        XCTAssertGreaterThan(bands[0], 0, "low-frequency energy must reach the first bar")
        XCTAssertEqual(bands[bandCount - 1], 0, "and must not leak into the top bar")
    }

    func testHighFrequencyEnergyLandsHigh() {
        var bins = [Float](repeating: 0, count: 512)
        for i in 480..<512 { bins[i] = 1 }
        let bands = AudioVisualizerService.fold(magnitudes: bins, into: bandCount)
        XCTAssertGreaterThan(bands[bandCount - 1], 0, "top bins must reach the top band")
        XCTAssertEqual(bands[0], 0, "and must not leak into the first band")
    }

    func testLouderInputGivesHigherBands() {
        let quiet = AudioVisualizerService.fold(magnitudes: [Float](repeating: 0.01, count: 512),
                                                into: bandCount)
        let loud = AudioVisualizerService.fold(magnitudes: [Float](repeating: 1.0, count: 512),
                                               into: bandCount)
        XCTAssertGreaterThan(loud[8], quiet[8], "the bands must actually track level")
    }
}

/// The adaptive ceiling. Loudly-mastered tracks measured ~20 dB above the
/// static references, which the old fixed mapping clipped flat — every band
/// at 1.0, a motionless brick.
final class AudioVisualizerGainTests: XCTestCase {

    private let bands = AudioVisualizerService.bandCount

    /// Band dB sitting a uniform `offset` above each band's own reference.
    private func decibels(offsetFromReference offset: Float) -> [Float] {
        (0..<bands).map { AudioVisualizerService.referenceDB[$0] + offset }
    }

    // MARK: - The bug

    func testLoudInputNoLongerPinsEveryBand() {
        // +20 dB over reference: the measured real-world case.
        let loud = decibels(offsetFromReference: 20)

        let fixed = AudioVisualizerService.normalize(bandDecibels: loud, gain: 0)
        XCTAssertTrue(fixed.allSatisfy { $0 == 1 },
                      "precondition: the static mapping clips this flat, which is the bug")

        let gain = AudioVisualizerService.updatedGain(current: 0, excess: 20)
        let adapted = AudioVisualizerService.normalize(bandDecibels: loud, gain: gain)
        XCTAssertTrue(adapted.allSatisfy { $0 < 1 }, "nothing may sit pinned at the ceiling")
        XCTAssertTrue(adapted.allSatisfy { $0 > 0.85 }, "but loud must still read as loud")
    }

    func testLoudInputStillShowsDynamics() {
        // The symptom was motionlessness: two different loud frames must
        // produce visibly different heights, not both 1.0.
        let gain = AudioVisualizerService.updatedGain(current: 0, excess: 20)
        let peak = AudioVisualizerService.normalize(bandDecibels: decibels(offsetFromReference: 20), gain: gain)
        let dip = AudioVisualizerService.normalize(bandDecibels: decibels(offsetFromReference: 8), gain: gain)
        XCTAssertGreaterThan(peak[0] - dip[0], 0.2, "a 12 dB dip must be visible as motion")
    }

    // MARK: - Quiet material stays visible

    /// Runs the release to convergence. Downward adaptation is deliberately
    /// slow, so anything asserting the settled state has to get there first.
    private func settled(from start: Float, excess: Float, seconds: Int = 20) -> Float {
        var gain = start
        for _ in 0..<(46 * seconds) {
            gain = AudioVisualizerService.updatedGain(current: gain, excess: excess)
        }
        return gain
    }

    func testQuietTrackIsLiftedNotHidden() {
        // A quiet master peaking 10 dB below reference must still fill the
        // bars, which is what stops this from being a global desensitising.
        let quiet = decibels(offsetFromReference: -10)
        let adapted = AudioVisualizerService.normalize(
            bandDecibels: quiet, gain: settled(from: 0, excess: -10))
        XCTAssertTrue(adapted.allSatisfy { $0 > 0.85 }, "quiet music must still reach near the top")
    }

    func testNearSilenceIsNotAmplifiedIntoNoise() {
        // The floor's whole job: gain must not keep climbing until room tone
        // lights the bars.
        // Exponential release asymptotes rather than arriving, so the
        // invariant is "approaches the floor and never passes it".
        let gain = settled(from: 0, excess: -80)
        XCTAssertEqual(gain, AudioVisualizerService.minimumGain, accuracy: 0.25)
        XCTAssertGreaterThanOrEqual(gain, AudioVisualizerService.minimumGain,
                                    "the floor is a floor: the ceiling never falls below it")
        let silence = [Float](repeating: -180, count: bands)
        XCTAssertTrue(AudioVisualizerService.normalize(bandDecibels: silence, gain: gain)
            .allSatisfy { $0 == 0 })
    }

    // MARK: - Attack and release

    func testCeilingRisesInstantly() {
        // A transient must never clip while the ceiling catches up.
        XCTAssertEqual(AudioVisualizerService.updatedGain(current: 0, excess: 20),
                       20 + AudioVisualizerService.peakHeadroom, accuracy: 0.001)
    }

    func testCeilingFallsSlowly() {
        // One frame of quiet must barely move it, or the bars pump.
        let after = AudioVisualizerService.updatedGain(current: 23, excess: -10)
        XCTAssertLessThan(after, 23)
        XCTAssertGreaterThan(after, 22.8, "a single frame must not collapse the ceiling")
    }

    func testCeilingConvergesAfterSustainedQuiet() {
        // ~4s time constant, so a few seconds is partial and a long stretch
        // arrives. Both halves matter: the first is what stops pumping, the
        // second is what stops a loud track permanently deafening the bars.
        let partway = settled(from: 23, excess: -10, seconds: 3)
        XCTAssertGreaterThan(partway, -7, "still descending after three seconds")
        XCTAssertLessThan(partway, 23, "but genuinely descending")

        let arrived = settled(from: 23, excess: -10, seconds: 20)
        XCTAssertEqual(arrived, -10 + AudioVisualizerService.peakHeadroom, accuracy: 0.5)
    }

    // MARK: - The static path is unchanged

    func testFoldStillMatchesTheStaticMapping() {
        // fold() is the zero-gain case, and eight existing tests depend on it.
        let magnitudes = [Float](repeating: 0.5, count: 512)
        XCTAssertEqual(AudioVisualizerService.fold(magnitudes: magnitudes, into: bands),
                       AudioVisualizerService.normalize(
                           bandDecibels: AudioVisualizerService.bandDecibels(
                               magnitudes: magnitudes, into: bands), gain: 0))
    }

    func testBandDecibelsHandlesEmptyInput() {
        XCTAssertEqual(AudioVisualizerService.bandDecibels(magnitudes: [], into: bands).count, bands)
        XCTAssertTrue(AudioVisualizerService.fold(magnitudes: [], into: bands).allSatisfy { $0 == 0 })
    }
}

/// Bar motion. The smoother sits between the analyser's raw bands and the
/// scrub bar, and is tuned for calm: a rise eases in, and a fall subsides more
/// slowly still. These pin that shape rather than exact curves, so the
/// constants can be retuned without rewriting the tests.
final class AudioVisualizerMotionTests: XCTestCase {

    private func smoothed(_ previous: Float, _ raw: Float) -> Float {
        AudioVisualizerService.smoothed(previous: previous, raw: raw)
    }

    /// Buffers until a step from `start` towards `target` covers `fraction`
    /// of its travel.
    private func buffersToCover(_ fraction: Float, from start: Float, to target: Float) -> Int {
        var value = start
        var count = 0
        while abs(value - start) < abs(target - start) * fraction && count < 1000 {
            value = smoothed(value, target)
            count += 1
        }
        return count
    }

    func testRiseEasesInRatherThanJumping() {
        let first = smoothed(0, 1)
        XCTAssertGreaterThan(first, 0, "a rise must start moving on its first buffer")
        XCTAssertLessThan(first, 0.5, "a transient must not snap most of the way up in one buffer")
    }

    /// At about 47 buffers a second: 90% within 3 buffers (~65ms) reads as a
    /// snap, and beyond 25 (~530ms) the bar lags the music it shows.
    func testRiseArrivesAsASwellNotAFlicker() {
        let buffers = buffersToCover(0.9, from: 0, to: 1)
        XCTAssertGreaterThan(buffers, 3, "a rise this fast still snaps")
        XCTAssertLessThan(buffers, 25, "a rise this slow lags the music")
    }

    func testFallIsSlowerThanRise() {
        XCTAssertGreaterThan(buffersToCover(0.9, from: 1, to: 0),
                             buffersToCover(0.9, from: 0, to: 1),
                             "a band that falls as fast as it rises reads as flicker")
    }

    /// Stepped only until the band arrives: past that the gap is smaller
    /// than a `Float` can resolve, `previous * keep + raw * (1 - keep)` rounds
    /// back to `previous`, and a strict increase would fail on a curve that
    /// had already landed.
    func testRiseIsMonotonicAndArrives() {
        var value: Float = 0
        var steps = 0
        while value < 0.99 && steps < 1000 {
            let next = smoothed(value, 1)
            XCTAssertGreaterThan(next, value, "a rise must never stall or reverse before it arrives")
            XCTAssertLessThanOrEqual(next, 1)
            value = next
            steps += 1
        }
        XCTAssertGreaterThanOrEqual(value, 0.99, "a bar must reach its level, not hang below it")
    }

    /// Stepped only until the band settles, for the same reason as the rise.
    func testFallIsMonotonicAndSettles() {
        var value: Float = 1
        var steps = 0
        while value > 0.01 && steps < 1000 {
            let next = smoothed(value, 0)
            XCTAssertLessThan(next, value, "a fall must never stall or reverse before it settles")
            XCTAssertGreaterThanOrEqual(next, 0)
            value = next
            steps += 1
        }
        XCTAssertLessThanOrEqual(value, 0.01, "a bar must reach the floor, not hang above it")
    }

    func testCoefficientsSmoothWithoutFreezing() {
        for keep in [AudioVisualizerService.barAttack, AudioVisualizerService.barRelease] {
            XCTAssertGreaterThan(keep, 0, "0 is no smoothing at all")
            XCTAssertLessThan(keep, 1, "1 would never move")
        }
    }

    func testSmoothingCannotPushABandOutOfRange() {
        // The smoother only ever interpolates between two in-range values, so
        // it cannot create a clipped band.
        for raw in [Float(0), 0.5, 1] {
            for previous in [Float(0), 0.5, 1] {
                let result = smoothed(previous, raw)
                XCTAssertGreaterThanOrEqual(result, 0)
                XCTAssertLessThanOrEqual(result, 1)
            }
        }
    }
}

/// Publish coalescing: the rate a steady stream of buffers reaches the main
/// actor at.
final class AudioVisualizerPublishRateTests: XCTestCase {

    /// Publishes per second over ten seconds of buffers of this duration,
    /// with alternating early and late arrival by `jitter`.
    private func publishRate(bufferDuration: TimeInterval, jitter: TimeInterval = 0) -> Double {
        var throttle = PublishThrottle(interval: AudioVisualizerService.publishInterval)
        var admitted = 0
        let buffers = Int((10 / bufferDuration).rounded())
        for index in 0..<buffers {
            let offset = index % 2 == 0 ? jitter : -jitter
            if throttle.admit(at: Double(index) * bufferDuration + offset) {
                admitted += 1
            }
        }
        return Double(admitted) / 10
    }

    func testRateLandsBetweenTwentyAndThirtyHertzAtCommonSampleRates() {
        for sampleRate in [44_100.0, 48_000.0, 88_200.0, 96_000.0] {
            let rate = publishRate(bufferDuration: 1024 / sampleRate)
            XCTAssertGreaterThanOrEqual(rate, 20, "too few publishes at \(sampleRate) Hz")
            XCTAssertLessThanOrEqual(rate, 30, "too many publishes at \(sampleRate) Hz")
        }
    }

    /// Two milliseconds early or late either side of 48kHz buffers must not
    /// change which buffers get through.
    func testJitterDoesNotWobbleTheRate() {
        let steady = publishRate(bufferDuration: 1024 / 48_000.0)
        let jittered = publishRate(bufferDuration: 1024 / 48_000.0, jitter: 0.002)
        XCTAssertEqual(jittered, steady, accuracy: 0.2)
    }

    func testFirstBufferPublishesImmediately() {
        var throttle = PublishThrottle(interval: AudioVisualizerService.publishInterval)
        XCTAssertTrue(throttle.admit(at: 123.4))
        XCTAssertFalse(throttle.admit(at: 123.41), "the next buffer 10ms later waits")
    }
}

/// Stands in for the system-audio tap: counts what the service asks of it and
/// makes no Core Audio call. It always starts, so a start that should not
/// have happened shows up as `isRunning`.
final class FakeAudioCapture: AudioCaptureEngine {
    private(set) var starts = 0
    private(set) var stops = 0
    /// What the service asked this engine to exclude when it made it.
    let excludedPIDs: [pid_t]
    var onInvalidated: (() -> Void)?

    init(excludedPIDs: [pid_t] = []) {
        self.excludedPIDs = excludedPIDs
    }

    func start() -> AudioCaptureStartResult {
        starts += 1
        return .success
    }

    func stop() {
        stops += 1
    }

    /// Stands in for coreaudiod restarting under a live capture.
    func simulateServiceRestart() {
        onInvalidated?()
    }
}

/// Off by default, and never running when nobody is looking.
@MainActor
final class AudioVisualizerLifecycleTests: XCTestCase {

    /// Every engine the service under test has made, oldest first.
    private var engines: [FakeAudioCapture] = []

    /// A service whose engines are fakes, so no test here can open a real
    /// system-audio tap, whatever conditions it sets.
    private func makeService() -> AudioVisualizerService {
        AudioVisualizerService(makeCapture: { excluded, _ in
            let engine = FakeAudioCapture(excludedPIDs: excluded)
            self.engines.append(engine)
            return engine
        })
    }

    func testOffByDefaultAndNotRunning() {
        let service = makeService()
        XCTAssertFalse(service.isEnabled, "capture must never start unasked")
        XCTAssertFalse(service.isRunning)
        XCTAssertNil(service.lastError)
    }

    func testBandsStartSilent() {
        let service = makeService()
        XCTAssertEqual(service.bands.count, AudioVisualizerService.bandCount)
        XCTAssertTrue(service.bands.allSatisfy { $0 == 0 })
    }

    func testEnablingWithoutAVisibleSpectrumDoesNotRun() {
        // Both conditions are required: enabled AND on screen.
        let service = makeService()
        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        XCTAssertFalse(service.isRunning, "a spectrum nobody can see must not capture audio")
    }

    func testDisablingClearsRunningState() {
        let service = makeService()
        service.setEnabled(true)
        service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isRunning)
    }

    func testSpectrumHiddenWhileEnabledStopsCapture() {
        let service = makeService()
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        service.setSpectrumVisible(false)
        XCTAssertFalse(service.isRunning)
    }

    // MARK: - Phase 6: excluding what the tap engine re-renders
    //
    // The tap excludes the processes PopNotch is muting and re-rendering, so
    // the spectrum carries our gain-adjusted copy rather than the app's
    // pre-mute stream. The set arrives from `TapEngine` through AppDelegate.

    private func runningService() -> AudioVisualizerService {
        let service = makeService()
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        service.setPlaying(true)
        return service
    }

    func testCaptureExcludesNothingWhenNothingIsTapped() {
        let service = runningService()
        XCTAssertTrue(service.isRunning)
        XCTAssertEqual(engines.last?.excludedPIDs, [], "nothing tapped, nothing excluded")
    }

    func testTappedProcessesReachTheTap() {
        let service = makeService()
        service.setTappedProcesses([852, 2942])
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        service.setPlaying(true)
        XCTAssertEqual(engines.last?.excludedPIDs, [852, 2942],
                       "a capture starting later must exclude what is already tapped")
    }

    func testTappedProcessesAreDeduplicatedAndSorted() {
        let service = makeService()
        service.setTappedProcesses([2942, 852, 2942])
        XCTAssertEqual(service.tappedPIDs, [852, 2942])
    }

    func testChangingTheTappedSetWhileCapturingRebuildsTheTap() {
        let service = runningService()
        XCTAssertEqual(engines.count, 1)

        service.setTappedProcesses([2942])

        XCTAssertEqual(engines.count, 2, "a tap's process list is fixed at creation")
        XCTAssertEqual(engines[0].stops, 1, "the stale tap is torn down")
        XCTAssertEqual(engines[1].excludedPIDs, [2942])
        XCTAssertTrue(service.isRunning)
    }

    func testRepeatingTheSameTappedSetDoesNotRebuild() {
        let service = runningService()
        service.setTappedProcesses([2942])
        service.setTappedProcesses([2942])
        XCTAssertEqual(engines.count, 2, "an unchanged set must not cost a rebuild")
    }

    func testChangingTheTappedSetWhileIdleStartsNothing() {
        let service = makeService()
        service.setEnabled(true)
        service.setTappedProcesses([2942])
        XCTAssertTrue(engines.isEmpty, "nobody is looking; the next start picks the list up")
        XCTAssertFalse(service.isRunning)
    }

    func testLegDisengagingRestoresTheAppToTheSpectrum() {
        let service = runningService()
        service.setTappedProcesses([2942])
        service.setTappedProcesses([])
        XCTAssertEqual(engines.count, 3)
        XCTAssertEqual(engines.last?.excludedPIDs, [],
                       "an app we no longer re-render is audible again, so it counts again")
    }

    // MARK: - Phase 6: coreaudiod restart

    func testServiceRestartRebuildsTheCapture() {
        let service = runningService()
        engines[0].simulateServiceRestart()
        XCTAssertEqual(engines.count, 2, "stale IDs cannot be reused")
        XCTAssertTrue(service.isRunning)
        XCTAssertNil(service.lastError)
    }

    func testServiceRestartKeepsTheExclusionList() {
        let service = makeService()
        service.setTappedProcesses([2942])
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        service.setPlaying(true)
        engines[0].simulateServiceRestart()
        XCTAssertEqual(engines.last?.excludedPIDs, [2942])
    }

    func testServiceRestartAfterCaptureStoppedStartsNothing() {
        let service = runningService()
        let engine = engines[0]
        service.setPlaying(false)
        XCTAssertFalse(service.isRunning)

        engine.simulateServiceRestart()

        XCTAssertEqual(engines.count, 1, "a restart must not resurrect a capture nobody wants")
        XCTAssertFalse(service.isRunning)
    }

    // MARK: - Playback gate
    //
    // The tap is whole-system, so it is gated on the tracked player. Without
    // this the bars would dance to a YouTube tab or a notification chime
    // while the notch showed a paused track.
    //
    // Every service here captures through fakes (`makeService`), so a test
    // may set all three conditions at once.

    func testEnabledAndVisibleButNotPlayingDoesNotCapture() {
        let service = makeService()
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        XCTAssertFalse(service.isRunning,
                       "nothing playing means no tap, however visible the spectrum is")
    }

    func testPlayingAloneDoesNotCapture() {
        // Playback is necessary, not sufficient: the spectrum must be on screen and
        // the feature enabled.
        let service = makeService()
        service.setPlaying(true)
        XCTAssertFalse(service.isRunning)
        XCTAssertFalse(service.isEnabled)
    }

    func testPlayingWithoutBeingEnabledDoesNotCapture() {
        let service = makeService()
        service.setSpectrumVisible(true)
        service.setPlaying(true)
        XCTAssertFalse(service.isRunning, "an off feature must never open a tap")
    }

    func testPauseAfterPlayingLeavesNothingRunning() {
        let service = makeService()
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        service.setPlaying(true)
        XCTAssertTrue(service.isRunning, "precondition: all three conditions start capture")
        XCTAssertEqual(engines.map(\.starts), [1], "one engine, started once")

        service.setPlaying(false)
        XCTAssertFalse(service.isRunning)
        XCTAssertEqual(engines.count, 1, "pausing must not make another engine")
        XCTAssertEqual(engines.map(\.stops), [1], "the engine that ran is stopped, once")
    }

    func testBandsRestAtSilentBaselineWhenNotPlaying() {
        // The view keeps drawing while enabled and healthy, so the zeroed
        // bands are what makes the bars rest rather than react.
        let service = makeService()
        service.setEnabled(true)
        service.setSpectrumVisible(true)
        service.setPlaying(false)
        XCTAssertTrue(service.bands.allSatisfy { $0 == 0 },
                      "silent baseline, not stale magnitudes")
    }
}
