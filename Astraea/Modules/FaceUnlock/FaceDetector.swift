// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Vision
import CoreGraphics

/// One face Vision found in a frame. `@unchecked Sendable` because
/// `VNFaceLandmarks2D` is an immutable result object that is not annotated;
/// a face crosses from the detection task back to the main actor once.
nonisolated struct DetectedFace: @unchecked Sendable {
    /// Pixel-space box, top-left origin, ready to crop with.
    let boundingBox: CGRect
    /// Vision's own normalized, bottom-left-origin box.
    let normalizedBoundingBox: CGRect
    /// Vision's 0...1 capture-quality score, or nil if it produced none.
    let quality: Float?
    /// Head rotation in radians. Raw Vision signs on an unmirrored frame:
    /// +yaw is a turn to the user's left, +pitch is looking down.
    let yaw: Float?
    let pitch: Float?
    /// Feeds `FaceAligner`'s 5-point alignment ahead of the face model.
    let landmarks: VNFaceLandmarks2D?
    let imageSize: CGSize
}

/// Pure, synchronous, CPU-bound. `nonisolated` so it runs on a background
/// task despite the target's default main-actor isolation.
nonisolated enum FaceDetector {

    /// Face rectangles first; quality and landmarks only when there is a
    /// face. The second pass is chained through `inputFaceObservations`, so
    /// its results line up 1:1 by index with the rectangles.
    static func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([rectanglesRequest])
        let observations = rectanglesRequest.results ?? []
        guard !observations.isEmpty else { return [] }

        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        qualityRequest.inputFaceObservations = observations
        landmarksRequest.inputFaceObservations = observations
        try handler.perform([qualityRequest, landmarksRequest])

        let qualities = qualityRequest.results ?? []
        let landmarks = landmarksRequest.results ?? []
        let imageSize = CGSize(width: image.width, height: image.height)

        return observations.enumerated().map { index, observation in
            DetectedFace(
                boundingBox: convertToImageSpace(observation.boundingBox, imageSize: imageSize),
                normalizedBoundingBox: observation.boundingBox,
                quality: qualities.indices.contains(index) ? qualities[index].faceCaptureQuality : nil,
                yaw: observation.yaw?.floatValue,
                pitch: observation.pitch?.floatValue,
                landmarks: landmarks.indices.contains(index) ? landmarks[index].landmarks : nil,
                imageSize: imageSize
            )
        }
    }

    /// Vision's normalized rect is bottom-left origin; pixel crops want top-left.
    static func convertToImageSpace(_ normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let x = normalizedRect.origin.x * imageSize.width
        let y = (1 - normalizedRect.origin.y) * imageSize.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Largest face by area, with no size cutoff, so enrolment can tell
    /// "too far away" apart from "nobody there".
    static func largestFace(in faces: [DetectedFace]) -> DetectedFace? {
        faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
    }
}
