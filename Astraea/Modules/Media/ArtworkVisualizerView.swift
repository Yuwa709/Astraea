import SwiftUI
import AppKit
import CoreImage

/// Colours sampled from album artwork, used to light the notch behind it.
///
/// Three samples rather than one: a single average is usually mud, while
/// opposite corners give the ambient glow a direction that matches the art.
struct ArtworkPalette: Equatable {
    let overall: Color
    let leading: Color
    let trailing: Color
}

/// Palette extraction via Core Image's `CIAreaAverage`, which reduces a
/// region to a single pixel on the GPU — far cheaper than walking bytes.
///
/// Entirely local: no network, no external services.
enum ArtworkPaletteExtractor {

    /// One shared context. Constructing a `CIContext` per call is expensive
    /// enough to show up on a track change.
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// From the artwork's own bytes, so there is no NSImage -> TIFF round
    /// trip. Called once per artwork change by `MediaModule`, never from a
    /// view's appear.
    static func palette(from data: Data) -> ArtworkPalette? {
        guard let ciImage = CIImage(data: data) else { return nil }

        let extent = ciImage.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        // Opposite halves, plus the whole frame for the base tone.
        let leadingRect = CGRect(x: extent.minX, y: extent.minY,
                                 width: extent.width / 2, height: extent.height)
        let trailingRect = CGRect(x: extent.midX, y: extent.minY,
                                  width: extent.width / 2, height: extent.height)

        guard let overall = average(ciImage, in: extent),
              let leading = average(ciImage, in: leadingRect),
              let trailing = average(ciImage, in: trailingRect) else { return nil }

        return ArtworkPalette(
            overall: lift(overall),
            leading: lift(leading),
            trailing: lift(trailing)
        )
    }

    /// Average colour of one region, rendered down to a single RGBA pixel.
    private static func average(_ image: CIImage, in rect: CGRect) -> NSColor? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect)
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return NSColor(
            srgbRed: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }

    /// Averaging desaturates and darkens. Glow that sits on a pure-black
    /// panel needs help to read at all, so saturation and brightness get a
    /// floor — the same reasoning as the accent colour extractor.
    private static func lift(_ color: NSColor) -> Color {
        guard let rgb = color.usingColorSpace(.sRGB) else { return Color(color) }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(
            hue: Double(hue),
            saturation: Double(min(1, max(0.35, saturation * 1.4))),
            brightness: Double(min(1, max(0.45, brightness * 1.25)))
        )
    }
}

/// Album artwork as an ambient centrepiece: a slow Ken Burns pan-and-zoom,
/// a palette-driven glow behind it, and a parallax tilt that follows the
/// cursor across the panel.
///
/// Motion notes, learned the hard way in this project:
/// - Driven by a repeating animation rather than a per-frame
///   `TimelineView`. The notch panel can never become key (hard rule 3),
///   and SwiftUI throttles per-frame animation callbacks in non-key
///   windows — that produced visible stutter in the waveform. A
///   `repeatForever` SwiftUI animation does **not** run in the render
///   server: it is ticked in-process on the main thread every display
///   refresh while it runs (profiled, PROJECT-CONTEXT.md, the wing-waveform
///   CPU incident). It costs CPU while playing, which is why it must stop,
///   not merely settle, on pause.
/// - The loop is started and stopped via `.animation(_:value:)` keyed to
///   one `@State`, never `withAnimation`. The transforms must not read
///   `isPlaying` directly: the prop flips in the module's own (instant)
///   transaction, which interrupts an in-flight `repeatForever` instead
///   of replacing it — the artwork froze mid-drift as a mangled crop on
///   every pause. `.animation(value:)` picks the ease-out at the moment
///   the value flips, which replaces the repeat deterministically.
/// - Everything stops when playback pauses: the loop settles, the tilt
///   returns to neutral, and no animation remains scheduled.
/// - Reduce Motion (hard rule 8) disables the loop and the tilt entirely;
///   the artwork and glow still render, just still.
struct ArtworkVisualizerView: View {

    let image: NSImage
    /// Computed by `MediaModule` once per artwork; nil draws no glow.
    let palette: ArtworkPalette?
    let isPlaying: Bool
    var cornerRadius: CGFloat = 14

