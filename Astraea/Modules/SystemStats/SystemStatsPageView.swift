import SwiftUI

/// The stats door: everything the data layer already reads, on one screen.
///
/// The battery card across the top: the charge, a level bar, and how long
/// until full and until empty, which is what someone opening the page came
/// to see. Under it two equal cards side by side: the machine's usage, whose
/// last row leads to the apps behind it, and the pack's long-term figures
/// beside the adapter. Reads only what `BatteryService` and
/// `SystemStatsService` publish; this view adds no IOKit of its own.
///
/// No header: the title rides in the chrome band beside Back (2026-11-04),
/// so the first card sits just under the neck.
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
    /// Opens the resource page; nil hides its row.
    var onShowResources: (() -> Void)?

    /// 560pt. With the overlay's 32pt side border either side the panel comes
    /// to 624pt, inside the 690 ceiling with 66pt to spare — unlike the
    /// resting shelf, which sits exactly on it.
    static let contentWidth: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.m) {
            BatteryOverviewCard(snapshot: battery.snapshot)
            HStack(alignment: .top, spacing: NotchStyle.Spacing.s) {
                StatsSection("Usage") {
                    SystemStatsMachineRows(stats: stats.stats, onShowResources: onShowResources)
                }
                StatsSection("Battery Details") {
                    BatteryDetailsGrid(snapshot: battery.snapshot)
                }
            }
            // Both cards take the taller one's height, so their bottoms meet.
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .foregroundStyle(NotchStyle.Ink.primary)
    }
}

/// A labelled card that fills its share of the row, width and height.
private struct StatsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NotchSectionLabel(title)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .notchCard()
        }
        .frame(maxWidth: .infinity)
    }
}

/// The pack's long-term figures and the adapter, two by two: what the
/// battery is, beside what is feeding it.
///
/// Condition is macOS's verdict and keeps its own cell and provenance
/// line, so it is never read as the same number as Capacity, which is a
/// ratio Astraea computes. Absent rather than guessed when the system
/// declines to say.
struct BatteryDetailsGrid: View {
    let snapshot: BatterySnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            }
            // The two rows split the card's height, so the grid's last
            // line meets the usage card's last row across the gap.
            Spacer(minLength: NotchStyle.Spacing.m)
            HStack(alignment: .top, spacing: NotchStyle.Spacing.m) {
                StatFigure(title: "Condition",
                           value: snapshot?.conditionDescription ?? "Not reported",
                           detail: "Reported by macOS")
                StatFigure(title: "Adapter", value: adapterValue, detail: adapterDetail)
            }
        }
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
                .font(.system(size: 15, weight: .semibold, design: .rounded))
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
