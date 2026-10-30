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
/// Laid out like Control Center's Sound module: the shared page header,
/// then every app as one grouped card of 44pt rows divided by inset
/// hairlines, each with a capsule slider. Fixed 420pt content width, the
/// clipboard page's, so the two doors read as one family. Height follows
/// the row count up to eight rows, then the list scrolls inside its card.
/// Eight 44pt rows are 352pt; with the 22pt header and 8pt gap the page is
/// 382pt, inside the panel's ~388pt of content under its 460pt ceiling.
struct AppVolumePageView: View {

    var service: AppVolumeService

    static let contentWidth: CGFloat = 420
    /// Rows abut inside one card, separated by hairline overlays that take
    /// no height, so `rowSpacing` is zero.
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 0
    /// Past this many rows the list stops growing and scrolls instead.
    static let maxVisibleRows = 8
    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.s) {
            header
            if let warning = AppVolumeService.mixerConflictWarning(names: service.conflictingMixers) {
                MixerConflictBanner(warning: warning)
            }
            content
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .foregroundStyle(NotchStyle.Ink.primary)
    }

    private var header: some View {
        NotchPageHeader(symbol: "speaker.wave.2.fill", title: "App Volume") {
            let playing = service.mixerRows.filter(\.isPlaying).count
            if playing > 0 {
                HStack(spacing: 5) {
                    Circle().fill(NotchStyle.Ink.primary).frame(width: 6, height: 6)
                    Text("\(playing) playing")
                        .font(NotchStyle.Font.captionEmphasis)
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule().fill(NotchStyle.Fill.card))
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let rows = service.mixerRows
        if rows.isEmpty {
            NotchEmptyState(symbol: "speaker.wave.2", message: "Nothing has played audio yet")
                .frame(height: 88)
                .notchCard(padding: 0)
        } else {
            let shape = RoundedRectangle(cornerRadius: NotchStyle.Radius.card, style: .continuous)
            ScrollView(.vertical, showsIndicators: rows.count > Self.maxVisibleRows) {
                LazyVStack(spacing: Self.rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.element.owner.key) { index, row in
                        MixerRowView(row: row, service: service, showsSeparator: index < rows.count - 1)
                    }
                }
            }
            .frame(height: Self.listHeight(rowCount: rows.count,
                                           warningShown: !service.conflictingMixers.isEmpty))
            .background(shape.fill(NotchStyle.Fill.card))
            .clipShape(shape)
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

/// Another mixer is running. Says what that does to the spectrum, not
/// merely that an app is open — a warning nobody can act on is noise.
/// Costs one row's worth of height, which `listHeight` gives back by showing
/// one row fewer, so the panel's ceiling is unchanged.
///
/// Two lines at most: 7 rows plus header and gaps leave 42pt for the banner
/// under the 388pt content budget, and two 10pt lines with this padding are
/// ~34pt. One mixer's warning fits in two lines; a list of several names can
/// truncate, so the full text stays on the tooltip and for VoiceOver.
private struct MixerConflictBanner: View {
    let warning: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .accessibilityHidden(true)
            Text(warning)
                .font(NotchStyle.Font.footnote)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(warning)
        .accessibilityLabel(warning)
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: NotchStyle.Radius.row, style: .continuous)
            .fill(Color.orange.opacity(0.12)))
        .accessibilityElement(children: .combine)
    }
}

/// One app's row: icon, name and state caption, and the slider. A never-tap
/// row is greyed with its reason and a disabled slider — explained, not
/// broken-looking. Non-scripted rows carry the tap engine's slider (Phase
/// 5), live while taps are on and the engine reports the row workable.
private struct MixerRowView: View {
    let row: MixerRow
    let service: AppVolumeService
    let showsSeparator: Bool

    /// Every control that does nothing reads at this opacity.
    static let inertSliderOpacity: Double = 0.45
    /// Where the hairline starts: the row's 12pt inset, the 24pt icon and
    /// its 10pt gap, so it lines up under the name as in a grouped list.
    private static let separatorInset: CGFloat = 46

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

    private var isNeverTap: Bool { row.neverTapReason != nil }

