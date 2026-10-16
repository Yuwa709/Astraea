// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Vision
import CoreGraphics

/// Looks for a phone or tablet bezel round the face with Vision's rectangle
/// detector. Only ever evidence of a spoof, never of a live face. The
/// overlap maths is `LivenessCues.deviceSample`, tested without Vision.
nonisolated enum DeviceBezelDetector {

    /// Glance's first-pass values, not yet checked against PopNotch's
    /// frames. A doorway, window or monitor behind the user is the likely
    /// false reject; the logged area ratio is there to tune it.
    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // A share of the image's smaller side.
        request.minimumSize = 0.15
        // Glance asked for 3. More, since every candidate's overlap is now
        // measured and a background rectangle must not crowd out a phone.
        request.maximumObservations = 8
        // Short side over long: a portrait phone (0.35) to a square crop.
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.0
        // Generous, so a phone held at a slight angle still registers.
        request.quadratureTolerance = 30
        return request
    }

    /// Synchronous and CPU-bound: call off the main actor. `faceBox` is in
    /// `image`'s top-left pixel space. `DeviceBezelSample.noDevice` when
    /// Vision ran and found no rectangle at least the face's size; nil, an
    /// abstention, only when Vision threw (or the face box is empty).
    static func detect(in image: CGImage, faceBox: CGRect) -> DeviceBezelSample? {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let rectangles: [CGRect]?
        do {
            try handler.perform([request])
            let imageSize = CGSize(width: image.width, height: image.height)
            rectangles = (request.results ?? []).map {
                FaceDetector.convertToImageSpace($0.boundingBox, imageSize: imageSize)
            }
        } catch {
            rectangles = nil
        }
        return LivenessCues.deviceSample(faceBox: faceBox, visionRectangles: rectangles)
    }
}
