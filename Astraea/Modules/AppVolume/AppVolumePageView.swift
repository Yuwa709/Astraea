import AppKit
import SwiftUI

/// The mixer page: one row per app that has played audio this session, with
/// a volume slider each. Composed by the coordinator, the way the stats
/// page is (v1 plan, decision 2).
///
/// **Spotify's and Music's rows work now; every other slider is inert.**
/// Those two use the player's own AppleScript `sound volume` (decision 3),
/// which needs no tap engine, and their rows share state with the player
/// screen's slider through `ScriptedPlayerVolumes` — moving one moves the
/// other. Every other row's slider is dimmed and disabled until the tap
/// engine (Phase 5). Never-tap apps show greyed with the reason instead of
/// a working slider (decision 9).
///
/// V2: every adjustable row also carries an output menu at its trailing
/// edge (`OutputMenu`), and V2 Phase 3 a bass boost badge just before it
/// (`BassBoostButton`). Neither changes the row height, so choosing an
/// output or a boost never resizes the panel.
///
/// Fixed 420pt content width, the clipboard page's, so the two doors read
/// as one family. Height follows the row count up to eight rows, then the
/// list scrolls: the panel's 460pt ceiling minus the neck and padding
/// leaves ~388pt of content, and eight 40pt rows plus the header fill it.
struct AppVolumePageView: View {

    var service: AppVolumeService

    static let contentWidth: CGFloat = 420
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 6
    /// Past this many rows the list stops growing and scrolls instead.
    static let maxVisibleRows = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let warning = AppVolumeService.mixerConflictWarning(names: service.conflictingMixers) {
                conflictBanner(warning)
            }
            content
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("APP VOLUME")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            let playing = service.mixerRows.filter(\.isPlaying).count
            if playing > 0 {
                Text("\(playing) playing")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    /// Another mixer is running. Says what that does to the spectrum, not
    /// merely that an app is open — a warning nobody can act on is noise.
    /// Costs one row's worth of height, which `listHeight` gives back by
    /// showing one row fewer, so the panel's ceiling is unchanged.
    private func conflictBanner(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
            Text(warning)
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.orange.opacity(0.9))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        let rows = service.mixerRows
        if rows.isEmpty {
            Text("Nothing has played audio yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity)
                .frame(height: 88)
        } else {
            ScrollView(.vertical, showsIndicators: rows.count > Self.maxVisibleRows) {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(rows, id: \.owner.key) { row in
                        MixerRowView(row: row, service: service)
                    }
                }
            }
            .frame(height: Self.listHeight(rowCount: rows.count,
                                           warningShown: !service.conflictingMixers.isEmpty))
        }
    }

    /// The list's height for a row count: exact up to `maxVisibleRows`,
    /// pinned there beyond. Pure so the eight-row cap is a test, not a
    /// hardware session.
    nonisolated static func listHeight(rowCount: Int, warningShown: Bool = false) -> CGFloat {
        let cap = warningShown ? maxVisibleRows - 1 : maxVisibleRows
        let visible = min(rowCount, cap)
        return CGFloat(visible) * rowHeight + CGFloat(max(visible - 1, 0)) * rowSpacing
    }
}

/// One app's row: icon, name and state caption, and the slider. A never-tap
/// row is greyed with its reason and a disabled slider — explained, not
/// broken-looking. Non-scripted rows carry the tap engine's slider (Phase
/// 5), live while taps are on and the engine reports the row workable.
private struct MixerRowView: View {
    let row: MixerRow
    let service: AppVolumeService

    /// Close to a never-tap row's whole-row 0.4, so every slider that does
    /// nothing reads the same.
    static let inertSliderOpacity: Double = 0.45

    /// The player that owns this row's volume, when it is Spotify or Music
    /// and the media module is on. Nil means the tap-engine path.
    private var scriptedPlayer: ScriptedPlayerVolumes? {
        guard let players = service.playerVolumes, row.neverTapReason == nil,
              players.handlesVolume(for: row.owner.key) else { return nil }
        return players
    }

    private var engineReason: String? {
        if case .inert(let reason) = row.engineState { return reason }
        return nil
    }

