import Foundation
import CoreGraphics

/// What the lock-screen overlay shows. Hidden is `nil`, not a case: hidden
/// means no window and no SkyLight space at all.
nonisolated enum LockScreenOverlayPhase: Equatable, Sendable {
    /// Looking for a face.
    case scanning
    /// Face matched: the password is being typed or checked.
    case matched
    /// The attempt ended without unlocking; shown for `failureHold`.
    case failed
}

/// Coordinator state in, overlay phase out. Pure: no AppKit, no clock of its
/// own, so every row of the table is a test.
///
/// Derived, not a second state machine: everything comes from the
/// coordinator's `status`, `lastOutcome` and `lastOutcomeAt`. The one thing
/// the caller adds is `consumedOutcomeAt`, the `lastOutcomeAt` it has already
/// dealt with (shown and expired, killed, or recorded before the current
/// scan began). `lastOutcome` outlives its lock session, so without that an
/// old failure could come back.
nonisolated enum LockScreenOverlayMapping {

    /// How long a failure stays up, measured from `lastOutcomeAt`.
    static let failureHold: TimeInterval = 2

    /// The coordinator states that are an attempt in progress.
    static func isInProgress(_ status: FaceUnlockStatus) -> Bool {
        switch status {
        case .scanning, .typingPassword, .verifying: true
        default: false
        }
    }

    /// Whether an outcome, while fresh, holds a failure on screen.
    static func showsFailure(_ outcome: FaceUnlockOutcome) -> Bool {
        switch outcome {
        // Aborted partway: part of the password may be in the field, which
        // the user has to clear, so it is a failure.
        case .scanCapReached, .livenessDenied, .passwordRejected, .abortedPartway, .failed:
            true
        // Unlocked: the lock screen is gone. Aborted: the lock screen went
        // away or the display slept. Inconclusive: the session server gave
        // no answer, which on hardware is what an unlock looks like for its
        // first seconds (measured 2026-10-15), so a failure there would
        // most likely be drawn over a Mac that just unlocked.
        case .unlocked, .unlockedUnconfirmed, .aborted, .verificationInconclusive:
            false
        }
    }

    /// Seconds of failure hold left, from 0 to `failureHold`.
    static func failureHoldRemaining(outcomeAt: Date, now: Date) -> TimeInterval {
        let elapsed = max(0, now.timeIntervalSince(outcomeAt))
        return max(0, failureHold - elapsed)
    }

    static func phase(status: FaceUnlockStatus, outcome: FaceUnlockOutcome?, outcomeAt: Date?,
                      consumedOutcomeAt: Date?, now: Date) -> LockScreenOverlayPhase? {
        switch status {
        case .scanning: return .scanning
        case .typingPassword, .verifying: return .matched
        default: break
        }
        guard let outcome, let outcomeAt, outcomeAt != consumedOutcomeAt,
              showsFailure(outcome),
              failureHoldRemaining(outcomeAt: outcomeAt, now: now) > 0 else { return nil }
        return .failed
    }
}

/// Where the overlay sits: the notch plus a wing either side, flush with the
/// top of the screen and as tall as the notch, so content sits beside the
/// housing inside the menu-bar band and never reaches the lock-screen clock.
nonisolated struct LockScreenScanLayout: Equatable, Sendable {

    /// Width of each wing beside the notch. Tune by eye on hardware.
    static let wingWidth: CGFloat = 48

    let notchWidth: CGFloat
    let height: CGFloat
    let wingWidth: CGFloat

    var totalWidth: CGFloat { notchWidth + wingWidth * 2 }

    init(notchRect: NSRect, wingWidth: CGFloat = LockScreenScanLayout.wingWidth) {
        notchWidth = notchRect.width
        height = notchRect.height
        self.wingWidth = wingWidth
    }

    /// The window frame, in the same (global) coordinates as `notchRect`.
    static func overlayFrame(notchRect: NSRect, wingWidth: CGFloat = LockScreenScanLayout.wingWidth) -> NSRect {
        notchRect.insetBy(dx: -wingWidth, dy: 0)
    }
}
