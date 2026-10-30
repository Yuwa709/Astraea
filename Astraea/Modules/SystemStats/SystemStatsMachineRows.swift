import SwiftUI

/// CPU, GPU, memory and disk on one card at the foot of the stats page, as
/// a two-by-two grid of labelled level bars.
///
/// A stat that cannot be read is shown as a dash with no bar, matching
/// `SystemStats`'s rule that a missing reading is never rendered as zero.
/// The bars are neutral white: a load has no good or bad colour here.
struct SystemStatsMachineRows: View {
    let stats: SystemStats

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: NotchStyle.Spacing.l) {
                MachineStatRow(title: "CPU", symbol: "cpu", fraction: stats.cpuFraction)
                MachineStatRow(title: "GPU", symbol: "cpu.fill", fraction: stats.gpuFraction)
            }
            HStack(spacing: NotchStyle.Spacing.l) {
                MachineStatRow(title: "Memory", symbol: "memorychip", fraction: stats.memoryFraction)
                MachineStatRow(title: "Disk", symbol: "internaldrive",
                               fraction: diskFraction, trailing: diskDetail)
            }
        }
        .notchCard()
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
