import Foundation

/// Where lock-screen Face Unlock stands, for the Settings page. The gate
/// cases are in the order the coordinator checks them; the first that
/// applies wins.
enum FaceUnlockStatus: Equatable, Sendable {
    case disabled
    /// The session is locked (Lock Now, auto-lock, a launch with nothing to
    /// restore, or a cancelled owner check), so the password cannot be read
    /// at the lock screen.
    case sessionLocked
    case noStoredPassword
    /// Auto-typing stopped after two lock sessions in a row in which the
    /// typed password did not unlock the Mac. Also used, until the screen
    /// unlocks, once a lock session has started
    /// `FaceUnlockCoordinator.scanStartsPerLockSession` scans.
    case pausedAfterRejections
    /// The face data is not decrypted in memory, or cannot be.
    case faceDataNotReady
    case noEnrolledFace
    /// Every face that is turned on was enrolled with an older face model:
    /// they are kept but cannot match until recaptured.
    case enrolledFacesNeedRecapture
    case accessibilityNeeded
    /// Camera access was never requested: PopNotch is not listed in System
    /// Settings yet. Adding a face is what asks for it.
    case cameraNotYetRequested
    /// Denied or restricted.
    case cameraNotAuthorized
    /// Armed. The last typed password did not unlock the Mac, once.
    case passwordRejected
    /// Armed.
    case ready
    case scanning
    case typingPassword
    case verifying

    var text: String {
        switch self {
        case .disabled:
            "Face Unlock at the lock screen is off."
        case .sessionLocked:
            "Face Unlock is paused — unlock it in Settings."
        case .noStoredPassword:
            "Save your Mac password to use Face Unlock at the lock screen."
        case .pausedAfterRejections:
            "Typing your password is paused: it was typed twice and the Mac stayed locked. Re-save your password in Settings."
        case .faceDataNotReady:
            "Your face data isn't loaded. Unlock Face Unlock in Settings."
        case .noEnrolledFace:
            "Add a face, or turn one on, to use Face Unlock at the lock screen."
        case .enrolledFacesNeedRecapture:
            "PopNotch's face model changed. Recapture your face under Enrolled Faces to use Face Unlock again."
        case .accessibilityNeeded:
            "PopNotch needs Accessibility permission to type your password."
        case .cameraNotYetRequested:
            "PopNotch hasn't asked for camera access yet. Add a face in Settings, and macOS will ask then."
        case .cameraNotAuthorized:
            "PopNotch needs camera access. Turn it on in System Settings → Privacy & Security → Camera."
        case .passwordRejected:
            "Your password was typed but the Mac stayed locked — your stored password may be out of date."
        case .ready:
            "Ready. Wake your Mac at the lock screen and look at the camera to unlock with your face."
        case .scanning:
            "Looking for your face…"
        case .typingPassword:
            "Face recognised — typing your password…"
        case .verifying:
            "Checking that the Mac unlocked…"
        }
    }

    /// True for the states in which a wake at the lock screen starts a scan.
    var isArmed: Bool { self == .ready || self == .passwordRejected }
}

/// How the last lock-screen attempt ended.
enum FaceUnlockOutcome: Equatable, Sendable {
    /// The password was typed and the Mac unlocked within the confirmation
    /// window.
    case unlocked
    /// The Mac unlocked, but too long after Return to credit the typed
    /// password: the rejection count is neither reset nor raised.
    case unlockedUnconfirmed
    /// The session server gave no answer when the check ended.
    case verificationInconclusive
    /// The scan reached its 2-minute cap without typing anything.
    case scanCapReached
    /// An enrolled face matched, but liveness refused it, and the scan ran
    /// to its cap without typing anything.
    case livenessDenied(LivenessCue)
    case passwordRejected
    /// The lock screen went away, the display slept, or the password field
    /// lost focus, before anything was typed.
    case aborted
    /// The same, after part of the password was typed. Return was not
    /// pressed, and the field may hold the partial password.
    case abortedPartway
    /// The camera or the face model could not start, or typing failed.
    case failed(String)

    var text: String {
        switch self {
        case .unlocked: "Unlocked with your face."
        case .unlockedUnconfirmed: "Mac unlocked — couldn't confirm the typed password worked."
        case .verificationInconclusive: "Couldn't confirm whether the typed password worked: macOS didn't report the lock state."
        case .scanCapReached: "Stopped looking after 2 minutes — close and reopen the lid, or let the display sleep and wake it, to try again."
        case .livenessDenied(let cue): "Not unlocked: your face matched, but \(cue.denialReason) suggested a photo. Nothing was typed."
        case .passwordRejected: FaceUnlockStatus.passwordRejected.text
        case .aborted: "Stopped before typing: the Mac left the lock screen or the password field lost focus."
        case .abortedPartway: "Partially typed; Return not pressed — clear the field before typing your password."
        case .failed(let reason): "Face Unlock could not run: \(reason)"
        }
    }
}
