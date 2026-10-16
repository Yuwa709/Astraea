// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation
import CoreGraphics

/// One captured embedding. Camera frames are never stored, only this.
nonisolated struct FaceSample: Codable, Equatable, Sendable {
    let embedding: [Float]
    /// Which guided pose it came from (`EnrollmentPose.storageName`).
    let pose: String?
    let capturedAt: Date
    /// Vision's capture-quality score, 0...1.
    let quality: Float?
}

/// An enrolled person, or one look of a person (with glasses, say).
nonisolated struct FaceIdentity: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var samples: [FaceSample]
    /// The `FaceEmbedder.modelIdentifier` that produced the samples.
    var modelIdentifier: String
    var embeddingDimension: Int
    var createdAt: Date
    /// Off keeps the enrolment but excludes it from matching.
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, samples: [FaceSample],
         modelIdentifier: String = FaceEmbedder.modelIdentifier,
         embeddingDimension: Int = FaceEmbedder.embeddingDimension,
         createdAt: Date = Date(), isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.samples = samples
        self.modelIdentifier = modelIdentifier
        self.embeddingDimension = embeddingDimension
        self.createdAt = createdAt
        self.isEnabled = isEnabled
    }

    /// Hand-written so a missing `isEnabled` defaults to true: the whole
    /// file decodes as one array, so one throwing identity would lose all.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        samples = try container.decode([FaceSample].self, forKey: .samples)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        embeddingDimension = try container.decode(Int.self, forKey: .embeddingDimension)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// The averaged vector matching compares against.
    var template: [Float]? { FaceEmbedding.average(samples.map(\.embedding)) }

    /// True when the samples came from a different model than the bundled
    /// one (the 512-d ArcFace enrolments made before the switch to Intel's
    /// model, say). A stale
    /// identity is kept, shown as needing a recapture, and never compared.
    var isStale: Bool {
        modelIdentifier != FaceEmbedder.modelIdentifier || embeddingDimension != FaceEmbedder.embeddingDimension
    }
}

nonisolated struct ScoredIdentity: Sendable {
    let identity: FaceIdentity
    /// Against the averaged template.
    let centroidSimilarity: Float
    /// Against the single closest sample; catches poses averaging blurred.
    let maxSampleSimilarity: Float
}

/// Matching rules. Unused until the unlock phase, but they live with the
/// data they score, and the tests pin them now.
nonisolated enum FaceMatcher {

    /// Sorted best first. Stale identities are skipped, never scored: their
    /// vectors live in another model's space, often of another length, so
    /// any number would be meaningless. `bestMatch` refuses them as well.
    static func score(_ embedding: [Float], against identities: [FaceIdentity]) -> [ScoredIdentity] {
        identities.compactMap { identity in
            guard !identity.isStale, let template = identity.template, !identity.samples.isEmpty else { return nil }
            let centroid = FaceEmbedding.cosineSimilarity(embedding, template)
            let best = identity.samples.map { FaceEmbedding.cosineSimilarity(embedding, $0.embedding) }.max() ?? centroid
            return ScoredIdentity(identity: identity, centroidSimilarity: centroid, maxSampleSimilarity: best)
        }
        .sorted { $0.centroidSimilarity > $1.centroidSimilarity }
    }

    /// The top identity, only if it is current and clears the threshold on
    /// both measures. No runner-up margin: two looks of the same person
    /// legitimately score close together.
    static func bestMatch(in scored: [ScoredIdentity], threshold: Float) -> ScoredIdentity? {
        guard let first = scored.first, !first.identity.isStale else { return nil }
        guard first.centroidSimilarity >= threshold, first.maxSampleSimilarity >= threshold else { return nil }
        return first
    }
}

nonisolated struct FaceRecognitionResult: @unchecked Sendable {
    let embedding: [Float]
    let face: DetectedFace
}

/// Detect, align, embed. Holds the loaded model, so it is created when an
/// enrolment starts and released with it: the model is not resident while
/// nobody is enrolling.
nonisolated final class FaceRecognitionPipeline: Sendable {
    private let embedder: FaceEmbedder

    init() throws {
        embedder = try FaceEmbedder()
    }

    /// Aligns and embeds an already-chosen face. Nil when 5-point alignment
    /// is impossible, which enrolment treats as "not a usable frame".
    func recognize(_ face: DetectedFace, in frame: CGImage) throws -> FaceRecognitionResult? {
        guard let aligned = FaceAligner.align(face, from: frame) else { return nil }
        return FaceRecognitionResult(embedding: try embedder.embedding(for: aligned), face: face)
    }
}
