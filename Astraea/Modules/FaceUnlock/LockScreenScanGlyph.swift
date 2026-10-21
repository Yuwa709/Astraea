import SwiftUI

/// The leading wing: the Face ID glyph breathing while scanning, a green
/// check with a soft glow on a match, and the glyph turned red with a small
/// shake on a failure. Icon-only, because a failure can be the two-minute
/// cap as much as a rejected password.
struct LockScreenScanGlyph: View {
    let phase: LockScreenOverlayPhase
    let reduceMotion: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            // Group hands the transition to whichever branch is shown.
            Group {
                switch phase {
                case .scanning:
                    if reduceMotion {
                        LockScreenFaceGlyph(size: size, color: .white)
                    } else {
                        LockScreenBreathingGlyph(size: size)
                    }
                case .matched:
                    LockScreenMatchedGlyph(size: size)
                case .failed:
                    LockScreenFailedGlyph(size: size, reduceMotion: reduceMotion)
                }
            }
            .transition(LockScreenScanMotion.arrival(reduceMotion: reduceMotion))
        }
        .animation(LockScreenScanMotion.phaseChange(reduceMotion: reduceMotion), value: phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch phase {
        case .scanning: "Face Unlock: looking for your face"
        case .matched: "Face Unlock: face recognised"
        case .failed: "Face Unlock: not unlocked"
        }
    }
}
