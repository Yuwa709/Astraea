import Foundation

/// How much liveness checking lock-screen Face Unlock does before it types.
/// Stored in `AppSettings` by name, so a name this build does not know (a
/// later build's heavier level, say) decodes as the default rather than
/// costing the settings beside it.
nonisolated enum FaceLivenessLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    /// No check: a match alone types the password, as before phase 4.
    case off
    /// Deny-only, Glance's Light mode: screen glare or a device edge round
    /// the face blocks typing. Nothing has to prove the face is real, so a
    /// matte print or an angled phone that shows neither still passes.
    case light

    static let `default`: FaceLivenessLevel = .light

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        }
    }

    var summary: String {
        switch self {
        case .off: "A face match alone types your password, so a photo of you on a phone may unlock the Mac."
        case .light: "Refuses a scan when the frame shows screen glare or the edge of a phone or tablet. A well-held matte print, or a phone held at an angle, can still pass."
        }
    }

    /// Ordered weakest first.
    private var strength: Int {
        switch self {
        case .off: 0
        case .light: 1
        }
    }

    /// Checks less than `other`: changing to it needs a fresh owner check
    /// (`FaceUnlockSession.reauthenticate(reason:)`).
    func isWeaker(than other: FaceLivenessLevel) -> Bool { strength < other.strength }
}