    /// Routing and boost both need a tap, so both need taps on and the
    /// capture grant. Either control still shows its saved choice while
    /// disabled.
    static func tapControlsEnabled(_ row: MixerRow, service: AppVolumeService) -> Bool {
        service.tapsEnabled && row.engineState != .inert(reason: "permission needed")
    }

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(owner: row.owner)
                .opacity(isNeverTap ? 0.4 : 1)
            MixerRowLabels(name: row.owner.name, caption: caption, captionColor: captionColor,
                           isPlaying: row.isPlaying, isGreyed: isNeverTap)
                .frame(width: 136, alignment: .leading)
            slider
            // Never-tap apps are never tapped, so they cannot be routed or
            // boosted.
            if !isNeverTap {
                HStack(spacing: 0) {
                    BassBoostButton(ownerKey: row.owner.key, service: service,
                                    isEnabled: Self.tapControlsEnabled(row, service: service))
                    OutputMenu(row: row, service: service, route: route)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: AppVolumePageView.rowHeight)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle().fill(NotchStyle.Fill.separator).frame(height: 1)
                    .padding(.leading, Self.separatorInset)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.owner.name), \(caption)")
    }

    @ViewBuilder
    private var slider: some View {
        if let scriptedPlayer {
            ScriptedVolumeSlider(bundleID: row.owner.key, players: scriptedPlayer)
        } else if !isNeverTap, service.tapsEnabled, engineReason == nil,
                  !AppVolumeService.scriptedPlayerKeys.contains(row.owner.key) {
            // The identity check keeps Spotify and Music off the tap path
            // even while the Media module (their slider's owner) is
            // disabled: their row goes inert, never to a tap.
            TapVolumeSlider(ownerKey: row.owner.key, service: service)
        } else {
            // Dimmed and disabled: never-tap, taps off, or an engine reason
            // the caption explains.
            MixerSlider(value: .constant(1.0), isEnabled: false)
                .opacity(Self.inertSliderOpacity)
                .accessibilityHidden(true)
        }
    }

    private var route: OutputRoute { service.route(for: row.owner.key) }

    private var caption: String {
        AppVolumeService.caption(for: row, scripted: scriptedPlayer != nil,
                                 tapsEnabled: service.tapsEnabled, route: route,
                                 boosted: service.bass(for: row.owner.key) > 0)
    }

    /// An unplugged choice is the one caption that needs noticing.
    private var captionColor: Color {
        if case .disconnected = route { return .orange }
        return NotchStyle.Ink.tertiary
    }
}

