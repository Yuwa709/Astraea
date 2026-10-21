// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import CoreGraphics

/// Turns a crop round the face into a `GlareSample`: one draw and one pass
/// over the pixels, cheap enough for every face frame. CoreGraphics only.
nonisolated enum GlareCueExtractor {
    /// Near-white and near-grey: a direct specular highlight, not a bright
    /// coloured surface.
    private static let specularLumaFloor: Float = 235
    private static let specularChromaTolerance: Float = 10
    /// Coarse on purpose: it only tells one blob from scattered points.
    private static let clusterGridSize = 8
    /// The crop reaches this far past the face box on every side (about
    /// 1.3x), so a screen's edge glare is inside it.
    static let cropMargin: CGFloat = 0.15

    /// The face box grown by `cropMargin` per side, clamped to the image and
    /// made whole pixels. Top-left pixel space, as `CGImage.cropping(to:)`
    /// takes it. nil when nothing of it is inside the image.
    static func cropRect(around faceBox: CGRect, imageSize: CGSize) -> CGRect? {
        let expanded = faceBox.insetBy(dx: -faceBox.width * cropMargin, dy: -faceBox.height * cropMargin)
        let clamped = expanded.intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// nil only if the crop could not be drawn. A crop too small to trust
    /// still yields a sample, which the cue discounts by its width.
    static func extract(faceCrop: CGImage) -> GlareSample? {
        let width = faceCrop.width
        let height = faceCrop.height
        guard width > 0, height > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(faceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        var gridCounts = [Int](repeating: 0, count: clusterGridSize * clusterGridSize)
        var specularTotal = 0
        data.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                let rowBase = y * width * 4
                let gridY = min(clusterGridSize - 1, y * clusterGridSize / height)
                for x in 0..<width {
                    let offset = rowBase + x * 4
                    let r = Float(bytes[offset])
                    let g = Float(bytes[offset + 1])
                    let b = Float(bytes[offset + 2])
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    guard luma >= specularLumaFloor else { continue }
                    let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                    let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
                    guard abs(cb - 128) <= specularChromaTolerance,
                          abs(cr - 128) <= specularChromaTolerance else { continue }
                    specularTotal += 1
                    let gridX = min(clusterGridSize - 1, x * clusterGridSize / width)
                    gridCounts[gridY * clusterGridSize + gridX] += 1
                }
            }
        }

        let largestCell = gridCounts.max() ?? 0
        return GlareSample(
            cropPixelWidth: CGFloat(width),
            specularFraction: Float(specularTotal) / Float(width * height),
            specularClusterRatio: specularTotal > 0 ? Float(largestCell) / Float(specularTotal) : 0)
    }
}
