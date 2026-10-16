// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import CoreML
import CoreGraphics
import CoreVideo
import Foundation
import os

/// Vector maths shared by enrolment and (later) matching.
nonisolated enum FaceEmbedding {

    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    /// Cosine similarity, -1...1. Zero for empty or mismatched vectors.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    /// Normalize each vector, average, renormalize, so a larger-magnitude
    /// sample cannot dominate. Vectors of the wrong length are skipped and
    /// not counted (Glance counted them; harmless there, wrong here).
    static func average(_ vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first, !first.isEmpty else { return nil }
        let usable = vectors.filter { $0.count == first.count }
        var sum = [Float](repeating: 0, count: first.count)
        for vector in usable {
            let normalized = l2Normalized(vector)
            for i in 0..<normalized.count { sum[i] += normalized[i] }
        }
        return l2Normalized(sum.map { $0 / Float(usable.count) })
    }
}

enum FaceEmbedderError: LocalizedError {
    case modelNotFound
    case modelIntegrityFailed
    case modelLoadFailed(String)
    case pixelBufferCreationFailed
    case pixelBufferLockFailed(CVReturn)
    case pixelBufferBaseAddressMissing
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound: "The face model is missing from the app bundle."
        case .modelIntegrityFailed: "The face model in the app bundle has been changed. Reinstall PopNotch."
        case .modelLoadFailed(let detail): "The face model could not be loaded: \(detail)"
        case .pixelBufferCreationFailed: "The aligned face could not be prepared for the face model."
        case .pixelBufferLockFailed(let status): "The aligned face's buffer could not be locked (\(status))."
        case .pixelBufferBaseAddressMissing: "The aligned face's buffer has no memory to draw into."
        case .unexpectedOutput(let detail): "The face model returned an unexpected result: \(detail)"
        }
    }
}

/// Intel's face-reidentification-retail-0095 (Open Model Zoo, Apache-2.0),
/// converted to Core ML fp16 for PopNotch. It takes the 128x128 aligned face
/// as a BGR image and scales its own input, so the only Swift-side work is
/// drawing the face into a 32BGRA buffer (Core ML reorders the channels)
/// and L2-normalising the 256-float output, which the model leaves
/// unnormalised. See THIRD-PARTY-LICENSES.md.
nonisolated final class FaceEmbedder: @unchecked Sendable {

    /// Persisted with every sample. Embeddings from different models live in
    /// unrelated vector spaces, so a mismatch means re-enrol, never compare.
    static let modelIdentifier = "intel-face-reidentification-retail-0095-fp16-v1"
    static let embeddingDimension = 256

    /// The compiled model's name in the bundle, `<name>.mlmodelc`.
    static let resourceName = "FaceReidentification"
    static let inputName = "input_image"
    static let outputName = "embedding"
    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "FaceUnlock")

    // One model and one pool, loaded once: model load dominates inference.
    // `prediction(from:)` is synchronous; callers run this off the main actor.
    private let model: MLModel
    private let pixelBufferPool: CVPixelBufferPool

    init() throws {
        // Located and hashed once per launch; a model that fails the check
        // is never loaded.
        let url = try FaceModelIntegrity.verifiedBundledModel.get()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let started = ContinuousClock.now
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            Self.logger.error("Face model load failed: \(error.localizedDescription, privacy: .public)")
            throw FaceEmbedderError.modelLoadFailed(error.localizedDescription)
        }
        if let problem = FaceModelIntegrity.checkDescription(model.modelDescription, inputName: Self.inputName,
                                                             outputName: Self.outputName) {
            Self.logger.error("Face model failed its integrity check: \(problem, privacy: .public); not used")
            throw FaceEmbedderError.modelIntegrityFailed
        }
        guard let pool = Self.makePixelBufferPool(size: FaceAligner.outputSize) else {
            throw FaceEmbedderError.pixelBufferCreationFailed
        }
        pixelBufferPool = pool
        let elapsed = (ContinuousClock.now - started).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        Self.logger.notice("Face model loaded: \(Self.modelIdentifier, privacy: .public), \(Self.embeddingDimension, privacy: .public)-d embedding, \(FaceAligner.outputSize, privacy: .public) px input, \(milliseconds, format: .fixed(precision: 0), privacy: .public) ms")
    }

    func embedding(for alignedFace: CGImage) throws -> [Float] {
        var bufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &bufferOut)
        guard status == kCVReturnSuccess, let buffer = bufferOut else {
            throw FaceEmbedderError.pixelBufferCreationFailed
        }
        try Self.render(alignedFace, into: buffer)

        let input = try MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLFeatureValue(pixelBuffer: buffer)])
        let output = try model.prediction(from: input)
        guard let array = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw FaceEmbedderError.unexpectedOutput("no '\(Self.outputName)' output")
        }
        guard array.count == Self.embeddingDimension else {
            throw FaceEmbedderError.unexpectedOutput("\(array.count) values, expected \(Self.embeddingDimension)")
        }
        // Indexed through the array's own subscript: MLMultiArray storage
        // is not guaranteed to be flat and stride-1.
        let raw = (0..<array.count).map { array[$0].floatValue }
        return FaceEmbedding.l2Normalized(raw)
    }

    private static func makePixelBufferPool(size: Int) -> CVPixelBufferPool? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size,
            kCVPixelBufferHeightKey as String: size,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        return pool
    }

    /// Draws the aligned face into `buffer`. Throws rather than draw into a
    /// buffer it could not lock or that has no base address (a nil `data`
    /// would make Core Graphics draw into memory of its own, and the model
    /// would embed whatever the pooled buffer last held).
    static func render(_ image: CGImage, into buffer: CVPixelBuffer) throws {
        let lockStatus = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockStatus == kCVReturnSuccess else {
            throw FaceEmbedderError.pixelBufferLockFailed(lockStatus)
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw FaceEmbedderError.pixelBufferBaseAddressMissing
        }
        guard let context = CGContext(
            data: baseAddress,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FaceEmbedderError.pixelBufferCreationFailed
        }
        // Pooled buffers are recycled: without .copy, transparent edges of the
        // warped crop would keep the previous face's pixels.
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
}
