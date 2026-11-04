import SwiftUI

/// CPU, GPU, memory and disk, one labelled level bar each, stacked in the
/// stats page's Usage card; the card itself is the page's (`StatsSection`).
///
/// A stat that cannot be read is shown as a dash with no bar, matching
/// `SystemStats`'s rule that a missing reading is never rendered as zero.
/// The bars are neutral white: a load has no good or bad colour here.
///
/// The card's last row leads to the resource page: a grouped-list row with
/// a hairline above and a chevron, the way Settings leads from a summary to
/// its detail, rather than a bordered button inside the card.
struct SystemStatsMachineRows: View {
    let stats: SystemStats
    /// Opens the resource page. Nil hides the row, where no resource
    /// service is wired up.
    var onShowResources: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                MachineStatRow(title: "CPU", symbol: "cpu", fraction: stats.cpuFraction)
                MachineStatRow(title: "GPU", symbol: "cpu.fill", fraction: stats.gpuFraction)
                MachineStatRow(title: "Memory", symbol: "memorychip", fraction: stats.memoryFraction)
                MachineStatRow(title: "Disk", symbol: "internaldrive",
                               fraction: diskFraction, trailing: diskDetail)
            }
            if let onShowResources {
                // Pinned to the card's foot when the neighbouring card is
                // the taller one.
                Spacer(minLength: 10)
                ResourceUsageRow(action: onShowResources)
            }
        }
    }

    private var diskFraction: Double? {
        guard let free = stats.diskFreeBytes, let total = stats.diskTotalBytes, total > 0
        else { return nil }
        return Double(total - free) / Double(total)
    }

    private var diskDetail: String? {
        stats.diskFreeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free"
        }
    }
}

/// One stat: glyph, name, a bar of how much is in use, and the figure.
/// Fixed label and figure widths, so the four bars start and end together.
struct MachineStatRow: View {
    let title: String
    let symbol: String
    let fraction: Double?
    var trailing: String?

    var body: some View {
        HStack(spacing: NotchStyle.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(NotchStyle.Ink.tertiary)
                .frame(width: 14)
            Text(title)
                .font(NotchStyle.Font.captionEmphasis)
                .foregroundStyle(NotchStyle.Ink.secondary)
                .frame(width: 50, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchStyle.Fill.selected)
                    if let fraction {
                        Capsule()
                            .fill(NotchStyle.Ink.secondary)
                            .frame(width: max(6, geometry.size.width * min(1, max(0, fraction))))
                    }
                }
            }
            .frame(height: 6)
            .animation(NotchStyle.motion(), value: fraction)
            Text(value)
                .font(NotchStyle.Font.captionEmphasis)
                .foregroundStyle(NotchStyle.Ink.primary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 80, alignment: .trailing)
        }
        .frame(height: 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value == "—" ? "Unavailable" : value)
    }

    private var value: String {
        trailing ?? fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

/// The way into the resource page: the Usage card's last row. A hairline
/// across the card, then the label and a trailing chevron. Clear at rest,
/// the shared hover fill under the pointer; its highlight runs past the
/// text to the card's padding, as a list row's does.
struct ResourceUsageRow: View {
    let action: () -> Void

    /// Out into the card's 12pt padding, less a margin for the corners.
    private static let bleed: CGFloat = 6

    var body: some View {
        VStack(spacing: 4) {
            Rectangle()
                .fill(NotchStyle.Fill.separator)
                .frame(height: 1)
            Button(action: action) {
                HStack(spacing: NotchStyle.Spacing.s) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 11))
                        .foregroundStyle(NotchStyle.Ink.tertiary)
                        .frame(width: 14)
                    Text("Resource Usage")
                        .font(NotchStyle.Font.captionEmphasis)
                        .foregroundStyle(NotchStyle.Ink.secondary)
                    Spacer(minLength: NotchStyle.Spacing.s)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NotchStyle.Ink.tertiary)
                }
                .padding(.horizontal, Self.bleed)
                .frame(height: 24)
            }
            .buttonStyle(NotchRowButtonStyle(radius: NotchStyle.Radius.thumb, resting: .clear))
            .padding(.horizontal, -Self.bleed)
            .padding(.bottom, -4)
            .help("Apps ranked by energy, memory and CPU")
            .accessibilityLabel("Resource usage")
            .accessibilityHint("Shows apps ranked by energy, memory and CPU use")
        }
    }
}
