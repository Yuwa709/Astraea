import XCTest
import CoreGraphics
@testable import PopNotch

/// Face Unlock phase 4, light liveness: the decision window, the cue maths
/// and the glare pixel counting. No camera, no Vision. The first group is
/// Glance's own self-test cases (`tools/liveness_selftest.swift`), ported to
/// the sliding window.
final class FaceUnlockLivenessTests: XCTestCase {

    /// A real face, both cues confident and clean.
    private let skin = FakeLivenessSampler.clean
    private let screenGlare = FakeLivenessSampler.screenGlare
    private let device25 = LivenessSample(glare: FakeLivenessSampler.skin.glare,
                                          device: DeviceBezelSample(faceOverlap: 0.25, areaRatio: 3))
    private let phone = LivenessSample(glare: FakeLivenessSampler.skin.glare,
                                       device: DeviceBezelSample(faceOverlap: 0.9, areaRatio: 3))
    /// The glare crop too narrow to trust, the device cue abstaining (Vision
    /// failed): neither cue can vouch for the frame.
    private let unsure = LivenessSample(glare: GlareSample(cropPixelWidth: 40, specularFraction: 0.2, specularClusterRatio: 1))

    /// Balanced. The count floor is 0.56, the reset floor 0.42.
    private static let threshold: Float = 0.72

    private func evaluator(_ level: FaceLivenessLevel = .light) -> LivenessEvaluator {
        LivenessEvaluator(level: level, threshold: Self.threshold)
    }

    private func run(_ samples: [LivenessSample], _ face: TestFace = .owner,
                     level: FaceLivenessLevel = .light) -> LivenessEvaluator {
        var evaluator = evaluator(level)
        for sample in samples { evaluator.observe(sample, face) }
        return evaluator
    }

    // MARK: - Glance's decision-model cases

    func testSustainedScreenGlareDenies() {
        XCTAssertEqual(run(Array(repeating: screenGlare, count: 8)).decision, .denied(.glossGlare))
    }

    func testModestButSustainedDeviceOverlapDenies() {
        XCTAssertEqual(run(Array(repeating: device25, count: 8)).decision, .denied(.deviceDetected))
    }

    func testASingleGlareFrameDoesNotDeny() {
        let evaluator = run([screenGlare] + Array(repeating: skin, count: 7))
        XCTAssertEqual(evaluator.decision, .passed)
    }

