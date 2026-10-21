// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation

/// Fire levels and window sizes. Glance's levels, kept as the starting
/// point; Glance measured glare on native-resolution crops and Astraea
/// measures it on the 640 px frame, so retune from the `.notice` logs.
nonisolated struct LivenessTuning: Equatable, Sendable {
    var glossLevel: Float = 0.04
    /// Lower than `glossLevel` on purpose: in Glance's testing the rectangle
    /// detector was the one cue proven reliable on real devices.
    var deviceLevel: Float = 0.15
    /// A cue starts denying when it trips on `denyFrames` of the last
    /// `windowFrames` face frames, and keeps denying until it has tripped
    /// on none of the last `windowFrames`. Glance counted over the whole
    /// scan and latched; a Astraea scan runs up to 2 minutes, so three
    /// stray frames anywhere in it would lock the owner out until the next
    /// wake. The clean-window exit keeps a spoof that trips on most frames
    /// from slipping through between trips.
    var windowFrames = 5
    var denyFrames = 3
    /// A matched frame types only when it and the counted face frames just
    /// before it, `cleanFrames` in a row, were fully checked, tripped no
    /// cue, and were of a face near the threshold (`SimilarityBand`).
    /// Equal to `windowFrames`, so the run spans the whole deny window: a
    /// spoof that trips on 2 of every 5 frames, below `denyFrames`, never
    /// gets 5 clean frames in a row and never passes. Earlier frames need
    /// not have matched: on a strict threshold the owner's similarity
    /// hovers round the line, and requiring matches in a row took 15 to 25
    /// s on hardware. Glance passed on any 3 face frames.
    var cleanFrames = 5
    /// A cue reading below this confidence cannot vouch for a frame: if
    /// nothing tripped, the frame is neutral (it neither adds to nor resets
    /// the clean run, and stays out of the deny window). Glare reaches it
    /// at a 90 px crop; the device cue reads at 1 unless Vision failed.
    var minimumConfidence: Float = 0.5
    /// How far below the scan's threshold a face's similarity may sit and
    /// still count toward the clean run, and below which it is taken for a
    /// different person and resets the run. Between the two a face frame is
    /// neutral. Derived on face-reidentification-retail-0095's scale, not
    /// ArcFace's:
    /// - Owner: on the worst hardware wake (Strict, 0.76) the median was
    ///   0.681 and only 1 of 51 frames cleared 0.76; on LFW the presets
    ///   0.68/0.72/0.76 accept 84%/71%/51% of genuine pairs, a spread of
    ///   about 0.075. A 0.16 margin puts the count floor at 0.52/0.56/0.60,
    ///   0.08 under that worst median, so most of the owner's frames count
    ///   on every preset. ArcFace's 0.06 would have counted under half of
    ///   them on that wake.
    /// - Impostor: sd 0.098 on LFW; with 2 and 1 accepts in 3.6M at 0.68
    ///   and 0.76, a normal tail puts the mean near 0.20 (an upper bound:
    ///   real tails are heavier). The count floors sit 3.3/3.7/4.1 sd above
    ///   a stranger's mean, so a typical stranger never counts; the reset
    ///   floors, 0.38/0.42/0.46 (margin 0.30), sit 1.8/2.2/2.7 sd above it,
    ///   so most of a stranger's frames reset the run, and still 0.22 or
    ///   more under the owner's worst median.
    var identityCountMargin: Float = 0.16
    var identityResetMargin: Float = 0.30

    static let `default` = LivenessTuning()

    func level(for cue: LivenessCue) -> Float {
        switch cue {
        case .glossGlare: glossLevel
        case .deviceDetected: deviceLevel
        }
    }

    /// Weighted by confidence, so a reading at confidence 0.01 cannot trip
    /// at full strength. At confidence 1 the measured levels are unchanged.
    func trips(_ cue: LivenessCue, _ reading: CueReading) -> Bool {
        reading.confidence > 0 && reading.level * reading.confidence >= level(for: cue)
    }
}

