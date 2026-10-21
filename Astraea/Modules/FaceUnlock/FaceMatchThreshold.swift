import Foundation

/// How strict lock-screen matching is. Stored in `AppSettings` by name, so
/// the numbers can be retuned without a migration.
///
/// Both of `FaceMatcher.bestMatch`'s measures (the averaged template and the
/// closest single sample) must clear the value.
nonisolated enum FaceMatchThreshold: String, Codable, CaseIterable, Identifiable, Sendable {
    case lenient
    case balanced
    case strict

    static let `default`: FaceMatchThreshold = .balanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lenient: "Lenient"
        case .balanced: "Balanced"
        case .strict: "Strict"
        }
    }

    /// Cosine similarity an enrolled face must reach, on
    /// face-reidentification-retail-0095's scale. Starting values, to be
    /// tuned on hardware. On LFW with the app's rule (5 enrolment samples,
    /// centroid and closest sample both clear), genuine accepts and
    /// impostor accepts out of 3.6M: 0.68 84%/2, 0.72 71%/1, 0.76 51%/1.
    /// ArcFace's old 0.58/0.63/0.68 do not carry over: Intel's impostor
    /// scores spread wider (sd 0.098 against 0.069).
    var value: Float {
        switch self {
        case .lenient: 0.68
        case .balanced: 0.72
        case .strict: 0.76
        }
    }

    /// Accepts faces `other` would refuse: changing to it needs a fresh
    /// owner check (`FaceUnlockSession.reauthenticate(reason:)`).
    func isWeaker(than other: FaceMatchThreshold) -> Bool { value < other.value }
}
