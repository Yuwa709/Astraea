// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import Foundation

/// A guided head pose: centre, then the eight compass directions, in the
/// order they are asked for.
nonisolated enum EnrollmentPose: Int, CaseIterable, Sendable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    enum YawBand { case left, none, right }
    enum PitchBand { case up, none, down }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: .left
        case .right, .topRight, .bottomRight: .right
        case .center, .top, .bottom: .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: .up
        case .bottom, .bottomLeft, .bottomRight: .down
        case .center, .left, .right: .none
        }
    }

    /// Compass angle (0 = up, clockwise) of this pose's ring sector. Centre
    /// has none; it pulses the whole ring instead.
    var compassAngle: Double? {
        switch self {
        case .center: nil
        case .left: 270
        case .topLeft: 315
        case .top: 0
        case .topRight: 45
        case .right: 90
        case .bottomRight: 135
        case .bottom: 180
        case .bottomLeft: 225
        }
    }

    var instruction: String {
        switch self {
        case .center: "Look straight at the camera"
        case .left: "Turn your head slightly left"
        case .topLeft: "Turn your head to the top left"
        case .top: "Tilt your head slightly up"
        case .topRight: "Turn your head to the top right"
        case .right: "Turn your head slightly right"
        case .bottomRight: "Turn your head to the bottom right"
        case .bottom: "Tilt your head slightly down"
        case .bottomLeft: "Turn your head to the bottom left"
        }
    }

    /// Widens this pose's bands; looking down-and-sideways is hard.
    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: 1.5
        case .bottom: 1.2
        default: 1
        }
    }

    /// Persisted with each sample.
    var storageName: String {
        switch self {
        case .center: "center"
        case .left: "left"
        case .topLeft: "top_left"
        case .top: "top"
        case .topRight: "top_right"
        case .right: "right"
        case .bottomRight: "bottom_right"
        case .bottom: "bottom"
        case .bottomLeft: "bottom_left"
        }
    }
}

/// Where the head is turned, for the ring's live indicator.
nonisolated struct HeadTurn: Equatable, Sendable {
    /// Compass angle, same frame as `EnrollmentPose.compassAngle`.
    let angle: Double
    /// 0...1 toward the current pose's threshold.
    let progress: Double
}

nonisolated enum ExcessiveTurn: Equatable, Sendable {
    case left, topLeft, up, topRight, right, bottomRight, down, bottomLeft

    var instruction: String {
        switch self {
        case .left: "Too far left"
        case .topLeft: "Too far toward the top left"
        case .up: "Too far up"
        case .topRight: "Too far toward the top right"
        case .right: "Too far right"
        case .bottomRight: "Too far toward the bottom right"
        case .down: "Too far down"
        case .bottomLeft: "Too far toward the bottom left"
        }
    }
}

/// The pose bands, pure so they are testable without a camera. Radians,
/// raw Vision signs on the unmirrored frame: +yaw is a turn to the user's
/// left, -pitch is looking up (Glance confirmed both empirically).
nonisolated enum EnrollmentPoseRules {
    static let yawInnerThreshold: Float = 0.24
    static let yawCenterTolerance: Float = 0.18
    static let yawOuterCap: Float = 0.51
    static let pitchInnerThreshold: Float = 0.17
    static let pitchCenterTolerance: Float = 0.15
    static let pitchOuterCap: Float = 0.37
    /// Applied once a pose has taken longer than the stall timeout, so an
    /// unusual camera angle cannot strand the user.
    static let stallWidenFactor: Float = 1.25
    /// Below this fraction of the threshold, direction is sensor noise.
    static let headTurnDeadzone: Double = 0.15

    static func poseMatches(yaw: Float, pitch: Float, pose: EnrollmentPose, widened: Bool) -> Bool {
        let factor = (widened ? stallWidenFactor : 1) * pose.matchLeniency
        let yawOK = switch pose.yawBand {
        case .none: abs(yaw) < yawCenterTolerance * factor
        case .left: yaw > yawInnerThreshold / factor && yaw < yawOuterCap
        case .right: yaw < -yawInnerThreshold / factor && yaw > -yawOuterCap
        }
        let pitchOK = switch pose.pitchBand {
        case .none: abs(pitch) < pitchCenterTolerance * factor
        case .up: pitch < -pitchInnerThreshold / factor && pitch > -pitchOuterCap
        case .down: pitch > pitchInnerThreshold / factor && pitch < pitchOuterCap
        }
        return yawOK && pitchOK
    }

    /// The dominant direction once the head is past the useful envelope;
    /// samples there are not repeatable, so capture is refused.
    static func excessiveTurn(yaw: Float, pitch: Float) -> ExcessiveTurn? {
        let yawOver = abs(yaw) / yawOuterCap
        let pitchOver = abs(pitch) / pitchOuterCap
        guard max(yawOver, pitchOver) >= 1 else { return nil }

        if yawOver >= 1, pitchOver >= 1 {
            switch (yaw > 0, pitch < 0) {
            case (true, true): return .topLeft
            case (false, true): return .topRight
            case (false, false): return .bottomRight
            case (true, false): return .bottomLeft
            }
        }
        if yawOver >= pitchOver { return yaw > 0 ? .left : .right }
        return pitch < 0 ? .up : .down
    }

    /// Axes are normalised against the pose's thresholds, so `progress`
    /// reaches 1 as the pose starts matching. Vision inverts both axes
    /// relative to the mirrored preview.
    static func headTurn(yaw: Float, pitch: Float, pose: EnrollmentPose) -> HeadTurn? {
        guard pose != .center else { return nil }
        let x = Double(-yaw / (yawInnerThreshold / pose.matchLeniency))
        let y = Double(-pitch / (pitchInnerThreshold / pose.matchLeniency))
        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > headTurnDeadzone else { return nil }
        let degrees = atan2(x, y) * 180 / .pi
        return HeadTurn(angle: degrees < 0 ? degrees + 360 : degrees, progress: min(magnitude, 1))
    }
}
