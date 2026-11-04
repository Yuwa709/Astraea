import AppKit
import SwiftUI

/// The stats page's second screen: running apps ranked by what they use,
/// each with a Quit button. Reached from the Usage card's "Resource Usage"
/// row on the stats page; the chrome's back chevron returns there.
///
/// The stats page's 560pt width. Fixed height too: the list scrolls inside
/// a card of `visibleRows` rows whatever the app count, so apps launching
/// and quitting never resize the panel. The 26pt control row, an 8pt gap
/// and 280pt of list come to 314pt, within a few points of the stats page,
/// so going between the two is close to no morph at all. The title rides
/// in the chrome band, as on the stats page.
///
/// Laid out like Activity Monitor's list under a scope control: the
/// metric picker and what it sorts by on one line, then the ranked rows.
struct ResourceUsagePageView: View {

    @Bindable var service: ResourceUsageService

    static let rowHeight: CGFloat = 40
    static let visibleRows = 7
    static let listHeight = rowHeight * CGFloat(visibleRows)

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.s) {
            HStack(spacing: NotchStyle.Spacing.m) {
                NotchSegmentedControl(selection: $service.metric, segments: [
                    .init(value: .energy, label: "Energy"),
                    .init(value: .memory, label: "Memory"),
                    .init(value: .cpu, label: "CPU"),
                ], segmentWidth: 72)
                Spacer(minLength: NotchStyle.Spacing.s)
                Text(service.metric.sortDescription)
                    .font(NotchStyle.Font.caption)
                    .foregroundStyle(NotchStyle.Ink.tertiary)
                    .lineLimit(1)
            }
            list
                .frame(height: Self.listHeight)
                .background(card.fill(NotchStyle.Fill.card))
                .clipShape(card)
        }
        .frame(width: SystemStatsPageView.contentWidth, alignment: .leading)
        .foregroundStyle(NotchStyle.Ink.primary)
    }

    private var card: RoundedRectangle {
        RoundedRectangle(cornerRadius: NotchStyle.Radius.card, style: .continuous)
    }

    @ViewBuilder
    private var list: some View {
        let rows = service.ranked
        if service.phase != .ready, service.metric.needsTwoSamples || rows.isEmpty {
            // Energy and CPU need two samples; until then the page says it is
            // measuring rather than ranking everyone at zero.
            MeasuringState()
        } else if rows.isEmpty {
            NotchEmptyState(symbol: "app.dashed", message: "No running apps to show")
        } else {
            ScrollView(.vertical, showsIndicators: rows.count > Self.visibleRows) {
                // Not animated on refresh: the ranking reshuffles most
                // samples, and every animated frame redraws the list in
                // software (~8% of a core, measured 2026-11-04). A metric
                // switch still animates, through the segmented control.
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ResourceAppRow(usage: row, metric: service.metric, service: service,
                                       showsSeparator: index < rows.count - 1)
                    }
                }
            }
        }
    }
}

private struct MeasuringState: View {
    var body: some View {
        VStack(spacing: NotchStyle.Spacing.s) {
            ProgressView()
                .controlSize(.small)
                .tint(NotchStyle.Ink.secondary)
            Text("Measuring…")
                .font(NotchStyle.Font.caption)
                .foregroundStyle(NotchStyle.Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Measuring resource usage")
    }
}

/// One app: icon, name with CPU and memory beneath, the ranked figure, Quit.
private struct ResourceAppRow: View {
    let usage: ResourceAppUsage
    let metric: ResourceMetric
    let service: ResourceUsageService
    let showsSeparator: Bool

    /// The row's 12pt inset, the 24pt icon and its 10pt gap.
    private static let separatorInset: CGFloat = 46

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(usage.app.name)
                    .font(NotchStyle.Font.bodyEmphasis)
                    .foregroundStyle(NotchStyle.Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondary)
                    .font(NotchStyle.Font.footnote)
                    .foregroundStyle(NotchStyle.Ink.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: NotchStyle.Spacing.s)
            Text(primary)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(NotchStyle.Ink.primary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
            quit
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: ResourceUsagePageView.rowHeight)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle().fill(NotchStyle.Fill.separator).frame(height: 1)
                    .padding(.leading, Self.separatorInset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(usage.app.name), \(secondary)")
    }

    private var icon: some View {
        Group {
            if let image = service.icon(for: usage.app) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 16))
                    .foregroundStyle(NotchStyle.Ink.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    private var secondary: String {
        "CPU \(ResourceFormat.cpu(usage.cpuPercent)) · RAM \(ResourceFormat.memory(usage.memoryBytes))"
    }

    private var primary: String {
        switch metric {
        case .energy: ResourceFormat.power(usage.watts)
        case .memory: ResourceFormat.memory(usage.memoryBytes)
        case .cpu: ResourceFormat.cpu(usage.cpuPercent)
        }
    }

    @ViewBuilder
    private var quit: some View {
        if usage.app.canQuit {
            let isQuitting = service.quitting[usage.id] != nil
            let refused = service.quitRefused.contains(usage.id)
            Button(isQuitting ? "Quitting…" : "Quit") { service.quit(usage.app) }
                .buttonStyle(ResourceQuitButtonStyle())
                .disabled(isQuitting)
                .help(refused ? "\(usage.app.name) didn't accept the request to quit"
                              : "Quit \(usage.app.name)")
                .accessibilityLabel(isQuitting ? "Quitting \(usage.app.name)" : "Quit \(usage.app.name)")
        }
    }
}

/// A small filled capsule, the App Store's row-button shape: a quiet fill
/// at rest, brighter under the pointer. Neutral, not red: quitting is the
/// user's ordinary choice here, and the app itself still asks about
/// unsaved work.
private struct ResourceQuitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ResourceQuitButtonBody(configuration: configuration)
    }
}

private struct ResourceQuitButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let shape = Capsule()
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(!isEnabled ? NotchStyle.Ink.tertiary
                             : hovering ? NotchStyle.Ink.primary : NotchStyle.Ink.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 22)
            .background(shape.fill(configuration.isPressed ? NotchStyle.Ink.quaternary
                                   : isEnabled && hovering ? NotchStyle.Fill.selected : NotchStyle.Fill.hover))
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(NotchStyle.hoverMotion, value: hovering)
    }
}
