// Adapted from Glance (github.com/jonnyoo/glance), MIT, (c) 2026 Jonathan Zhou.
// See THIRD-PARTY-LICENSES.md.

import SwiftUI
import AppKit

/// 80 ticks in eight 45° sectors, each lit once its pose is captured. The
/// centre pose has no sector and pulses the whole ring. A short band of
/// longer, tinted ticks follows where the head is turned.
struct EnrollmentRingView: View {
    let session: FaceEnrollmentSession
    /// The camera circle's diameter; ticks start just outside it.
    let diameter: CGFloat

    private let tickCount = 80
    private let ticksPerSector = 10
    private let turnIndicatorTickSpan = 6.0
    private let unlitLength: CGFloat = 12
    private let litLength: CGFloat = 20
    private let turnLengthBoost: CGFloat = 5
    private let tickWidth: CGFloat = 2.4

    @State private var pulseActive = false

    private var radius: CGFloat { diameter / 2 + 6 }
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        let turn = session.headTurn
        ZStack {
            ForEach(0..<tickCount, id: \.self) { index in
                let intensity = turnIntensity(for: index, turn: turn)
                let length = length(for: index, intensity: intensity)
                Capsule()
                    .fill(color(for: index, intensity: intensity))
                    .frame(width: tickWidth, height: length)
                    // Inner tip pinned at the radius, so growth goes outward.
                    .offset(y: -(radius + length / 2))
                    .rotationEffect(.degrees(angle(for: index)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.3)
                        .delay(Double(index % ticksPerSector) * 0.008), value: isLit(index))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: pulseActive)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: intensity)
            }
        }
        .frame(width: 2 * (radius + litLength), height: 2 * (radius + litLength))
        .onChange(of: session.centerPulseTick) { _, _ in pulse() }
        .accessibilityHidden(true)
    }

    private func angle(for index: Int) -> Double {
        Double(index) * 360 / Double(tickCount)
    }

    private func sectorPose(for index: Int) -> EnrollmentPose? {
        let sector = Int((angle(for: index) / 45).rounded()) % 8
        return EnrollmentPose.allCases.first { $0.compassAngle == Double(sector) * 45 }
    }

    private func isLit(_ index: Int) -> Bool {
        guard let pose = sectorPose(for: index) else { return false }
        return session.capturedPoses.contains(pose)
    }

    private func length(for index: Int, intensity: Double) -> CGFloat {
        if isLit(index) || pulseActive { return litLength }
        return unlitLength + turnLengthBoost * intensity
    }

    private func color(for index: Int, intensity: Double) -> Color {
        if isLit(index) { return .accentColor }
        if intensity > 0 { return Color.accentColor.opacity(0.35 + 0.65 * intensity) }
        return Color.secondary.opacity(0.45)
    }

    /// Peaks where the head points and fades over half the span each side.
    private func turnIntensity(for index: Int, turn: HeadTurn?) -> Double {
        guard let turn, !isLit(index) else { return 0 }
        var delta = abs(angle(for: index) - turn.angle)
        if delta > 180 { delta = 360 - delta }
        let degreesPerTick = 360 / Double(tickCount)
        return turn.progress * max(0, 1 - (delta / degreesPerTick) / (turnIndicatorTickSpan / 2))
    }

    private func pulse() {
        guard !reduceMotion else { return }
        Task {
            pulseActive = true
            try? await Task.sleep(for: .milliseconds(220))
            pulseActive = false
        }
    }
}