    /// Routing and boost both need a tap, so both need taps on and the
    /// capture grant. Either control still shows its saved choice while
    /// disabled.
    static func tapControlsEnabled(_ row: MixerRow, service: AppVolumeService) -> Bool {
        service.tapsEnabled && row.engineState != .inert(reason: "permission needed")
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(owner: row.owner)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.owner.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(caption)
                    .font(.system(size: 9))
                    .foregroundStyle(captionColor)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            if let scriptedPlayer {
                ScriptedVolumeSlider(bundleID: row.owner.key, players: scriptedPlayer)
            } else if row.neverTapReason == nil, service.tapsEnabled, engineReason == nil,
                      !AppVolumeService.scriptedPlayerKeys.contains(row.owner.key) {
                // The identity check keeps Spotify and Music off the tap
                // path even while the Media module (their slider's owner)
                // is disabled: their row goes inert, never to a tap.
                TapVolumeSlider(ownerKey: row.owner.key, service: service)
            } else {
                // Dimmed and disabled: never-tap, taps off, or an engine
                // reason the caption explains. A never-tap row is already
                // dimmed whole, so its slider takes no second dimming.
                Slider(value: .constant(1.0))
                    .controlSize(.small)
                    .disabled(true)
                    .opacity(row.neverTapReason == nil ? Self.inertSliderOpacity : 1)
                    .accessibilityHidden(true)
            }
            // Never-tap apps are never tapped, so they cannot be routed or
            // boosted.
            if row.neverTapReason == nil {
                HStack(spacing: 4) {
                    BassBoostButton(ownerKey: row.owner.key, service: service,
                                    isEnabled: Self.tapControlsEnabled(row, service: service))
                    OutputMenu(row: row, service: service, route: route)
                }
            }
        }
        .frame(height: AppVolumePageView.rowHeight)
        .opacity(row.neverTapReason == nil ? 1 : 0.4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.owner.name), \(caption)")
    }

    private var route: OutputRoute { service.route(for: row.owner.key) }

    private var caption: String {
        AppVolumeService.caption(for: row, scripted: scriptedPlayer != nil,
                                 tapsEnabled: service.tapsEnabled, route: route,
                                 boosted: service.bass(for: row.owner.key) > 0)
    }

    /// An unplugged choice is the one caption that needs noticing.
    private var captionColor: Color {
        if case .disconnected = route { return .orange.opacity(0.9) }
        return .white.opacity(0.45)
    }
}

/// The row's output choice (V2 routing): "System default" first, then the
/// current output devices by name, each checked when chosen. A device that
/// cannot be a target is listed disabled, with the reason, rather than
/// hidden. An unplugged choice stays listed — checked, disabled, marked
/// disconnected — so the menu never shows the fallback as if it were the
/// choice.
///
/// A system menu, so there is no SwiftUI animation here to gate for Reduce
/// Motion (hard rule 8), and opening it resizes nothing.
private struct OutputMenu: View {
    let row: MixerRow
    let service: AppVolumeService
    let route: OutputRoute

    private var isEnabled: Bool { MixerRowView.tapControlsEnabled(row, service: service) }

    var body: some View {
        Menu {
            Toggle("System default", isOn: choice(nil))
            Divider()
            ForEach(service.outputDevices, id: \.uid) { device in
                let reason = AppVolumeService.routeUnavailableReason(device)
                Toggle(reason.map { "\(device.name) (\($0))" } ?? device.name,
                       isOn: choice(device.uid))
                    .disabled(reason != nil)
            }
            if case .disconnected(_, let name) = route {
                Toggle("\(name ?? "Saved output") (disconnected)", isOn: .constant(true))
                    .disabled(true)
            }
        } label: {
            Image(systemName: route == .systemDefault ? "hifispeaker" : "hifispeaker.fill")
                .font(.system(size: 11))
                .foregroundStyle(glyphColor)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : MixerRowView.inertSliderOpacity)
        .accessibilityLabel("Output")
        .accessibilityValue(accessibilityValue)
    }

    private var glyphColor: Color {
        switch route {
        case .systemDefault: return .white.opacity(0.55)
        case .device: return .white.opacity(0.9)
        case .disconnected: return .orange.opacity(0.9)
        }
    }

    private var accessibilityValue: String {
        switch route {
        case .systemDefault: return "System default"
        case .device(_, let name): return name
        case .disconnected(_, let name): return "\(name ?? "Saved output"), disconnected"
        }
    }

    /// Checked when this is the saved choice. Choosing the checked item
    /// again changes nothing: a toggle's "off" is never a choice.
    private func choice(_ uid: String?) -> Binding<Bool> {
        let key = row.owner.key
        return Binding(get: { service.output(for: key) == uid },
                       set: { isOn in if isOn { service.setOutput(uid, for: key) } })
    }
}

