// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Vision
import CoreGraphics

/// The face model needs faces warped into a canonical pose; a loose crop
/// tanks its accuracy. Only the 5-point path is accepted for enrolment, so
/// unlike Glance there is no 2-point or padded-crop fallback: a frame that
/// cannot be aligned is simply skipped.
///
/// The crop feeds `FaceEmbedder` and nothing else: liveness measures the
/// camera frame round the face box, not this crop.
nonisolated enum FaceAligner {
    /// face-reidentification-retail-0095's input side.
    static let outputSize = 128

    /// face-reidentification-retail-0095's 128x128 template, top-left
    /// origin: image-left eye, image-right eye, nose tip, image-left and
    /// image-right mouth corner. These are the points the model was
    /// benchmarked with (LFW 99.52%), derived from Vision's landmarks
    /// exactly as `fivePoints` does.
    static let referencePoints: [CGPoint] = [
        CGPoint(x: 40.393, y: 59.081),
        CGPoint(x: 87.376, y: 59.081),
        CGPoint(x: 64.034, y: 81.985),
        CGPoint(x: 44.732, y: 105.561),
        CGPoint(x: 83.640, y: 105.561),
    ]

    static func align(_ face: DetectedFace, from image: CGImage) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard let landmarks = face.landmarks,
              let points = fivePoints(from: landmarks, imageSize: imageSize) else { return nil }
        return warp(image, sourcePoints: points)
    }

    private static func fivePoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize),
              let nose = landmarks.nose, let noseCenter = centroid(of: nose, imageSize: imageSize),
              let outerLips = landmarks.outerLips else { return nil }
        return orderedFivePoints(eyeA: eyeA, eyeB: eyeB, nose: noseCenter,
                                 outerLips: imagePoints(of: outerLips, imageSize: imageSize))
    }

    /// The template's order from raw landmark points, top-left pixel space.
    /// Vision's left/right eye labels are anatomical, not on-screen, so the
    /// eyes are sorted by x; the mouth corners are the outer lips' extreme
    /// x points. nil without lip points.
    static func orderedFivePoints(eyeA: CGPoint, eyeB: CGPoint, nose: CGPoint, outerLips: [CGPoint]) -> [CGPoint]? {
        let imageLeftEye = eyeA.x <= eyeB.x ? eyeA : eyeB
        let imageRightEye = eyeA.x <= eyeB.x ? eyeB : eyeA
        guard let leftMouth = outerLips.min(by: { $0.x < $1.x }),
              let rightMouth = outerLips.max(by: { $0.x < $1.x }) else { return nil }
        return [imageLeftEye, imageRightEye, nose, leftMouth, rightMouth]
    }

    /// The transform `warp` draws with: from the source image's y-up space
    /// to the crop's y-up space. Points arrive top-left/y-down and are
    /// flipped before solving, since `CGContext` is y-up. The image itself
    /// needs no flip: `draw(_:in:)` already accounts for a CGImage's row
    /// order.
    static func alignmentTransform(sourcePoints: [CGPoint], imageHeight: CGFloat) -> CGAffineTransform? {
        let source = sourcePoints.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }
        let destination = referencePoints.map { CGPoint(x: $0.x, y: CGFloat(outputSize) - $0.y) }
        return solveSimilarityTransform(from: source, to: destination)
    }

    private static func warp(_ image: CGImage, sourcePoints: [CGPoint]) -> CGImage? {
        guard let transform = alignmentTransform(sourcePoints: sourcePoints,
                                                 imageHeight: CGFloat(image.height)) else { return nil }

        guard let context = CGContext(
            data: nil, width: outputSize, height: outputSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Geometry

    /// Vision's landmark points are bottom-left/y-up; flipped to top-left.
    static func imagePoints(of region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> [CGPoint] {
        region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
    }

    static func centroid(of region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> CGPoint? {
        let points = imagePoints(of: region, imageSize: imageSize)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// The pupil is a precise point; the eye outline's centroid is the fallback.
    static func eyeCenter(pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        if let pupil, let center = centroid(of: pupil, imageSize: imageSize) { return center }
        if let eye { return centroid(of: eye, imageSize: imageSize) }
        return nil
    }

    /// Closed-form least-squares similarity transform (rotation, uniform
    /// scale, translation): 2D Procrustes in complex-number form, no SVD.
    static func solveSimilarityTransform(from sourcePoints: [CGPoint], to destinationPoints: [CGPoint]) -> CGAffineTransform? {
        guard sourcePoints.count == destinationPoints.count, sourcePoints.count >= 2 else { return nil }

        let n = CGFloat(sourcePoints.count)
        let srcSum = sourcePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let dstSum = destinationPoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let srcMean = CGPoint(x: srcSum.x / n, y: srcSum.y / n)
        let dstMean = CGPoint(x: dstSum.x / n, y: dstSum.y / n)

        var numeratorReal: CGFloat = 0
        var numeratorImag: CGFloat = 0
        var denominator: CGFloat = 0
        for i in 0..<sourcePoints.count {
            let p = CGPoint(x: sourcePoints[i].x - srcMean.x, y: sourcePoints[i].y - srcMean.y)
            let q = CGPoint(x: destinationPoints[i].x - dstMean.x, y: destinationPoints[i].y - dstMean.y)
            // q * conj(p) = (qx*px + qy*py) + i(qy*px - qx*py)
            numeratorReal += q.x * p.x + q.y * p.y
            numeratorImag += q.y * p.x - q.x * p.y
            denominator += p.x * p.x + p.y * p.y
        }
        guard denominator > 0 else { return nil }

        // scale*cos(theta) and scale*sin(theta)
        let sc = numeratorReal / denominator
        let ss = numeratorImag / denominator
        let a = sc, b = ss, c = -ss, d = sc
        let tx = dstMean.x - (a * srcMean.x + c * srcMean.y)
        let ty = dstMean.y - (b * srcMean.x + d * srcMean.y)
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}