    /// Ken Burns extremes. Deliberately gentle — this sits under text.
    ///
    /// Drift is a fraction of the view's own width, not a fixed point count:
    /// 10pt on a 60pt tile is a sixth of the frame, which slid the crop
    /// visibly off-centre. Both scales must stay above `1 + 2 * driftRatio`
    /// or the image pulls away from an edge and leaves a gap.
    private let restScale: CGFloat = 1.08
    private let driftScale: CGFloat = 1.18
    private let driftRatio: CGFloat = 0.03
    private let loopDuration: TimeInterval = 18

    /// Maximum tilt in degrees at the panel's edge.
    private let maxTilt: Double = 5

    /// Sole driver of the Ken Burns loop. Set plainly (no `withAnimation`);
    /// the `.animation(_:value:)` modifiers on the transforms decide the
    /// curve — repeat on start, ease-out on stop.
    @State private var loopActive = false
    /// Cursor position within the view, normalised to -1...1 on both axes.
    @State private var tilt: CGSize = .zero

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var animatesLoop: Bool { isPlaying && !reduceMotion }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                glow(in: geo.size)
                artwork(in: geo.size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard !reduceMotion, isPlaying else { return }
                switch phase {
                case .active(let point):
                    let x = (point.x / max(geo.size.width, 1)) * 2 - 1
                    let y = (point.y / max(geo.size.height, 1)) * 2 - 1
                    withAnimation(.easeOut(duration: 0.18)) {
                        tilt = CGSize(width: min(1, max(-1, x)), height: min(1, max(-1, y)))
                    }
                case .ended:
                    withAnimation(.easeOut(duration: 0.35)) { tilt = .zero }
                }
            }
        }
        .onAppear {
            loopActive = animatesLoop
        }
        .onChange(of: isPlaying) { _, _ in
            loopActive = animatesLoop
            if !animatesLoop {
                withAnimation(.easeOut(duration: 0.4)) { tilt = .zero }
            }
        }
    }

    /// Repeat while looping, ease back to rest when stopped. Evaluated at
    /// the moment `loopActive` changes, so the stop always animates out
    /// instead of interrupting the repeat mid-flight.
    private var loopAnimation: Animation {
        loopActive
            ? .easeInOut(duration: loopDuration).repeatForever(autoreverses: true)
            : .easeOut(duration: 0.6)
    }

    // MARK: - Layers

    /// Two soft radial pools in the artwork's own colours, plus a wash of
    /// its overall tone. Blurred well past the artwork's edge so it reads as
    /// light spilling onto the panel rather than a border.
    @ViewBuilder
    private func glow(in size: CGSize) -> some View {
        if let palette {
            ZStack {
                RadialGradient(
                    colors: [palette.leading.opacity(0.55), .clear],
                    center: .init(x: 0.25, y: 0.35),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.75
                )
                RadialGradient(
                    colors: [palette.trailing.opacity(0.45), .clear],
                    center: .init(x: 0.78, y: 0.7),
                    startRadius: 0,
                    endRadius: max(size.width, size.height) * 0.7
                )
                palette.overall.opacity(0.18)
            }
            // Proportional: a fixed 26pt blur swamped a 60pt thumbnail.
            .blur(radius: max(8, min(size.width, size.height) * 0.28))
            .scaleEffect(loopActive ? 1.08 : 1)
            .animation(loopAnimation, value: loopActive)
            .allowsHitTesting(false)
        }
    }

    private func artwork(in size: CGSize) -> some View {
        let drift = size.width * driftRatio
        // The clip belongs to a fixed-size container, with the image moving
        // *inside* it. Clipping after the transforms made the crop window
        // travel with the image, which is what mangled the thumbnail.
        return Color.clear
            .overlay(
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // Ken Burns: scale and drift together, autoreversing.
                    .scaleEffect(loopActive ? driftScale : restScale)
                    .offset(
                        x: loopActive ? drift : -drift,
                        y: loopActive ? -drift * 0.6 : drift * 0.6
                    )
                    .animation(loopAnimation, value: loopActive)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            // Parallax: tilt away from the cursor, with a slight counter
            // shift so the surface reads as having depth.
            .rotation3DEffect(
                .degrees(-tilt.height * maxTilt),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.6
            )
            .rotation3DEffect(
                .degrees(tilt.width * maxTilt),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.6
            )
            .offset(x: tilt.width * 3, y: tilt.height * 3)
            .shadow(color: (palette?.overall ?? .black).opacity(0.5), radius: 12)
    }

}
