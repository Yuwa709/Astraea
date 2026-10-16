import SwiftUI

extension Color {
    /// The update tint: a cool blue against the black panel, deliberately
    /// unlike the warm media accent so the two wings never read as one.
    static let updateAccent = Color(red: 0.42, green: 0.74, blue: 1.0)
}

/// Left wing: the download glyph. Still, always: a badge that pulses would
/// need a repeating animation, and the wing waveform already taught what
/// those cost at idle (PROJECT-CONTEXT, performance findings).
struct UpdateWingGlyph: View {
    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.updateAccent)
            .accessibilityLabel("Update available")
    }
}

/// Right wing: the version waiting. Scales down rather than truncating, so
/// a long version still reads inside the 44pt wing.
struct UpdateWingVersion: View {
    let version: String

    var body: some View {
        Text(version)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(.white.opacity(0.92))
    }
}

/// The expanded card: what is out, what is running, and the way to install.
struct UpdateNoticeCard: View {
    let service: UpdateService

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Color.updateAccent)
            VStack(alignment: .leading, spacing: 3) {
                Text("UPDATE AVAILABLE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                Text("PopNotch \(service.availableVersion ?? "")")
                    .font(.system(size: 14, weight: .semibold))
                Text("You have \(service.currentVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 12)
            installButton
        }
        .frame(width: 368, alignment: .leading)
        .foregroundStyle(.white)
    }

    /// Hands off to Sparkle. Click-driven, so the activation Sparkle does
    /// to show its alert falls under the same carve-out as the settings
    /// gear; see `UpdateService.showUpdate`.
    private var installButton: some View {
        Button {
            service.showUpdate()
        } label: {
            Text("Install…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.black.opacity(0.85))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.updateAccent))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open the installer")
    }
}
