import AppKit
import SwiftUI

/// The picker the notch opens to when a window is dragged into it: each
/// preset drawn as a little screen divided into its zones. The user keeps
/// the button held, moves onto a zone, and lets go.
///
/// Nothing here receives the mouse. The button is held by the window drag in
/// another app, so the panel gets no hover or click events; the module
/// hit-tests the cursor against the zones' views and sets `hoveredZoneID`.
struct WindowLayoutPickerView: View {
    let state: WindowLayoutState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 14) {
                ForEach(state.presets) { preset in
                    PresetThumbnail(preset: preset, state: state)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
            Text(state.window.map { "Place \($0.ownerName)" } ?? "Place window")
                .lineLimit(1)
            Spacer(minLength: 0)
            if !state.isTrusted {
                Text("Needs Accessibility access")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12, weight: .semibold))
    }
}

/// One preset: a screen-shaped frame holding its zones, name underneath.
private struct PresetThumbnail: View {
    let preset: LayoutPreset
    let state: WindowLayoutState

    static let size = CGSize(width: 104, height: 66)
    private static let gap: CGFloat = 3

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                ForEach(preset.zones) { zone in
                    ZoneCell(zone: zone, state: state)
                        .frame(width: max(0, zone.unitRect.width * Self.size.width - Self.gap * 2),
                               height: max(0, zone.unitRect.height * Self.size.height - Self.gap * 2))
                        .offset(x: zone.unitRect.minX * Self.size.width + Self.gap,
                                y: zone.unitRect.minY * Self.size.height + Self.gap)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
            Text(preset.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
    }
}

/// A zone, lit while the cursor is over it.
private struct ZoneCell: View {
    let zone: LayoutZone
    let state: WindowLayoutState

    private var isHovered: Bool { state.hoveredZoneID == zone.id }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isHovered ? Color.accentColor : .white.opacity(0.14))
            .background(ZoneAnchorView(zoneID: zone.id, anchors: state.anchors))
            // Hard rule 8: the highlight is instant under Reduce Motion.
            .animation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                       ? nil : .easeOut(duration: 0.12), value: isHovered)
    }
}

/// An invisible NSView behind each zone, registered so the module can ask
/// it where it is on screen. See `ZoneAnchors`.
private struct ZoneAnchorView: NSViewRepresentable {
    let zoneID: String
    let anchors: ZoneAnchors

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchors.register(view, zoneID: zoneID)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchors.register(nsView, zoneID: zoneID)
    }
}
