import SwiftUI

/// The HUD strip: a glyph and a level bar under the notch housing.
struct SystemHUDView: View {

    let state: SystemHUDState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: Self.symbol(kind: state.kind, level: state.level,
                                          isMuted: state.isMuted))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                // Fixed, so swapping between one and three waves never
                // shifts the bar.
                .frame(width: 18, alignment: .leading)
            HUDLevelBar(level: state.level)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let percent = Int((state.level * 100).rounded())
        switch state.kind {
        case .volume: return state.isMuted ? "Volume muted" : "Volume \(percent) percent"
        case .brightness: return "Brightness \(percent) percent"
        }
    }

    /// The glyph for a reading, matching the system's own thresholds in
    /// spirit: slashed when silent, then one, two, three waves; a small sun
    /// below half brightness, a full one above.
    nonisolated static func symbol(kind: SystemHUDState.Kind, level: Double,
                                   isMuted: Bool) -> String {
        switch kind {
        case .volume:
            if isMuted || level <= 0 { return "speaker.slash.fill" }
            if level < 1.0 / 3 { return "speaker.wave.1.fill" }
            if level < 2.0 / 3 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        }
    }
}

/// A rounded track filled to `level`. Steps jump with no animation, in
/// lockstep with the system's increments.
private struct HUDLevelBar: View {

    let level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(.white)
                    .frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .frame(height: 5)
    }
}
