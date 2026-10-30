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
    /// Also the switch for the battery wings: off stops their monitor.
    var isEnabled: Bool = true {
        didSet { isEnabled ? battery?.start() : battery?.stop() }
    }

    private let service: SystemStatsService
    /// Nil in tests that exercise the module without a power source.
    private let battery: BatteryWingMonitor?

    /// Fired when the battery wings appear or disappear.
    var onPresenceChange: (() -> Void)?

    init(service: SystemStatsService, battery: BatteryWingMonitor? = nil) {
        self.service = service
        self.battery = battery
        battery?.onPresenceChange = { [weak self] in self?.onPresenceChange?() }
        if isEnabled { battery?.start() }
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

    /// Battery wings: time to empty on the left, charge on the right. Last
    /// in registration order, so media artwork and the update badge outrank
    /// them; they fill the wings only when nothing else wants them. Nil on a
    /// Mac with no battery, which keeps the collapsed notch invisible there.
    func makeCompactLeadingView() -> AnyView? {
        guard isEnabled, let battery, battery.reading != nil else { return nil }
        // Nudged toward the housing; centred it sat a touch far out
        // (user-observed 2026-10-21).
        return AnyView(BatteryWingTimeLeft(monitor: battery).offset(x: 2))
    }

    func makeCompactTrailingView() -> AnyView? {
        guard isEnabled, let battery, battery.reading != nil else { return nil }
        // Pulled in from the outer corner's flare, as media's waveform is.
        return AnyView(BatteryWingCharge(monitor: battery).offset(x: -3))
    }

    func didBecomeVisible() { service.start() }
    func didResignVisible() { service.stop() }
}

/// Not currently drawn: the collapsed panel shows only module wings, and the
/// coordinator builds content for the open panel alone. Kept for reuse.
struct SystemStatsCompactView: View {
    let service: SystemStatsService

    var body: some View {
        HStack(spacing: NotchStyle.Spacing.m) {
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
        HStack(spacing: NotchStyle.Spacing.l + 2) {
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
        .foregroundStyle(NotchStyle.Ink.primary)
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
                .font(NotchStyle.Font.footnote.weight(.medium))
                .foregroundStyle(NotchStyle.Ink.tertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StatChip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: NotchStyle.Spacing.xs) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(NotchStyle.Ink.secondary)
            Text(text)
                .font(NotchStyle.Font.captionEmphasis)
                .foregroundStyle(NotchStyle.Ink.primary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
