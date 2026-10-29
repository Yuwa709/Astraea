import AppKit
import SwiftUI

/// The picker the notch opens to when a window is dragged into it: each
/// preset drawn as a miniature of the screen the window came from, divided
/// into its zones. The user keeps the button held, moves onto a zone, and
/// lets go.
///
/// Deliberately quiet: flat tiles, no borders, no header. The one loud
/// element is the hovered zone, which turns the accent colour and holds the
/// dragged app's icon. The label under the active tile names that zone, so
/// the readout sits where the eye already is.
///
/// Nothing here receives the mouse. The button is held by the window drag in
/// another app, so the panel gets no hover or click events; the module
/// hit-tests the cursor against the zones' views and sets `hoveredZoneID`.
struct WindowLayoutPickerView: View {
    let state: WindowLayoutState

    var body: some View {
        VStack(spacing: 10) {
            // Rows 14pt apart, as tiles are, so `ZoneAnchors.presetOutset`
            // closes the gap between rows too.
            VStack(spacing: 14) {
                ForEach(Self.rows(of: state.presets), id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(row) { preset in
                            PresetTile(preset: preset, state: state)
                        }
                    }
                }
            }
            if !state.isTrusted {
                // Says how to fix it: dropping is what raises the system prompt.
                Label("Drop to allow Accessibility access", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .foregroundStyle(.white)
    }

    /// At most five tiles a row, the rows as even as they can be: six
    /// presets are three and three, not five and one.
    static let maxPerRow = 5

    static func rows(of presets: [LayoutPreset]) -> [[LayoutPreset]] {
        guard !presets.isEmpty else { return [] }
        let rowCount = (presets.count + maxPerRow - 1) / maxPerRow
        let perRow = (presets.count + rowCount - 1) / rowCount
        return stride(from: 0, to: presets.count, by: perRow).map {
            Array(presets[$0..<min($0 + perRow, presets.count)])
        }
    }
}

/// Hard rule 8: every animation in the picker goes through this, so Reduce
/// Motion turns all of them into instant changes.
private func pickerAnimation(_ animation: Animation) -> Animation? {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
}

/// One preset: a screen-shaped tile holding its zones, a label underneath
/// that names the preset, or the hovered zone while the cursor is on it.
private struct PresetTile: View {
    let preset: LayoutPreset
    let state: WindowLayoutState

    @Environment(\.colorSchemeContrast) private var contrast

    /// Height is fixed; width follows the source screen's shape, so the tile
    /// previews the screen the window will land on.
    static let height: CGFloat = 66
    /// Tile edge to zones, and zone to zone. Radii are concentric:
    /// tile 8 − inset 3 = zone 5.
    static let inset: CGFloat = 3
    static let gap: CGFloat = 2
    static let radius: CGFloat = 8

    private var hoveredZone: LayoutZone? {
        preset.zones.first { $0.id == state.hoveredZoneID }
    }

    /// Another preset has the cursor: step back so the choice reads alone.
    /// Keyed off the preset's whole area, not the zone, so the gaps between
    /// zones and between tiles never flash the others back.
    private var isReceded: Bool {
        state.hoveredPresetID != nil && state.hoveredPresetID != preset.id
    }

    private var size: CGSize {
        CGSize(width: (Self.height * state.screenAspect).rounded(), height: Self.height)
    }

    var body: some View {
        VStack(spacing: 6) {
            zones
                .padding(Self.inset - Self.gap / 2)
                .background(tile)
            Text(hoveredZone?.name ?? preset.name)
                .font(.system(size: 11, weight: hoveredZone == nil ? .medium : .semibold))
                // 55% white on black is 6.6:1; 92% is 18:1.
                .foregroundStyle(.white.opacity(hoveredZone == nil ? 0.55 : 0.92))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .background(AnchorView(id: preset.id, anchors: state.anchors, presetID: nil))
        .opacity(isReceded ? 0.5 : 1)
        .animation(pickerAnimation(.easeOut(duration: 0.12)), value: state.hoveredZoneID)
        .animation(pickerAnimation(.easeOut(duration: 0.12)), value: state.hoveredPresetID)
    }

    private var zones: some View {
        let inner = CGSize(width: size.width - (Self.inset * 2 - Self.gap),
                           height: size.height - (Self.inset * 2 - Self.gap))
        return ZStack(alignment: .topLeading) {
            ForEach(preset.zones) { zone in
                ZoneCell(zone: zone, presetID: preset.id, state: state)
                    .frame(width: max(0, zone.unitRect.width * inner.width - Self.gap),
                           height: max(0, zone.unitRect.height * inner.height - Self.gap))
                    .offset(x: zone.unitRect.minX * inner.width + Self.gap / 2,
                            y: zone.unitRect.minY * inner.height + Self.gap / 2)
            }
        }
        .frame(width: inner.width, height: inner.height, alignment: .topLeading)
    }

    /// Flat, borderless; a hairline appears only under Increase Contrast.
    private var tile: some View {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return shape
            .fill(.white.opacity(0.06))
            .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.45 : 0),
                                        lineWidth: 1))
    }
}

/// A zone. Flat at rest; the accent colour with the dragged app's icon while
/// the cursor is over it.
private struct ZoneCell: View {
    let zone: LayoutZone
    let presetID: String
    let state: WindowLayoutState

    @Environment(\.colorSchemeContrast) private var contrast

    private var isHovered: Bool { state.hoveredZoneID == zone.id }

    var body: some View {
        GeometryReader { proxy in
            let shape = RoundedRectangle(cornerRadius: PresetTile.radius - PresetTile.inset,
                                         style: .continuous)
            ZStack {
                shape.fill(isHovered ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.white.opacity(restOpacity)))
                    .animation(nil, value: isHovered)
                if isHovered, let icon = state.appIcon {
                    let side = min(22, proxy.size.height * 0.62, proxy.size.width * 0.62)
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }
        }
        .background(AnchorView(id: zone.id, anchors: state.anchors, presetID: presetID))
        // The fill swaps instantly; only the icon's arrival is animated.
        .animation(pickerAnimation(.spring(response: 0.24, dampingFraction: 0.78)),
                   value: isHovered)
    }

    private var restOpacity: Double { contrast == .increased ? 0.3 : 0.13 }
}

/// An invisible NSView behind each preset and each zone, registered so the
/// module can ask it where it is on screen. See `ZoneAnchors`.
private struct AnchorView: NSViewRepresentable {
    let id: String
    let anchors: ZoneAnchors
    /// Set for a zone: the preset it belongs to. Nil for a preset.
    let presetID: String?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(nsView)
    }

    private func register(_ view: NSView) {
        if let presetID {
            anchors.register(view, zoneID: id, presetID: presetID)
        } else {
            anchors.register(view, presetID: id)
        }
    }
}