/// Where a face's similarity to the top enrolled face sits against the
/// scan's threshold. Liveness counts `above` and `near` toward the clean
/// run, ignores `below`, and resets on `far` (another person). It is also
/// what the `.notice` logs and Settings show instead of the raw number: a
/// coarse band is neither a lasting record of scores nor an oracle to tune
/// a photo against.
nonisolated enum SimilarityBand: String, CaseIterable, Sendable {
    case above, near, below, far

    /// nil (no identity scored) is `far`.
    init(similarity: Float?, threshold: Float, tuning: LivenessTuning = .default) {
        guard let similarity else {
            self = .far
            return
        }
        if similarity >= threshold {
            self = .above
        } else if similarity >= threshold - tuning.identityCountMargin {
            self = .near
        } else if similarity >= threshold - tuning.identityResetMargin {
            self = .below
        } else {
            self = .far
        }
    }

    var title: String {
        switch self {
        case .above: "at or above the threshold"
        case .near: "close to the threshold"
        case .below: "below the threshold"
        case .far: "far below the threshold"
        }
    }
}

nonisolated enum LivenessDecision: Equatable, Sendable {
    /// This frame cannot type: it did not match, a cue tripped on it or on
    /// a face frame just before it, or too few clean frames of this face
    /// came first. Not a failure: the scan goes on.
    case pending
    /// This frame matched, and it and the counted face frames just before
    /// it, `cleanFrames` in a row, tripped no cue.
    case passed
    /// Blocks typing while it lasts. The scan goes on, and the denial
    /// clears once the cue has tripped on none of the last `windowFrames`
    /// face frames.
    case denied(LivenessCue)
}

/// Light liveness's decision, frame by frame, with no camera or Vision: fed
/// one `LivenessSample` per face frame, matched or not, so the deny cues
/// stay independent of the match. One evaluator per scan: nothing carries
/// over to the next.
nonisolated struct LivenessEvaluator: Sendable {
    let level: FaceLivenessLevel
    /// The scan's match threshold, for `SimilarityBand`.
    let threshold: Float
    let tuning: LivenessTuning
    /// The cues each recent checked face frame tripped, oldest first; at
    /// most `windowFrames`, or `cleanFrames` if that is more. A neutral
    /// frame is not added.
    private(set) var window: [Set<LivenessCue>] = []
    private(set) var faceFrames = 0
    /// Counted face frames in a row, up to the latest: fully checked, no
    /// cue tripped, similarity `above` or `near`. A trip or a `far` face
    /// resets it; a neutral frame, a `below` face or a frame with no face
    /// leaves it as it is.
    private(set) var cleanRun = 0
    /// Whether the latest face frame matched.
    private(set) var latestMatched = false
    /// Whether the latest face frame added to `cleanRun`: a match types
    /// only from a frame that was itself checked and clean.
    private(set) var latestCounted = false
    /// Whether the latest face frame was neutral: nothing tripped, and a
    /// cue was too unsure to vouch for it.
    private(set) var latestAbstained = false
    private(set) var latestBand: SimilarityBand = .far
    /// The cues the latest face frame tripped.
    private(set) var latestTrips: Set<LivenessCue> = []
    private(set) var latestReadings: [LivenessCue: CueReading] = [:]
    /// Cues denying now: entered at `denyFrames` trips in the window, left
    /// only at none.
    private(set) var denying: Set<LivenessCue> = []

    init(level: FaceLivenessLevel, threshold: Float, tuning: LivenessTuning = .default) {
        self.level = level
        self.threshold = threshold
        self.tuning = tuning
    }

    /// Off records nothing and always passes. `similarity` is the top
    /// identity's, nil when none scored; `matched` is the matcher's verdict
    /// on the same frame.
    @discardableResult
    mutating func observe(_ sample: LivenessSample, similarity: Float?, matched: Bool) -> LivenessDecision {
        guard level != .off else { return .passed }
        faceFrames += 1
        latestMatched = matched
        let readings = LivenessCues.readings(sample)
        latestReadings = readings
        let tripped = Set(LivenessCue.allCases.filter { tuning.trips($0, readings[$0] ?? .none) })
        let unsure = LivenessCue.allCases.contains { (readings[$0] ?? .none).confidence < tuning.minimumConfidence }
        latestTrips = tripped
        latestAbstained = tripped.isEmpty && unsure
        latestBand = SimilarityBand(similarity: similarity, threshold: threshold, tuning: tuning)
        latestCounted = false
        if !tripped.isEmpty {
            cleanRun = 0
        } else if !unsure {
            switch latestBand {
            case .above, .near:
                cleanRun += 1
                latestCounted = true
            case .below:
                break
            case .far:
                cleanRun = 0
            }
        }
        // A neutral frame is no evidence either way: kept out of the window
        // so it cannot push trips out of it and clear a denial early.
        if !latestAbstained {
            window.append(tripped)
            let capacity = max(tuning.windowFrames, tuning.cleanFrames)
            if window.count > capacity {
                window.removeFirst(window.count - capacity)
            }
        }
        for cue in LivenessCue.allCases {
            let count = trips(cue)
            if denying.contains(cue) {
                if count == 0 { denying.remove(cue) }
            } else if count >= tuning.denyFrames {
                denying.insert(cue)
            }
        }
        return decision
    }

    /// Frames among the last `windowFrames` on which `cue` tripped.
    func trips(_ cue: LivenessCue) -> Int {
        window.suffix(tuning.windowFrames).reduce(0) { $0 + ($1.contains(cue) ? 1 : 0) }
    }

    /// A deny wins over everything, including a pass already reached.
    var decision: LivenessDecision {
        guard level != .off else { return .passed }
        if let cue = LivenessCue.allCases.first(where: { denying.contains($0) }) {
            return .denied(cue)
        }
        return latestMatched && latestCounted && cleanRun >= tuning.cleanFrames ? .passed : .pending
    }
}

