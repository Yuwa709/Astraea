import SwiftUI

/// The trailing wing: a small pulsing dot while scanning (still, under
/// Reduce Motion), an open lock in green on a match, and a dim closed lock on
/// a failure, which reads as "still locked" whatever the cause.
struct LockScreenScanActivity: View {
    let phase: LockScreenOverlayPhase
    let reduceMotion: Bool
    /// Glyph size; the dot is a fraction of it.
    let size: CGFloat

    var body: some View {
        ZStack {
            // Group hands the transition to whichever branch is shown.
            Group {
                switch phase {
                case .scanning:
                    if reduceMotion {
                        ActivityDot(diameter: size * 0.4).opacity(0.6)
                    } else {
                        PulsingActivityDot(diameter: size * 0.4)
                    }
                case .matched:
                    LockGlyph(name: "lock.open.fill", size: size, color: .green)
                case .failed:
                    LockGlyph(name: "lock.fill", size: size, color: .white.opacity(0.55))
                }
            }
            .transition(LockScreenScanMotion.arrival(reduceMotion: reduceMotion))
        }
        .animation(LockScreenScanMotion.phaseChange(reduceMotion: reduceMotion), value: phase)
        .accessibilityHidden(true)
    }
}

private struct ActivityDot: View {
    let diameter: CGFloat

    var body: some View {
        Circle()
            .fill(Color.white)
            .frame(width: diameter, height: diameter)
    }
}

/// The dot, breathing a little faster than the glyph so the two never move
/// as one. Exists only while scanning without Reduce Motion; its loop ends
/// when it is removed.
private struct PulsingActivityDot: View {
    let diameter: CGFloat
    @State private var lit = false

    var body: some View {
        ActivityDot(diameter: diameter)
            .opacity(lit ? 0.85 : 0.25)
            .scaleEffect(lit ? 1 : 0.75)
            .onAppear {
                withAnimation(LockScreenScanMotion.breath.speed(1.3)) { lit = true }
            }
            .modifier(LockScreenLoopLogging(name: "activity"))
    }
}

private struct LockGlyph: View {
    let name: String
    let size: CGFloat
    let color: Color

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(color)
    }
}
