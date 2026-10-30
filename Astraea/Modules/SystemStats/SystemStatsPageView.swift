import SwiftUI

/// The stats door: everything the data layer already reads, on one screen.
///
/// Three bands, most-wanted first. The battery card: the charge, a level
/// bar, and how long until full and until empty, which is what someone
/// opening the page came to see. Then the pack's long-term figures beside
/// the adapter. Then the machine's usage. Reads only what `BatteryService`
/// and `SystemStatsService` publish; this view adds no IOKit of its own.
///
/// No history: the page shows now. A 24-hour charge graph lived here until
/// 2026-10-07, filled only while the page was open, and so was always empty.
///
/// Fixed width, intrinsic height, no scrolling: the panel sizes itself to the
/// content (`NotchCoordinator.measureExpandedContent`), so a scroll view would
/// measure as its own ideal height and defeat that. The width is chosen to
/// leave headroom under the 690pt panel ceiling — see `contentWidth`.
struct SystemStatsPageView: View {

    let stats: SystemStatsService
    let battery: BatteryService

    /// 560pt. With the overlay's 32pt side border either side the panel comes
    /// to 624pt, inside the 690 ceiling with 66pt to spare — unlike the
    /// resting shelf, which sits exactly on it.
    static let contentWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.m) {
            // Same glyph as the feature's switch in Settings.
            NotchPageHeader(symbol: "cpu.fill", title: "System Stats") {
                if battery.snapshot?.isLowPowerMode == true { LowPowerBadge() }
            }
            BatteryOverviewCard(snapshot: battery.snapshot)
            BatteryDetailRow(snapshot: battery.snapshot)
            VStack(alignment: .leading, spacing: 6) {
                NotchSectionLabel("Usage")
                SystemStatsMachineRows(stats: stats.stats)
            }
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .foregroundStyle(NotchStyle.Ink.primary)
    }
}

/// The pack's long-term figures on one card, the adapter on its own: what
/// the battery is, beside what is feeding it.
///
/// Condition is macOS's verdict and keeps its own column and provenance
/// line, so it is never read as the same number as Capacity, which is a
/// ratio Astraea computes. Absent rather than guessed when the system
/// declines to say.
struct BatteryDetailRow: View {
    let snapshot: BatterySnapshot?

    /// The adapter card's width; the health card takes the rest, so its
    /// three columns come out about as wide as this one.
    private static let adapterWidth: CGFloat = 134

    var body: some View {
        HStack(alignment: .top, spacing: NotchStyle.Spacing.s) {
            HStack(alignment: .top, spacing: NotchStyle.Spacing.m) {
                StatFigure(title: "Capacity",
                           value: snapshot?.displayHealthPercent.map { "\(Int($0.rounded()))%" } ?? "—",
                           detail: capacityDetail)
                // Cycles took Temperature's place on 2026-10-07: macOS 27
                // publishes no battery temperature, and the SMC's keys for it
                // are undocumented with nothing left to check them against.
                StatFigure(title: "Cycles",
                           value: snapshot?.cycleCount.map { "\($0)" } ?? "—",
                           detail: "Charge cycles")
                StatFigure(title: "Condition",
                           value: snapshot?.conditionDescription ?? "Not reported",
                           detail: "Reported by macOS")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchCard()
            StatFigure(title: "Adapter", value: adapterValue, detail: adapterDetail)
                .notchCard()
                .frame(width: Self.adapterWidth)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// What the percentage is made of: today's full charge against the
    /// factory figure, both in mAh.
    private var capacityDetail: String {
        guard let full = snapshot?.rawMaxCapacityMilliampHours,
              let design = snapshot?.designCapacityMilliampHours else { return "Of design capacity" }
        return "\(full.formatted()) of \(design.formatted()) mAh"
    }

    private var adapterValue: String {
        guard snapshot?.adapterIsPresent == true else { return "Not connected" }
        return snapshot?.adapterWatts.map { "\($0) W" } ?? "Connected"
    }

    /// The adapter's own `Description` string, shown verbatim — it is a
    /// category ("pd charger"), not a product name, and is never parsed.
    private var adapterDetail: String {
        guard snapshot?.adapterIsPresent == true else { return "On battery" }
        return snapshot?.adapterName ?? "Adapter attached"
    }
}

/// One figure: what it is, the number, and a line saying what the number
/// is made of. Fixed metrics so a row of them shares baselines.
struct StatFigure: View {
    let title: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(NotchStyle.Font.captionEmphasis)
                .foregroundStyle(NotchStyle.Ink.tertiary)
            Text(value)
                .font(NotchStyle.Font.metric)
                .foregroundStyle(NotchStyle.Ink.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(NotchStyle.Font.footnote)
                    .foregroundStyle(NotchStyle.Ink.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Low Power Mode, said in words; the yellow only echoes the system's own
/// low-power battery colour.
struct LowPowerBadge: View {
    var body: some View {
        Text("Low Power")
            .font(NotchStyle.Font.captionEmphasis)
            .foregroundStyle(BatteryInk.lowPower)
            .padding(.horizontal, NotchStyle.Spacing.s)
            .padding(.vertical, 3)
            .background(Capsule().fill(BatteryInk.lowPower.opacity(0.18)))
            .accessibilityLabel("Low Power Mode on")
    }
}