/// The row's bass boost (V2 Phase 3), drawn as a sergeant's badge: three
/// stacked chevrons lit from the bottom up — none for off, one for +6 dB,
/// two for +12, all three for +18. A click steps up one level and wraps
/// from +18 to off; a right-click clears to off from any level. There is no
/// step-down gesture, by the owner's choice.
///
/// The stack draws 9.75 × 12 pt of ink, the speaker glyph's own size at
/// the output menu's 11 pt (measured from the rendered symbol, 2026-09-28),
/// so the two read as a pair. In a 20×20 frame, the output menu's, so the
/// row keeps its height. The lighting
/// change fades briefly, and is instant under Reduce Motion (hard rule 8).
/// Disabled with the output menu (taps off, no capture grant), but still
/// showing the saved level.
private struct BassBoostButton: View {
    let ownerKey: String
    let service: AppVolumeService
    let isEnabled: Bool

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        let level = service.bass(for: ownerKey)
        Button { service.setBass(BassBoost.next(after: level), for: ownerKey) } label: {
            // Ink: 3 × 2 + 2 × 2.25 + the 1.5 stroke = 12 pt tall, and
            // 8.25 + 1.5 = 9.75 pt wide.
            VStack(spacing: 2.25) {
                ForEach([3, 2, 1], id: \.self) { rank in
                    Chevron()
                        .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 8.25, height: 2)
                        .foregroundStyle(.white.opacity(rank <= level ? 0.95 : 0.28))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: level)
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RightClickCatcher { if isEnabled { service.setBass(0, for: ownerKey) } })
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : MixerRowView.inertSliderOpacity)
        .accessibilityLabel("Bass boost")
        .accessibilityValue(level == 0 ? "Off" : "+\(Int(BassBoost.gainDB(level: level))) dB")
        .accessibilityAction(named: "Turn off") { if isEnabled { service.setBass(0, for: ownerKey) } }
    }

    /// One upward chevron filling its frame.
    private struct Chevron: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            return path
        }
    }
}

/// Takes right-clicks and nothing else. SwiftUI has no right-click gesture
/// on macOS 14, so this view claims a point only while the event being
/// routed is a right mouse-down; every other event falls through to the
/// control underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }
    }
}

/// The tap engine's slider: the position applies live while dragging (the
/// engine ramps each change) and persists on release — the app's own
/// volume is stored as absence. The middle is the app's own volume and the
/// right end twice it (`TapReconciler.maxPosition`); near the middle the
/// knob snaps onto it. Usable on a row that is not playing: the position
/// is remembered and applies the moment the app next outputs.
private struct TapVolumeSlider: View {
    let ownerKey: String
    let service: AppVolumeService
    /// A pointer drag is in progress. VoiceOver and keyboard increments
    /// set the value without one, and may never send the release that
    /// persists it, so a set outside a drag persists at once.
    @State private var dragging = false

    var body: some View {
        // The getter re-reads rather than closing over a value captured at
        // body time: during a drag the knob is drawn from whatever this
        // returns, so a captured constant would pin it in place even once
        // the row re-renders.
        let position = service.tapPosition(for: ownerKey)
        Slider(value: Binding(
                   get: { Double(service.tapPosition(for: ownerKey)) / Double(TapReconciler.maxPosition) },
                   set: {
                       service.setTapPosition(TapReconciler.position(atFraction: $0), for: ownerKey)
                       if !dragging { service.endTapVolumeEdit(for: ownerKey) }
                   }),
               onEditingChanged: { editing in
                   dragging = editing
                   if !editing { service.endTapVolumeEdit(for: ownerKey) }
               })
            .controlSize(.small)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(TapReconciler.sliderValue(atPosition: position)) percent")
    }
}

/// A working slider for Spotify or Music: their own `sound volume`, read
/// and written through the media module so it is the same value as the
/// player screen's slider. A drag is one edit — the module thins the
/// writes (each is a ~17ms Apple Event) and sends the release unthrottled.
/// Disabled while the volume is unknown (never read, or the read failed):
/// a thumb at a guessed position would claim a level nobody read.
private struct ScriptedVolumeSlider: View {
    let bundleID: String
    let players: ScriptedPlayerVolumes

    var body: some View {
        let known = players.volume(for: bundleID)
        Slider(value: Binding(
                   get: { Double(known ?? 100) / 100 },
                   set: { players.setVolume(PlayerVolume.value(atFraction: $0), for: bundleID) }),
               onEditingChanged: { editing in
                   if editing {
                       players.beginVolumeEdit(for: bundleID)
                   } else {
                       players.endVolumeEdit(for: bundleID)
                   }
               })
            .controlSize(.small)
            .disabled(known == nil)
            .accessibilityLabel("Volume")
            .accessibilityValue(known.map { "\($0) percent" } ?? "Unknown")
    }
}

/// The row's 20pt icon: the app's own icon where the owner is an app, a
/// globe for web content, a generic glyph for unbundled tools.
private struct AppIconView: View {
    let owner: AudioOwner

    var body: some View {
        Group {
            if let icon = AppIconStore.icon(for: owner) {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: owner.kind == .webContent ? "globe" : "app.dashed")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .frame(width: 20, height: 20)
    }
}

/// Icon lookups, cached per owner key: `urlForApplication` is a Launch
/// Services query and the rows re-render on every audio event.
@MainActor
enum AppIconStore {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for owner: AudioOwner) -> NSImage? {
        guard owner.kind == .app else { return nil }
        if let cached = cache[owner.key] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner.key)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[owner.key] = icon
        return icon
    }
}
