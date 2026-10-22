import SwiftUI

/// Left wing: time until full on the charger (Apple's gauge), time until
/// empty off it (Astraea's estimate), both as h:mm. A dimmed placeholder
/// holds the wing while a figure is on its way; only a full battery on the
/// charger leaves it blank. See `BatteryWingMonitor.Reading.wingShowsTime`.
struct BatteryWingTimeLeft: View {
    let monitor: BatteryWingMonitor

    var body: some View {
        if let reading = monitor.reading, reading.wingShowsTime {
            let minutes = reading.wingMinutes
            Text(minutes.map(Self.format) ?? "–:––")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.white.opacity(minutes == nil ? 0.5 : 0.92))
                .accessibilityLabel(minutes.map {
                    "\($0 / 60) hours \($0 % 60) minutes until \(reading.isOnAC ? "full" : "empty")"
                } ?? "Estimating time remaining")
        }
    }

    nonisolated static func format(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

/// Right wing: a plain battery, its fill showing the charge. No number and
/// no bolt — the fill colour alone says where power comes from: green on the
/// charger, white off it, red when low. Sized to match the left wing's 12pt
/// time text; at 31pt with a number inside it outweighed the left wing
/// (user-observed 2026-10-21).
struct BatteryWingCharge: View {
    let monitor: BatteryWingMonitor

    static let bodySize = CGSize(width: 20, height: 10)
    private static let inset: CGFloat = 1.5
    /// Apple's system grey, #8E8E93 (the same in light and dark), for the
    /// outline and nub: a solid white frame competed with the fill.
    private static let outlineGray = Color(red: 142 / 255, green: 142 / 255, blue: 147 / 255)
    /// Apple's system green in its dark variant, #30D158 — the charging
    /// green of the iOS battery (owner's call, 2026-10-21). Fixed rather than
    /// `NSColor.systemGreen`, which would turn to the light variant (#34C759)
    /// under a light menu bar, though the panel is always black.
    private static let chargingGreen = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)

    var body: some View {
        if let reading = monitor.reading {
            let fillWidth = max(1.5, (Self.bodySize.width - Self.inset * 2) * CGFloat(reading.percentage) / 100)
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.75)
                        .strokeBorder(Self.outlineGray, lineWidth: 1)
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Self.fill(for: reading))
                        .frame(width: fillWidth)
                        .padding(Self.inset)
                }
                .frame(width: Self.bodySize.width, height: Self.bodySize.height)
                // The terminal nub.
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Self.outlineGray)
                    .frame(width: 1.5, height: 3.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery \(reading.percentage) percent\(reading.isOnAC ? ", on charger" : "")")
        }
    }

    private static func fill(for reading: BatteryWingMonitor.Reading) -> Color {
        if reading.isOnAC { return chargingGreen }
        if reading.percentage <= 20 { return .red.opacity(0.85) }
        return .white.opacity(0.9)
    }
}