    func testLightPassesACleanFaceOnTheFifthFaceFrameNotBefore() {
        var evaluator = evaluator()
        XCTAssertEqual(evaluator.decision, .pending, "nothing seen yet")
        for frame in 1...4 {
            XCTAssertEqual(evaluator.observe(skin, .owner), .pending, "frame \(frame)")
        }
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed, "5 clean frames: the whole deny window")
    }

    func testADenialOverridesAPassAlreadyReached() {
        var evaluator = run(Array(repeating: skin, count: 5))
        XCTAssertEqual(evaluator.decision, .passed)
        XCTAssertEqual(evaluator.observe(phone, .owner), .pending, "a frame that trips cannot type")
        evaluator.observe(phone, .owner)
        XCTAssertTrue(evaluator.denying.isEmpty, "two trips are not yet a denial")
        XCTAssertEqual(evaluator.observe(phone, .owner), .denied(.deviceDetected))
    }

    func testEveryCueAbstainsWithNothingToRead() {
        let readings = LivenessCues.readings(.none)
        XCTAssertEqual(readings[.glossGlare], CueReading.none)
        XCTAssertEqual(readings[.deviceDetected], CueReading.none)
    }

    // MARK: - Abstention (review #3) and weak readings (#11)

    /// Frames no cue can vouch for must never add up to a pass, however
    /// many there are and however well they match.
    func testFramesNoCueCanVouchForNeverPass() {
        XCTAssertEqual(LivenessCues.glossGlare(unsure.glare).confidence, 0)
        var evaluator = evaluator()
        for _ in 0..<20 {
            XCTAssertEqual(evaluator.observe(unsure, .owner), .pending)
            XCTAssertEqual(evaluator.observe(LivenessSample.none, .owner), .pending)
        }
        XCTAssertEqual(evaluator.trips(.glossGlare), 0, "an abstention never trips")
        XCTAssertEqual(evaluator.cleanRun, 0)
        XCTAssertTrue(evaluator.latestAbstained)
        XCTAssertTrue(evaluator.window.isEmpty, "neutral frames stay out of the deny window")
    }

    /// One cue unsure is enough to make a frame neutral: it neither adds to
    /// the run nor resets it, and a match on it cannot type.
    func testAFrameWithOneCueUnsureIsNeutral() {
        var evaluator = run(Array(repeating: skin, count: 4))
        XCTAssertEqual(evaluator.cleanRun, 4)
        let deviceAbstains = FakeLivenessSampler.skin
        XCTAssertEqual(evaluator.observe(deviceAbstains, .owner), .pending, "Vision failed on this frame")
        XCTAssertEqual(evaluator.cleanRun, 4, "not reset either")
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed)
    }

    func testNeutralFramesCannotPushTripsOutOfTheWindow() {
        var evaluator = run(Array(repeating: screenGlare, count: 3))
        XCTAssertEqual(evaluator.decision, .denied(.glossGlare))
        for _ in 0..<10 { evaluator.observe(unsure, .owner) }
        XCTAssertEqual(evaluator.trips(.glossGlare), 3)
        XCTAssertEqual(evaluator.decision, .denied(.glossGlare))
    }

    /// Vision ran and found no rectangle: a confident zero, which lets a
    /// frame count. Only a Vision failure abstains.
    func testNoRectangleIsAConfidentZeroAndOnlyAVisionFailureAbstains() {
        XCTAssertEqual(LivenessCues.deviceDetected(.noDevice), CueReading(level: 0, confidence: 1))
        let face = CGRect(x: 100, y: 100, width: 100, height: 100)
        XCTAssertEqual(LivenessCues.deviceSample(faceBox: face, visionRectangles: []), .noDevice)
        let lens = CGRect(x: 110, y: 120, width: 60, height: 70)
        XCTAssertEqual(LivenessCues.deviceSample(faceBox: face, visionRectangles: [lens]), .noDevice,
                       "nothing device-sized is still a reading")
        XCTAssertNil(LivenessCues.deviceSample(faceBox: face, visionRectangles: nil), "Vision threw: abstain")
        XCTAssertNil(LivenessCues.deviceSample(faceBox: .zero, visionRectangles: []), "no face to measure against")
        let held = LivenessCues.deviceSample(faceBox: face, visionRectangles: [CGRect(x: 80, y: 60, width: 140, height: 200)])
        XCTAssertEqual(held?.faceOverlap ?? 0, 1, accuracy: 0.0001)
    }

    /// A trip is weighted by confidence: at 0.03 confidence even a strong
    /// glare reading does not trip, at 0.5 it still does, and at 1 the
    /// measured fire levels are unchanged.
    func testAReadingTripsByLevelTimesConfidence() {
        let tuning = LivenessTuning.default
        let barelySeen = LivenessCues.glossGlare(GlareSample(cropPixelWidth: 52, specularFraction: 0.09, specularClusterRatio: 0.75))
        XCTAssertEqual(barelySeen.confidence, 0.025, accuracy: 0.001)
        XCTAssertGreaterThan(barelySeen.level, tuning.glossLevel)
        XCTAssertFalse(tuning.trips(.glossGlare, barelySeen))
        let halfSeen = LivenessCues.glossGlare(GlareSample(cropPixelWidth: 90, specularFraction: 0.09, specularClusterRatio: 0.75))
        XCTAssertTrue(tuning.trips(.glossGlare, halfSeen))
        XCTAssertTrue(tuning.trips(.glossGlare, CueReading(level: 0.04, confidence: 1)))
        XCTAssertFalse(tuning.trips(.glossGlare, CueReading(level: 0.039, confidence: 1)))
        XCTAssertTrue(tuning.trips(.deviceDetected, CueReading(level: 0.15, confidence: 1)))
        XCTAssertFalse(tuning.trips(.deviceDetected, CueReading(level: 1, confidence: 0)))
    }

    // MARK: - The sliding window (PopNotch's deviation)

    func testDeniesOnThreeOfTheLastFiveEvenWithCleanFramesBetween() {
        XCTAssertEqual(run([screenGlare, skin, screenGlare, skin, screenGlare]).decision, .denied(.glossGlare))
    }

    func testTwoTripsInTheWindowDoNotDenyButDoNotPassEither() {
        let evaluator = run([screenGlare, screenGlare, skin, skin, skin])
        XCTAssertEqual(evaluator.trips(.glossGlare), 2)
        XCTAssertTrue(evaluator.denying.isEmpty)
        XCTAssertEqual(evaluator.decision, .pending, "3 clean frames are not the 5 needed")
    }

    /// Review #2: a spoof that trips on 2 of every 5 frames stays below the
    /// deny level, and under the old 3-frame rule passed on every third
    /// clean frame. It must never pass.
    func testASpoofTrippingOnTwoOfEveryFiveFramesNeverPasses() {
        var evaluator = evaluator()
        for cycle in 0..<12 {
            for sample in [screenGlare, screenGlare, skin, skin, skin] {
                XCTAssertNotEqual(evaluator.observe(sample, .owner), .passed, "cycle \(cycle)")
            }
        }
        XCTAssertTrue(evaluator.denying.isEmpty, "2 of 5 never reaches the deny level")
        evaluator.observe(skin, .owner)
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed, "the owner gets in once 5 clean frames come")
    }

    func testTripsOlderThanTheWindowAreForgotten() {
        // Three trips, but never three within any five frames.
        var evaluator = run([screenGlare, screenGlare, skin, skin, skin, screenGlare, skin, skin, skin])
        XCTAssertEqual(evaluator.window.count, 5)
        XCTAssertEqual(evaluator.trips(.glossGlare), 1)
        XCTAssertEqual(evaluator.decision, .pending)
        evaluator.observe(skin, .owner)
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed)
    }

    func testRecoversOnlyOnceTheWholeWindowIsClean() {
        var evaluator = run(Array(repeating: screenGlare, count: 3))
        XCTAssertEqual(evaluator.decision, .denied(.glossGlare))
        for clean in 1...4 {
            XCTAssertEqual(evaluator.observe(skin, .owner), .denied(.glossGlare),
                           "\(clean) clean: \(evaluator.trips(.glossGlare)) trips still in the window")
        }
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed, "5 clean frames: the owner gets back in")
    }

    /// Hysteresis: entering a denial takes 3 of 5, leaving it takes 0 of 5,
    /// so a spoof that trips on most frames cannot slip through between
    /// trips.
    func testADenialHoldsWhileOneOrTwoTripsRemain() {
        var evaluator = run(Array(repeating: screenGlare, count: 3) + [skin, skin, skin])
        XCTAssertEqual(evaluator.trips(.glossGlare), 2)
        XCTAssertEqual(evaluator.decision, .denied(.glossGlare), "2 of 5, below the entry level: still denied")
        for sample in [skin, screenGlare, skin, skin, screenGlare, skin] {
            evaluator.observe(sample, .owner)
            XCTAssertTrue((1...2).contains(evaluator.trips(.glossGlare)))
            XCTAssertEqual(evaluator.decision, .denied(.glossGlare), "a stray trip keeps it denied")
        }
        for _ in 0..<5 { evaluator.observe(skin, .owner) }
        XCTAssertEqual(evaluator.trips(.glossGlare), 0)
        XCTAssertEqual(evaluator.decision, .passed)
    }

    func testATripOnAnyOfTheLastFiveFaceFramesHoldsAMatch() {
        var evaluator = run(Array(repeating: skin, count: 4))
        XCTAssertEqual(evaluator.observe(screenGlare, .owner), .pending, "the matching frame itself tripped")
        for back in 1...4 {
            XCTAssertEqual(evaluator.observe(skin, .owner), .pending, "\(back) frames back")
        }
        XCTAssertEqual(evaluator.trips(.glossGlare), 1, "one trip: never a denial")
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed, "five clean frames")
    }

    // MARK: - The clean run is bound to the face (review #2)

    /// On a strict threshold the owner's similarity hovers round the line:
    /// near misses count toward the run, so the first match after them
    /// types at once.
    func testTheOwnersNearMissesCountTowardTheRun() {
        var evaluator = evaluator()
        for _ in 0..<4 {
            XCTAssertEqual(evaluator.observe(skin, .nearMiss), .pending, "a face that did not match cannot type")
        }
        XCTAssertEqual(evaluator.cleanRun, 4)
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed)
        XCTAssertEqual(evaluator.observe(skin, .nearMiss), .pending)
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed, "nor does a near miss reset anything")
        XCTAssertEqual(evaluator.cleanRun, 7)
    }

    /// The priming attack: someone else's clean face, then the owner's
    /// photo held so that it trips nothing. The stranger's frames must not
    /// vouch for the photo's first match.
    func testAStrangersCleanFramesDoNotPrimeAMatchThatTripsNothing() {
        var evaluator = run(Array(repeating: skin, count: 5), .stranger)
        XCTAssertEqual(evaluator.cleanRun, 0, "a far face never counts")
        XCTAssertEqual(evaluator.observe(skin, .owner), .pending, "the photo's first clean match")
        XCTAssertEqual(evaluator.cleanRun, 1)
        for _ in 0..<3 { XCTAssertEqual(evaluator.observe(skin, .owner), .pending) }
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed, "only its own 5 clean frames let it through")
    }

    func testAFarFaceResetsTheRun() {
        var evaluator = run(Array(repeating: skin, count: 4))
        evaluator.observe(skin, .stranger)
        XCTAssertEqual(evaluator.cleanRun, 0)
        XCTAssertEqual(evaluator.observe(skin, .owner), .pending)
    }

    func testALookalikeBetweenTheFloorsNeitherCountsNorResets() {
        var evaluator = run(Array(repeating: skin, count: 4))
        evaluator.observe(skin, .lookalike)
        XCTAssertEqual(evaluator.cleanRun, 4)
        XCTAssertEqual(evaluator.observe(skin, .owner), .passed)
    }

    /// The old pinned case still holds: a phone held up after someone
    /// else's clean face trips the device cue itself.
    func testAPhoneAfterAStrangersCleanFaceIsDenied() {
        var evaluator = run(Array(repeating: skin, count: 5), .stranger)
        XCTAssertEqual(evaluator.observe(phone, .owner), .pending)
        XCTAssertEqual(evaluator.observe(phone, .owner), .pending)
        XCTAssertEqual(evaluator.observe(phone, .owner), .denied(.deviceDetected))
    }

    func testFacesThatDoNotMatchStillFeedTheDenyWindow() {
        XCTAssertEqual(run(Array(repeating: screenGlare, count: 3), .stranger).decision, .denied(.glossGlare))
    }

    /// One evaluator per scan: the next scan's starts with nothing denied.
    func testADenialDoesNotCarryOverToTheNextScansEvaluator() {
        XCTAssertEqual(run(Array(repeating: screenGlare, count: 5)).decision, .denied(.glossGlare))
        XCTAssertEqual(run(Array(repeating: skin, count: 5)).decision, .passed)
    }

    func testSimilarityBandsOnEachPreset() {
        func band(_ similarity: Float?, _ preset: FaceMatchThreshold) -> SimilarityBand {
            SimilarityBand(similarity: similarity, threshold: preset.value)
        }
        // Count floors 0.52 / 0.56 / 0.60; reset floors 0.38 / 0.42 / 0.46.
        XCTAssertEqual(band(0.76, .strict), .above)
        XCTAssertEqual(band(0.681, .strict), .near, "the owner's median on the worst hardware wake counts")
        XCTAssertEqual(band(0.601, .strict), .near)
        XCTAssertEqual(band(0.59, .strict), .below)
        XCTAssertEqual(band(0.461, .strict), .below)
        XCTAssertEqual(band(0.45, .strict), .far)
        XCTAssertEqual(band(0.53, .lenient), .near)
        XCTAssertEqual(band(0.51, .lenient), .below)
        XCTAssertEqual(band(0.37, .lenient), .far)
        XCTAssertEqual(band(0.20, .balanced), .far, "a typical stranger")
        XCTAssertEqual(band(nil, .balanced), .far, "nothing scored")
    }

    func testOffAlwaysPassesAndRecordsNothing() {
        var evaluator = evaluator(.off)
        XCTAssertEqual(evaluator.decision, .passed, "before any frame: a match types at once, as before phase 4")
        for _ in 0..<5 { XCTAssertEqual(evaluator.observe(screenGlare, .owner), .passed) }
        XCTAssertEqual(evaluator.faceFrames, 0)
        XCTAssertTrue(evaluator.window.isEmpty)
    }

    // MARK: - Cue maths

    func testRamp() {
        XCTAssertEqual(LivenessCues.ramp(0, floor: 10, ceiling: 20), 0)
        XCTAssertEqual(LivenessCues.ramp(15, floor: 10, ceiling: 20), 0.5, accuracy: 0.0001)
        XCTAssertEqual(LivenessCues.ramp(30, floor: 10, ceiling: 20), 1)
    }

    func testGlareReadingsForGlancesSkinAndScreenSamples() {
        XCTAssertEqual(LivenessCues.glossGlare(skin.glare).level, 0, "under 1% specular is nothing")
        let screen = LivenessCues.glossGlare(screenGlare.glare)
        XCTAssertEqual(screen.level, 0.3 + 0.7 * (0.45 / 0.7), accuracy: 0.001)
        XCTAssertEqual(screen.confidence, 1)
        XCTAssertGreaterThanOrEqual(screen.level, LivenessTuning.default.glossLevel)
    }

    func testGlareConfidenceRampsWithCropWidth() {
        func confidence(_ width: CGFloat) -> Float {
            LivenessCues.glossGlare(GlareSample(cropPixelWidth: width, specularFraction: 0.05, specularClusterRatio: 1)).confidence
        }
        XCTAssertEqual(confidence(50), 0)
        XCTAssertEqual(confidence(90), 0.5, accuracy: 0.001)
        XCTAssertEqual(confidence(200), 1)
    }

    func testDeviceReadingIsTheOverlapClamped() {
        XCTAssertEqual(LivenessCues.deviceDetected(DeviceBezelSample(faceOverlap: 0.6, areaRatio: 2)),
                       CueReading(level: 0.6, confidence: 1))
        XCTAssertEqual(LivenessCues.deviceDetected(DeviceBezelSample(faceOverlap: 1.2, areaRatio: 2)).level, 1)
        XCTAssertEqual(LivenessCues.deviceDetected(nil), CueReading.none, "a Vision failure abstains")
    }

    func testScanStatsKeepTheStrongestReadingsAndCountTrips() {
        var stats = LivenessScanStats()
        stats.record(skin, tripped: [], seconds: 0.002)
        stats.record(screenGlare, tripped: [.glossGlare], seconds: 0.004)
        stats.record(device25, tripped: [.deviceDetected], seconds: 0.003)
        stats.record(screenGlare, tripped: [.glossGlare], seconds: 0.001)
        XCTAssertEqual(stats.faceFrames, 4)
        XCTAssertEqual(stats.glareAtMax, screenGlare.glare)
        XCTAssertEqual(stats.deviceAtMax?.faceOverlap, 0.25)
        XCTAssertEqual(stats.maxSeconds, 0.004, accuracy: 0.0001)
        XCTAssertEqual(stats.trips, [.glossGlare: 2, .deviceDetected: 1])
        XCTAssertTrue(stats.summary.contains("face frames tripped: glare 2, device rectangle 1"), stats.summary)
    }

    func testScanStatsDoNotReportNoRectangleAsADevice() {
        var stats = LivenessScanStats()
        stats.record(skin, tripped: [], seconds: 0.002)
        XCTAssertNil(stats.deviceAtMax)
        XCTAssertTrue(stats.summary.contains("no face-sized rectangle"), stats.summary)
    }

    // MARK: - Scan frame numbers

    func testScanFrameStatsCountMatchesAndTimeTheFirst() {
        var stats = ScanFrameStats(threshold: 0.68)
        for _ in 0..<5 { stats.recordChecked(recognitionSeconds: 0.1) }
        stats.recordFace(similarity: 0.60, matched: false, after: 1.0)
        stats.recordFace(similarity: 0.70, matched: true, after: 1.5)
        stats.recordFace(similarity: nil, matched: false, after: 2.0)
        stats.recordFace(similarity: 0.69, matched: true, after: 2.5)
        XCTAssertEqual(stats.checkedFrames, 5)
        XCTAssertEqual(stats.faceFrames, 4)
        XCTAssertEqual(stats.matchedFrames, 2)
        XCTAssertEqual(stats.firstMatchAfter, 1.5)
        XCTAssertEqual(stats.similarities, [0.60, 0.70, 0.69], "a face that scored nothing adds no similarity")
        XCTAssertEqual(stats.bestBand, .above)
        let summary = stats.summary(elapsed: 2)
        XCTAssertTrue(summary.contains("4 face of 5 checked frames in 2.0 s (2.00 face/s, 2.50 checked/s)"), summary)
        XCTAssertTrue(summary.contains("2 matched (first after 1.50 s)"), summary)
        XCTAssertTrue(summary.contains("similarity bands 2 above, 1 near, 0 below, 0 far"), summary)
        XCTAssertTrue(summary.contains("recognition 100.0 ms mean"), summary)
        XCTAssertTrue(stats.similarityDetail.contains("similarity min 0.600 / median 0.690 / max 0.700"), stats.similarityDetail)
    }

    /// L6: the `.notice` summary carries no raw score.
    func testTheSummaryHoldsNoRawSimilarity() {
        var stats = ScanFrameStats(threshold: 0.72)
        stats.recordFace(similarity: 0.7345, matched: true, after: 1)
        stats.recordFace(similarity: 0.6123, matched: false, after: 1)
        let summary = stats.summary(elapsed: 1)
        for raw in ["0.73", "0.734", "0.61", "0.612"] {
            XCTAssertFalse(summary.contains(raw), "\(raw) in \(summary)")
        }
    }

    func testScanFrameStatsWithNothingSeen() {
        let stats = ScanFrameStats(threshold: 0.72)
        let summary = stats.summary(elapsed: 0)
        XCTAssertTrue(summary.contains("0 matched (none)"), summary)
        XCTAssertTrue(summary.contains("no similarity"), summary)
        XCTAssertNil(stats.bestBand)
    }

    func testMedian() throws {
        XCTAssertNil(ScanFrameStats.median([]))
        XCTAssertEqual(ScanFrameStats.median([0.3, 0.1, 0.2]), 0.2)
        XCTAssertEqual(try XCTUnwrap(ScanFrameStats.median([0.4, 0.1, 0.2, 0.3])), 0.25, accuracy: 0.0001)
    }
}

/// Who is in front of the camera, by similarity to the enrolled face.
private enum TestFace {
    /// Matches.
    case owner
    /// The owner below the line on this frame: counts, cannot type.
    case nearMiss
    /// Under the count floor, over the reset floor: neutral.
    case lookalike
    /// Someone else: resets the clean run.
    case stranger

    var similarity: Float {
        switch self {
        case .owner: 0.80
        case .nearMiss: 0.66
        case .lookalike: 0.50
        case .stranger: 0.20
        }
    }
    var matched: Bool { self == .owner }
}

/// Similarities against a balanced threshold (0.72): the count floor is
/// 0.56, the reset floor 0.42.
private extension LivenessEvaluator {
    @discardableResult
    mutating func observe(_ sample: LivenessSample, _ face: TestFace) -> LivenessDecision {
        observe(sample, similarity: face.similarity, matched: face.matched)
    }
}
