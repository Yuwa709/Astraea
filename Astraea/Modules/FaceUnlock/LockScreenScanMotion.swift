import SwiftUI
import os

/// The lock-screen overlay's motion, in one place.
///
/// The scanning loops are `repeatForever` SwiftUI animations. Those are
/// ticked on the main thread every display refresh and cannot be retracted by
/// a later animation (PROJECT-CONTEXT.md, the wing-waveform CPU incident), so
/// a loop is stopped by removing the view that owns it: each looping view
/// exists only while the phase is `.scanning` and Reduce Motion is off, and
/// logs when its loop starts and stops. No timer anywhere.
///
/// Reduce Motion (hard rule 8): everything is instant. No loop, no scale,
/// no spring, no shake, no crossfade between phases, and the window appears
/// and disappears without a fade.
enum LockScreenScanMotion {

    static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    /// One scanning breath, each way.
    static let breathDuration: TimeInterval = 1.1

    /// The window's alpha fade in and out, without Reduce Motion.
    static let windowFadeDuration: TimeInterval = 0.2

    /// Between phases; nil, no animation at all, under Reduce Motion. The
    /// match must land inside ~0.25 s: the user sees it for well under a
    /// second and a half before the window vanishes.
    static func phaseChange(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3)
    }

    /// How a phase's glyph arrives: popping in from smaller, or, under
    /// Reduce Motion, simply there.
    static func arrival(reduceMotion: Bool) -> AnyTransition {
        reduceMotion
            ? .identity
            : .asymmetric(insertion: .scale(scale: 0.6).combined(with: .opacity),
                          removal: .opacity)
    }

    /// The window's fade-in; nil, appear at once, under Reduce Motion.
    static func windowFadeIn(reduceMotion: Bool) -> TimeInterval? {
        reduceMotion ? nil : windowFadeDuration
    }

    /// The repeating breath. Only for views that exist solely while it runs.
    static var breath: Animation {
        .easeInOut(duration: breathDuration).repeatForever(autoreverses: true)
    }
}

/// A short horizontal shake that decays to rest, like a rejected passcode.
/// Finite: one animation from 0 to 1, nothing left running.
nonisolated struct LockScreenShakeEffect: GeometryEffect {
    /// 0 at rest, 1 when the shake has finished.
    var progress: CGFloat

    static let amplitude: CGFloat = 4
    static let oscillations: CGFloat = 3

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let decay = 1 - min(max(progress, 0), 1)
        let x = Self.amplitude * decay * sin(progress * .pi * 2 * Self.oscillations)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// Logs a scanning loop's lifetime at `.notice`, the evidence that it stops
/// when the phase moves on (hard rule 9).
struct LockScreenLoopLogging: ViewModifier {
    let name: String

    func body(content: Content) -> some View {
        content
            .onAppear {
                LockScreenScanMotion.logger.notice("Lock-screen scan \(name, privacy: .public) loop started")
            }
            .onDisappear {
                LockScreenScanMotion.logger.notice("Lock-screen scan \(name, privacy: .public) loop stopped")
            }
    }
}