/// One scan's liveness numbers, for the scan-end `.notice` summary that
/// tuning works from.
nonisolated struct LivenessScanStats: Sendable {
    private(set) var faceFrames = 0
    private(set) var maxGlareLevel: Float = 0
    private(set) var glareAtMax: GlareSample?
    private(set) var deviceAtMax: DeviceBezelSample?
    /// Face frames on which each cue tripped, over the whole scan.
    private(set) var trips: [LivenessCue: Int] = [:]
    private(set) var totalSeconds: TimeInterval = 0
    private(set) var maxSeconds: TimeInterval = 0
    var denials = 0
    var blockedMatches = 0
    /// The cue that refused the latest blocked match.
    var lastBlockingCue: LivenessCue?

    mutating func record(_ sample: LivenessSample, tripped: Set<LivenessCue>, seconds: TimeInterval) {
        faceFrames += 1
        totalSeconds += seconds
        maxSeconds = max(maxSeconds, seconds)
        for cue in tripped { trips[cue, default: 0] += 1 }
        let glare = LivenessCues.glossGlare(sample.glare)
        if let measured = sample.glare, glareAtMax == nil || glare.level > maxGlareLevel {
            maxGlareLevel = glare.level
            glareAtMax = measured
        }
        if let device = sample.device, device.isRectangle, device.faceOverlap > (deviceAtMax?.faceOverlap ?? -1) {
            deviceAtMax = device
        }
    }

    var summary: String {
        let glare = glareAtMax.map {
            String(format: "max glare %.3f (specular %.4f, cluster %.2f, crop %.0f px)",
                   maxGlareLevel, $0.specularFraction, $0.specularClusterRatio, $0.cropPixelWidth)
        } ?? "no glare measured"
        let device = deviceAtMax.map {
            String(format: "max device overlap %.2f (rectangle %.1fx the face)", $0.faceOverlap, $0.areaRatio)
        } ?? "no face-sized rectangle"
        let tripped = LivenessCue.allCases.map { "\($0.title) \(trips[$0] ?? 0)" }.joined(separator: ", ")
        let mean = faceFrames > 0 ? totalSeconds / Double(faceFrames) : 0
        return "\(glare), \(device), face frames tripped: \(tripped), "
            + "\(denials) denials, \(blockedMatches) matches blocked, "
            + String(format: "measure %.1f ms mean / %.1f ms max", mean * 1000, maxSeconds * 1000)
    }
}
