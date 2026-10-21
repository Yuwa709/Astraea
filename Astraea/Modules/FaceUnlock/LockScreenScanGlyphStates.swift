import SwiftUI

// The glyphs `LockScreenScanGlyph` switches between, one per phase.

/// The plain glyph. Static: the Reduce Motion scan, and the failure's base.
struct LockScreenFaceGlyph: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: "faceid")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(color)
    }
}

/// The scanning glyph, slowly brightening and dimming. Its loop lives and
/// dies with this view, which exists only while scanning without Reduce
/// Motion.
struct LockScreenBreathingGlyph: View {
    let size: CGFloat
    @State private var inhaled = false

    var body: some View {
        LockScreenFaceGlyph(size: size, color: .white)
            .opacity(inhaled ? 1 : 0.45)
            .scaleEffect(inhaled ? 1 : 0.92)
            .onAppear {
                withAnimation(LockScreenScanMotion.breath) { inhaled = true }
            }
            .modifier(LockScreenLoopLogging(name: "glyph"))
    }
}

/// A white check on green, with a green glow on the black band.
struct LockScreenMatchedGlyph: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .green)
            .shadow(color: .green.opacity(0.7), radius: 5)
    }
}

/// The glyph in red, shaken once on arrival unless Reduce Motion is on.
struct LockScreenFailedGlyph: View {
    let size: CGFloat
    let reduceMotion: Bool
    @State private var shake: CGFloat = 0

    var body: some View {
        LockScreenFaceGlyph(size: size, color: Color(red: 1, green: 0.32, blue: 0.29))
            .modifier(LockScreenShakeEffect(progress: shake))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.4)) { shake = 1 }
            }
    }
}