/// The row's name over its state caption, with a small tinted waveform
/// after the name while the app is playing. A greyed (never-tap) row drops
/// its name to the tertiary ink, the dimmest text may go.
private struct MixerRowLabels: View {
    let name: String
    let caption: String
    let captionColor: Color
    let isPlaying: Bool
    let isGreyed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(name)
                    .font(NotchStyle.Font.bodyEmphasis)
                    .foregroundStyle(isGreyed ? NotchStyle.Ink.tertiary : NotchStyle.Ink.primary)
                    .lineLimit(1)
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .accessibilityHidden(true)
                }
            }
            Text(caption)
                .font(NotchStyle.Font.footnote)
                .foregroundStyle(isGreyed ? NotchStyle.Ink.tertiary : captionColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The row's volume slider. At rest a thin line in secondary ink, so a
/// page of rows reads as levels rather than as a stack of white bars
/// (user, 2026-10-29: "too bulky"). Under the pointer or in a drag it grows
/// to a thicker track with a knob and the level above it; the grow is
/// instant under Reduce Motion (hard rule 8). The 16pt hit strip never
/// changes, so the row does not reflow and the slider is as easy to grab
/// at rest. The fill-to-knob mapping is also the same in both states, so
/// the level does not jump as the pointer arrives.
///
/// `centerMark` draws a notch at the middle, where a tap slider's unity
/// sits. `readout` is the level as text, shown while active; nil hides it.
/// VoiceOver gets a real `Slider` through `accessibilityRepresentation`.
private struct MixerSlider: View {
    @Binding var value: Double
    var isEnabled = true
    var centerMark = false
    var readout: String?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var editing = false
    @State private var hovering = false

    /// The hit strip's height, constant in both states.
    static let height: CGFloat = 16
    private static let restingTrack: CGFloat = 4
    private static let activeTrack: CGFloat = 8
    /// The knob's diameter. Its travel is laid out at this size in both
    /// states; at rest it is simply not drawn.
    private static let knob: CGFloat = 12
    /// How far above the track's centre the readout sits.
    private static let readoutLift: CGFloat = 15

    private var isActive: Bool { isEnabled && (hovering || editing) }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let knob = Self.knob
            let travel = max(width - knob, 1)
            let fraction = min(max(value, 0), 1)
            let knobCenter = knob / 2 + CGFloat(fraction) * travel
            let track = isActive ? Self.activeTrack : Self.restingTrack
            ZStack(alignment: .leading) {
                Capsule().fill(NotchStyle.Fill.selected).frame(height: track)
                Capsule().fill(isActive ? NotchStyle.Ink.primary : NotchStyle.Ink.secondary)
                    .frame(width: knobCenter, height: track)
                if centerMark {
                    Capsule()
                        .fill(fraction >= 0.5 ? Color.black.opacity(0.25) : NotchStyle.Ink.quaternary)
                        .frame(width: 2, height: track + 2)
                        .offset(x: width / 2 - 1)
                }
                Circle().fill(Color.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .scaleEffect(isActive ? 1 : 0.4)
                    .opacity(isActive ? 1 : 0)
                    .offset(x: knobCenter - knob / 2)
                if let readout {
                    Text(readout)
                        .font(NotchStyle.Font.footnote)
                        .monospacedDigit()
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .fixedSize()
                        .frame(width: 40)
                        .offset(x: knobCenter - 20, y: -Self.readoutLift)
                        .opacity(isActive ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    guard isEnabled else { return }
                    if !editing { editing = true; onEditingChanged(true) }
                    value = Double(min(max((drag.location.x - knob / 2) / travel, 0), 1))
                }
                .onEnded { _ in
                    guard editing else { return }
                    editing = false
                    onEditingChanged(false)
                })
        }
        .frame(height: Self.height)
        // Scoped to the state flip: the drag itself moves the fill
        // directly, never under an animation.
        .animation(NotchStyle.motion(.snappy(duration: 0.18)), value: isActive)
        .accessibilityRepresentation {
            Slider(value: $value, onEditingChanged: onEditingChanged)
                .disabled(!isEnabled)
        }
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
        }
        .menuStyle(.button)
        .buttonStyle(NotchIconButtonStyle(size: 26))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : MixerRowView.inertSliderOpacity)
        .accessibilityLabel("Output")
        .accessibilityValue(accessibilityValue)
    }

    private var glyphColor: Color {
        switch route {
        case .systemDefault: return NotchStyle.Ink.secondary
        case .device: return NotchStyle.Ink.primary
        case .disconnected: return .orange
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
/// so the two read as a pair; both sit in the same 26pt icon-button circle,
/// inside the fixed row height. The lighting change fades briefly, and is
/// instant under Reduce Motion (hard rule 8). Disabled with the output menu
/// (taps off, no capture grant), but still showing the saved level.
private struct BassBoostButton: View {
    let ownerKey: String
    let service: AppVolumeService
    let isEnabled: Bool

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
                        .foregroundStyle(rank <= level ? NotchStyle.Ink.primary : NotchStyle.Ink.quaternary)
                }
            }
            .animation(NotchStyle.motion(.easeOut(duration: 0.12)), value: level)
        }
        .buttonStyle(NotchIconButtonStyle(size: 26))
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
/// volume is stored as absence. The middle is the app's own volume, marked
/// on the track, and the right end twice it (`TapReconciler.maxPosition`);
/// near the middle the knob snaps onto it. Usable on a row that is not
/// playing: the position is remembered and applies the moment the app
/// next outputs.
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
        MixerSlider(value: Binding(
                        get: { Double(service.tapPosition(for: ownerKey)) / Double(TapReconciler.maxPosition) },
                        set: {
                            service.setTapPosition(TapReconciler.position(atFraction: $0), for: ownerKey)
                            if !dragging { service.endTapVolumeEdit(for: ownerKey) }
                        }),
                    centerMark: true,
                    readout: "\(TapReconciler.sliderValue(atPosition: position))",
                    onEditingChanged: { editing in
                        dragging = editing
                        if !editing { service.endTapVolumeEdit(for: ownerKey) }
                    })
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
        MixerSlider(value: Binding(
                        get: { Double(known ?? 100) / 100 },
                        set: { players.setVolume(PlayerVolume.value(atFraction: $0), for: bundleID) }),
                    isEnabled: known != nil,
                    readout: known.map { "\($0)" },
                    onEditingChanged: { editing in
                        if editing {
                            players.beginVolumeEdit(for: bundleID)
                        } else {
                            players.endVolumeEdit(for: bundleID)
                        }
                    })
            .opacity(known == nil ? MixerRowView.inertSliderOpacity : 1)
            .accessibilityLabel("Volume")
            .accessibilityValue(known.map { "\($0) percent" } ?? "Unknown")
    }
}

/// The row's 24pt icon: the app's own icon where the owner is an app, a
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
                    .font(.system(size: 16))
                    .foregroundStyle(NotchStyle.Ink.secondary)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
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
