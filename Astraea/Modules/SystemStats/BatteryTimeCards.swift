import SwiftUI

/// The stats page's battery card: the charge and its level bar, then time
/// until full, time until empty, and the power flowing right now.
///
/// Both times always have a column, plugged in or not — each says why when
/// it has no number, rather than disappearing.
struct BatteryOverviewCard: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BatteryChargeSummary(snapshot: snapshot)
            BatteryLevelBar(snapshot: snapshot)
            Rectangle()
                .fill(NotchStyle.Fill.separator)
                .frame(height: 1)
                .padding(.vertical, 2)
            BatteryTimeFigures(snapshot: snapshot)
        }
        .notchCard()
    }
}

/// Charge percentage, charging state, and how much charge that is.
struct BatteryChargeSummary: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchStyle.Spacing.m) {
            Text(snapshot?.percentage.map { "\($0)%" } ?? "—")
                .font(NotchStyle.Font.metricLarge)
                .foregroundStyle(NotchStyle.Ink.primary)
                .monospacedDigit()
                .contentTransition(.numericText())
            HStack(spacing: NotchStyle.Spacing.xs) {
                if snapshot?.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .accessibilityHidden(true)
                }
                Text(state)
                    .font(NotchStyle.Font.bodyEmphasis)
                    .foregroundStyle(NotchStyle.Ink.primary)
            }
            Spacer(minLength: NotchStyle.Spacing.s)
            if !charge.isEmpty {
                Text(charge)
                    .font(NotchStyle.Font.caption)
                    .foregroundStyle(NotchStyle.Ink.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var state: String {
        guard let snapshot else { return "Battery unavailable" }
        if snapshot.isFullyCharged == true { return "Fully charged" }
        if snapshot.isCharging == true { return "Charging" }
        if snapshot.isExternalConnected == true { return "Plugged in, not charging" }
        return "On battery"
    }

    /// The charge left in the pack against what it holds when full, in the
    /// gauge's own mAh. Empty rather than half a figure when either is
    /// missing.
    private var charge: String {
        guard let now = snapshot?.rawCurrentCapacityMilliampHours,
              let full = snapshot?.rawMaxCapacityMilliampHours, full > 0 else { return "" }
        return "\(now.formatted()) of \(full.formatted()) mAh"
    }
}

/// The page's signature: a continuous capacity bar, the HIG's macOS level
/// indicator, filled to the charge. Its colour follows the battery wing's
/// rule — green on the charger, red when low — plus the system's yellow in
/// Low Power Mode. Each of those states is also in words on the page (the
/// state line, the percentage, the badge), so colour never stands alone.
struct BatteryLevelBar: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(NotchStyle.Fill.selected)
                if let percentage = snapshot?.percentage {
                    let fraction = CGFloat(min(100, max(0, percentage))) / 100
                    Capsule()
                        .fill(fill.gradient)
                        .frame(width: max(8, geometry.size.width * fraction))
                }
            }
        }
        .frame(height: 8)
        .animation(NotchStyle.motion(), value: snapshot?.percentage)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        guard let snapshot else { return NotchStyle.Ink.quaternary }
        if snapshot.isExternalConnected == true { return BatteryInk.charging }
        if snapshot.isLowPowerMode { return BatteryInk.lowPower }
        if let percentage = snapshot.percentage, percentage <= 20 { return BatteryInk.low }
        return Color.white.opacity(0.9)
    }
}

/// The battery card's lower half: until full, until empty, and power, as
/// three columns split by hairlines.
struct BatteryTimeFigures: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        HStack(alignment: .top, spacing: NotchStyle.Spacing.m) {
            let full = BatteryTime.untilFull(snapshot)
            let empty = BatteryTime.untilEmpty(snapshot)
            StatFigure(title: "Until full", value: full.value, detail: full.detail)
            hairline
            StatFigure(title: "Until empty", value: empty.value, detail: empty.detail)
            hairline
            StatFigure(title: "Power",
                       value: power.map { String(format: "%.1f W", $0) } ?? "—",
                       detail: powerDetail)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var hairline: some View {
        Rectangle().fill(NotchStyle.Fill.separator).frame(width: 1)
    }

    /// The Mac's whole draw when the hardware reports it, which is what the
    /// time to empty is computed from; otherwise the pack's own flow.
    private var power: Double? {
        snapshot?.systemLoadWatts ?? snapshot?.watts
    }

    /// Which way the pack's current is flowing. The sign of
    /// `amperageMilliamps` is the source of truth; the label never guesses
    /// from the wattage alone.
    private var powerDetail: String {
        if snapshot?.systemLoadWatts != nil {
            guard let amperage = snapshot?.amperageMilliamps else { return "Mac's draw" }
            if amperage > 0 { return "Mac's draw, charging" }
            if amperage < 0 { return "Mac's draw, on battery" }
            return "Mac's draw, from adapter"
        }
        guard let amperage = snapshot?.amperageMilliamps else { return "Draw unknown" }
        if amperage > 0 { return "Into battery" }
        if amperage < 0 { return "From battery" }
        return "Idle"
    }
}

/// The page's only colours, each meaning a battery state. Apple's dark
/// system variants, fixed rather than `NSColor` dynamic ones because the
/// panel is always black. `charging` is the battery wing's green.
enum BatteryInk {
    static let charging = Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)   // #30D158
    static let lowPower = Color(red: 255 / 255, green: 214 / 255, blue: 10 / 255)  // #FFD60A
    static let low = Color(red: 255 / 255, green: 69 / 255, blue: 58 / 255)        // #FF453A
}

/// What the two time cards say. Pure, so every state is tested rather than
/// eyeballed: these strings are the page's whole answer to "how long".
enum BatteryTime {

    struct Card: Equatable {
        var value: String
        var detail: String
    }

    static func untilFull(_ snapshot: BatterySnapshot?) -> Card {
        guard let snapshot else { return Card(value: "—", detail: "Battery unavailable") }
        if let minutes = snapshot.timeToFullMinutes {
            return Card(value: formatted(minutes), detail: "Charging")
        }
        if snapshot.isFullyCharged == true { return Card(value: "Full", detail: "Charged") }
        if snapshot.isCharging == true { return Card(value: "—", detail: "Estimating…") }
        if snapshot.isExternalConnected == true {
            // Optimized charging, a charge limit, or a weak adapter: macOS
            // is holding the charge where it is.
            return Card(value: "On hold", detail: "Plugged in, not charging")
        }
        return Card(value: "—", detail: "Not plugged in")
    }

    static func untilEmpty(_ snapshot: BatterySnapshot?) -> Card {
        guard let snapshot else { return Card(value: "—", detail: "Battery unavailable") }
        // Plugged in, the battery is not draining: nothing to estimate.
        if snapshot.isExternalConnected == true {
            return Card(value: "On charger", detail: "Estimates once unplugged")
        }
        if let minutes = snapshot.timeToEmptyMinutes {
            return Card(value: formatted(minutes), detail: "macOS estimate")
        }
        if let minutes = snapshot.estimatedTimeToEmptyMinutes {
            return Card(value: formatted(minutes), detail: "At current use")
        }
        return Card(value: "—", detail: "Estimating…")
    }

    /// Minutes under an hour exactly; past an hour, to the nearest five
    /// minutes, so a live estimate does not tick by a minute on every
    /// sample and claim a precision it does not have.
    static func formatted(_ minutes: Int) -> String {
        guard minutes >= 60 else { return "\(max(0, minutes))m" }
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        let remainder = rounded % 60
        return remainder == 0 ? "\(rounded / 60)h" : "\(rounded / 60)h \(remainder)m"
    }
}
