import SwiftUI

/// CPU, GPU, memory and disk as compact rows at the foot of the stats page.
///
/// A stat that cannot be read is shown as a dash with no bar, matching
/// `SystemStats`'s rule that a missing reading is never rendered as zero.
struct SystemStatsMachineRows: View {
    let stats: SystemStats

    var body: some View {
        VStack(spacing: 6) {
            row("CPU", symbol: "cpu", fraction: stats.cpuFraction)
            row("GPU", symbol: "cpu.fill", fraction: stats.gpuFraction)
            row("Memory", symbol: "memorychip", fraction: stats.memoryFraction)
            diskRow
        }
    }

    private var diskRow: some View {
        let fraction: Double? = {
            guard let free = stats.diskFreeBytes, let total = stats.diskTotalBytes, total > 0
            else { return nil }
            return Double(total - free) / Double(total)
        }()
        let detail = stats.diskFreeBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) + " free"
        }
        return row("Disk", symbol: "internaldrive", fraction: fraction, trailing: detail)
    }

    private func row(_ title: String, symbol: String,
                     fraction: Double?, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 12)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    if let fraction {
                        Capsule()
                            .fill(.white.opacity(0.55))
                            .frame(width: max(2, geometry.size.width * min(1, max(0, fraction))))
                    }
                }
            }
            .frame(height: 5)
            Text(trailing ?? fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 74, alignment: .trailing)
        }
        .frame(height: 14)
    }
}
