import SwiftUI
import Observation

/// Everything the lock-screen view reads. One per presentation; the
/// presenter changes `phase` in place, so the view animates between phases
/// without the window being rebuilt.
@Observable
@MainActor
final class LockScreenScanModel {
    /// Never nil while a window exists: hidden means no window.
    var phase: LockScreenOverlayPhase
    /// Read once, when the overlay is presented. With it on, phase changes
    /// must be instant (no springs, no movement).
    let reduceMotion: Bool
    /// The notch, the wings either side, and the height they share.
    let layout: LockScreenScanLayout

    init(phase: LockScreenOverlayPhase, reduceMotion: Bool, layout: LockScreenScanLayout) {
        self.phase = phase
        self.reduceMotion = reduceMotion
        self.layout = layout
    }
}

/// The notch grown sideways: one black band in the house compact silhouette
/// (`NotchShape`, flared into the screen edge like the idle notch panel),
/// with the Face ID glyph in the leading wing and a quiet activity cue in the
/// trailing one. The centre is the physical housing, so nothing is drawn
/// there. Drawn above the lock screen, never interactive (the window ignores
/// the mouse), and never below the band, where the lock-screen clock sits.
///
/// The only repeating animations live in the scanning-only subviews, which
/// are removed the moment the phase leaves `.scanning` (see
/// `LockScreenScanMotion`), and the whole tree goes with the window.
struct LockScreenScanView: View {
    let model: LockScreenScanModel

    var body: some View {
        let layout = model.layout
        // The silhouette's body is inset from the window edge by the top
        // flare, so each wing's content is centred in what is visibly black.
        let inset = NotchShape.compactTopRadius
        let wingContent = max(0, layout.wingWidth - inset)
        ZStack {
            NotchShape().fill(Color.black)
            HStack(spacing: 0) {
                LockScreenScanGlyph(phase: model.phase, reduceMotion: model.reduceMotion,
                                    size: layout.height * 0.48)
                    .frame(width: wingContent, height: layout.height)
                    .padding(.leading, inset)
                Color.clear.frame(width: layout.notchWidth)
                LockScreenScanActivity(phase: model.phase, reduceMotion: model.reduceMotion,
                                       size: layout.height * 0.36)
                    .frame(width: wingContent, height: layout.height)
                    .padding(.trailing, inset)
            }
        }
        .frame(width: layout.totalWidth, height: layout.height)
        .ignoresSafeArea()
    }
}
