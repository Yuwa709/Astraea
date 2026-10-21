import SwiftUI

/// The first real feature: always-on machine stats.
///
/// Holds no timer of its own — it starts and stops the shared service on the
/// visibility callbacks, which is how hard rule 9 is honoured without every
/// module reimplementing suspension.
@MainActor
final class SystemStatsModule: NotchModule {

    /// Permanent. Persisted as a settings key; renaming it would silently
    /// reset every user's preference for this module.
    let id: ModuleID = "system-stats"
    let displayName = "System Stats"
    let priority: ModulePriority = .ambient
    var isEnabled: Bool = true

    private let service: SystemStatsService

    init(service: SystemStatsService) {
        self.service = service
    }

    func makeCompactView() -> AnyView {
        AnyView(SystemStatsCompactView(service: service))
    }

    /// **No expanded row.** CPU, GPU, memory, disk and battery moved to the
    /// stats page (the trailing chart door), and showing the same numbers a
    /// second time under the media card was the duplication that removal was
    /// meant to end.
    ///
    /// It also means this module is never visible: with no row in the open
    /// stack and no wings, nothing of it is on screen, so its visibility
    /// callbacks do not fire and `SystemStatsService` samples only while the
    /// stats page holds it. The callbacks and `SystemStatsExpandedView` below
    /// are kept intact — nothing is deleted, it simply no longer joins the
    /// expanded standby stack. `NotchCoordinator.content(for:)` filters
    /// on this flag, so the media card is left alone rather than stacked
    /// above an empty view and its 8pt of spacing.
    var hasExpandedContent: Bool { false }

    func makeExpandedView() -> AnyView {
        AnyView(SystemStatsExpandedView(service: service))
    }

    func didBecomeVisible() { service.start() }
    func didResignVisible() { service.stop() }
}

/// Not currently drawn: the collapsed panel shows only module wings, and the
/// coordinator builds content for the open panel alone. Kept for reuse.
struct SystemStatsCompactView: View {
    let service: SystemStatsService

    var body: some View {
        HStack(spacing: 10) {
            if let cpu = service.stats.cpuFraction {
                StatChip(symbol: "cpu", text: percent(cpu))
            }
            if let memory = service.stats.memoryFraction {
                StatChip(symbol: "memorychip", text: percent(memory))
            }
            if let battery = service.stats.battery {
                StatChip(symbol: batterySymbol(battery), text: percent(battery.charge))
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func batterySymbol(_ battery: BatterySample) -> String {
        battery.isCharging ? "battery.100.bolt" : "battery.50"
    }
}

/// Shown when the notch is expanded.
struct SystemStatsExpandedView: View {
    let service: SystemStatsService

    var body: some View {
        HStack(spacing: 18) {
            gauge("CPU", service.stats.cpuFraction)
            gauge("MEM", service.stats.memoryFraction)
            gauge("GPU", service.stats.gpuFraction)
            if let battery = service.stats.battery {
                gauge("BATT", battery.charge)
            }
            if let free = service.stats.diskFreeBytes {
                labelled("DISK", ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
        }
        .foregroundStyle(.white)
    }

    /// A stat that cannot be read is omitted, never shown as zero.
    @ViewBuilder
    private func gauge(_ title: String, _ value: Double?) -> some View {
        if let value {
            labelled(title, "\(Int((value * 100).rounded()))%")
        }
    }

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }
}

private struct StatChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
    }
}
