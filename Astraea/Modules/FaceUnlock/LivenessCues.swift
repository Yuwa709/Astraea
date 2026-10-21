// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import CoreGraphics

// Light liveness, the camera-free half: what one face frame measured, and
// the maths that turns it into cue readings. No Vision, no camera, so every
// function here is a unit test. `GlareCueExtractor` and
// `DeviceBezelDetector` produce the measurements.

/// Light liveness's two deny cues. Each only ever argues "spoof"; neither
/// can prove a face is real.
nonisolated enum LivenessCue: String, CaseIterable, Sendable {
    /// One large, concentrated near-white highlight: glass or screen glare,
    /// not skin's small scattered shine.
    case glossGlare
    /// A phone- or tablet-shaped rectangle round the face.
    case deviceDetected

    var title: String {
        switch self {
        case .glossGlare: "glare"
        case .deviceDetected: "device rectangle"
        }
    }

    /// Why a match was refused, for the outcome line.
    var denialReason: String {
        switch self {
        case .glossGlare: "screen glare on the face"
        case .deviceDetected: "a phone- or tablet-shaped edge around the face"
        }
    }
}

/// One cue's reading for one frame. Confidence 0 is an abstention, never a
/// reading of zero: a cue that cannot see anything must not be able to
/// convict or acquit. Below `LivenessTuning.minimumConfidence` a reading
/// cannot acquit (the frame is neutral), and it convicts only when
/// `level * confidence` still clears the fire level.
nonisolated struct CueReading: Equatable, Sendable {
    /// 0...1 strength of the evidence for a spoof.
    let level: Float
    let confidence: Float

    static let none = CueReading(level: 0, confidence: 0)
}

/// The glare cue's pixel statistics over a crop round the face.
nonisolated struct GlareSample: Equatable, Sendable {
    /// Width of the measured crop in pixels. Below about 50 there is too
    /// little detail to tell a glare blob from a bright patch.
    let cropPixelWidth: CGFloat
    /// Share of the crop's pixels that are near-white and near-grey: direct
    /// specular reflection.
    let specularFraction: Float
    /// The densest cell of an 8x8 grid's share of those pixels: near 1 for
    /// one blob (glass), low for scattered points (skin).
    let specularClusterRatio: Float
}

/// The device cue's geometry: of the rectangles Vision found that are at
/// least the face box's size, the one that covers most of it.
nonisolated struct DeviceBezelSample: Equatable, Sendable {
    /// Share of the face box inside the rectangle, 0...1.
    let faceOverlap: CGFloat
    /// The rectangle's area over the face box's. Below
    /// `LivenessCues.minimumDeviceAreaRatio` the rectangle is not a device;
    /// above it, logged for tuning, since a phone held up is a few times
    /// the face while a doorway or monitor behind the user is far more.
    let areaRatio: CGFloat

    /// Vision ran and found no rectangle that could frame the face: a
    /// confident reading of zero, not an abstention. Only a Vision failure
    /// abstains (a nil sample).
    static let noDevice = DeviceBezelSample(faceOverlap: 0, areaRatio: 0)

    /// Whether this is a real rectangle rather than `noDevice`.
    var isRectangle: Bool { areaRatio > 0 }
}

/// What one face frame measured. A nil field abstains.
nonisolated struct LivenessSample: Equatable, Sendable {
    var glare: GlareSample?
    var device: DeviceBezelSample?

    static let none = LivenessSample()
}

nonisolated enum LivenessCues {

    static func readings(_ sample: LivenessSample) -> [LivenessCue: CueReading] {
        [.glossGlare: glossGlare(sample.glare), .deviceDetected: deviceDetected(sample.device)]
    }

    /// Skin gives many small scattered specular points; glass gives one big
    /// flat blob. The fraction alone would fire on a bright forehead, so it
    /// is weighted by how concentrated the glare is.
    static func glossGlare(_ glare: GlareSample?) -> CueReading {
        guard let glare else { return .none }
        let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
        let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
        let level = fractionScore * (0.3 + 0.7 * clusterFactor)
        // Full trust from about 130 px of crop.
        let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
        return CueReading(level: level, confidence: confidence)
    }

    /// The raw overlap, not re-scaled, at full confidence; `noDevice` reads
    /// zero. Only a nil sample (Vision failed) abstains.
    static func deviceDetected(_ device: DeviceBezelSample?) -> CueReading {
        guard let device else { return .none }
        return CueReading(level: Float(min(max(device.faceOverlap, 0), 1)), confidence: 1)
    }

    static func ramp(_ value: Float, floor: Float, ceiling: Float) -> Float {
        min(max((value - floor) / max(ceiling - floor, 0.0001), 0), 1)
    }

    /// Smallest rectangle, over the face box's area, that can count as a
    /// device: one that could frame the whole face. A glasses lens or a
    /// window pane behind the head is smaller, and on hardware a lens
    /// (0.2x to 0.4x the face) overlapped the face by 0.41, past the
    /// device level.
    static let minimumDeviceAreaRatio: CGFloat = 1

    /// Of the rectangles at least `minimumDeviceAreaRatio` times the face,
    /// the one that covers most of the face is taken to be the device; on a
    /// tie, the smaller one, as the more phone-like. Two deviations from
    /// Glance, which measured only the largest rectangle: a door, window or
    /// monitor behind the user could be that while a phone held in front
    /// went unseen; and rectangles smaller than the face are ignored. nil
    /// with no such rectangle or an empty face box. Both in the same pixel
    /// space.
    /// What `DeviceBezelDetector` reports for one frame. `rectangles` is
    /// nil when Vision threw: the cue abstains. A run that found nothing
    /// device-sized is `noDevice`, a confident zero, so a frame is never
    /// waved through only because the detector could not look. An empty
    /// face box abstains too: there is nothing to measure against.
    static func deviceSample(faceBox: CGRect, visionRectangles rectangles: [CGRect]?) -> DeviceBezelSample? {
        guard let rectangles, faceBox.width > 0, faceBox.height > 0 else { return nil }
        return deviceSample(faceBox: faceBox, rectangles: rectangles) ?? .noDevice
    }

    static func deviceSample(faceBox: CGRect, rectangles: [CGRect]) -> DeviceBezelSample? {
        let faceArea = faceBox.width * faceBox.height
        guard faceArea > 0 else { return nil }
        let samples = rectangles.map { rectangle in
            let intersection = rectangle.intersection(faceBox)
            let shared = intersection.isNull ? 0 : intersection.width * intersection.height
            return DeviceBezelSample(faceOverlap: shared / faceArea,
                                     areaRatio: rectangle.width * rectangle.height / faceArea)
        }
        return samples.filter { $0.areaRatio >= minimumDeviceAreaRatio }.max { lhs, rhs in
            lhs.faceOverlap != rhs.faceOverlap ? lhs.faceOverlap < rhs.faceOverlap : lhs.areaRatio > rhs.areaRatio
        }
    }
}
