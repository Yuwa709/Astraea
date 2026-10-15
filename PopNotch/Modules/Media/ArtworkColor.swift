import AppKit
import SwiftUI

/// Extracts a display accent from album artwork.
///
/// Downsamples to a small grid and histograms hue buckets, weighting each
/// pixel by saturation and brightness so vivid album colors beat large murky
/// backgrounds. Near-black, near-white, and gray pixels are excluded — the
/// accent must never be black (user rule) or invisible against the panel.
/// Returns nil for effectively colorless art; callers fall back to the fixed
/// peach.
enum ArtworkColor {

    static func dominant(in data: Data) -> Color? {
        guard let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let side = 24
        guard let context = CGContext(
            data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let pixels = context.data else { return nil }

        // 36 hue buckets; accumulate weight plus average saturation/brightness.
        var weight = [Double](repeating: 0, count: 36)
        var satSum = [Double](repeating: 0, count: 36)
        var briSum = [Double](repeating: 0, count: 36)
        var count = [Double](repeating: 0, count: 36)

        let buffer = pixels.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for i in stride(from: 0, to: side * side * 4, by: 4) {
            let r = Double(buffer[i]) / 255
            let g = Double(buffer[i + 1]) / 255
            let b = Double(buffer[i + 2]) / 255

            let maxC = max(r, g, b), minC = min(r, g, b)
            let brightness = maxC
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            // Exclude what cannot be an accent: near-black, near-white, gray.
            guard brightness > 0.18, brightness < 0.98 || saturation > 0.2,
                  saturation > 0.25 else { continue }

            let delta = maxC - minC
            var hue: Double
            if delta == 0 { hue = 0 }
            else if maxC == r { hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { hue = (b - r) / delta + 2 }
            else { hue = (r - g) / delta + 4 }
            hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)

            let bucket = min(35, Int(hue / 10))
            let w = saturation * brightness
            weight[bucket] += w
            satSum[bucket] += saturation
            briSum[bucket] += brightness
            count[bucket] += 1
        }

        guard let best = weight.indices.max(by: { weight[$0] < weight[$1] }),
              weight[best] > 0.5 // too few vivid pixels: colorless art
        else { return nil }

        let hue = (Double(best) * 10 + 5) / 360
        let saturation = min(1, satSum[best] / count[best])
        // Floor the brightness high: the accent sits on pure black, and the
        // user asked for deliberately brighter than the artwork's own tone
        // (dark-red covers were yielding a muddy bar).
        let brightness = max(0.78, min(1, briSum[best] / count[best]))
        return Color(hue: hue, saturation: saturation, brightness: brightness)
    }
}
