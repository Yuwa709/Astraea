import SwiftUI
import Observation
import os

/// What the HUD strip is showing. Observable, so a key press that refreshes
/// the activity in place moves the bar without the coordinator re-rendering.
@MainActor
@Observable
final class SystemHUDState {
    enum Kind: Equatable { case volume, brightness }

    var kind: Kind = .volume
    var level: Double = 0
    var isMuted = false
}

/// The system's key increments: 16 steps, or 64 with Option+Shift. A step
/// from between two marks lands on the next mark, as the system's does.
enum HUDStep {
    nonisolated static func next(_ level: Double, up: Bool, fine: Bool) -> Double {
        let steps = fine ? 64.0 : 16.0
        let position = min(max(level, 0), 1) * steps
        let mark = up ? (position + 1e-3).rounded(.down) + 1
                      : (position - 1e-3).rounded(.up) - 1
        return min(max(mark / steps, 0), 1)
    }

    /// Where the next step starts. Output hardware quantizes the volume: a
    /// set of 0.625 reads back as 0.6267, and stepping from the read-back
    /// lands on 0.625 again, so the volume stuck after one press (user,
    /// 2026-11-03). Within `tolerance` of the level last set, that level
    /// is the truth; further off, something else moved it.
    nonisolated static let tolerance = 0.02

    nonisolated static func base(reading: Double, lastSet: Double?) -> Double {
        guard let lastSet, abs(reading - lastSet) <= tolerance else { return reading }
        return lastSet
    }
}

/// Volume and brightness feedback in the notch, replacing the system OSD.
///
/// With Accessibility the module owns the keys: it applies each step itself
/// (16 per range, 64 with Option+Shift) and swallows the event, so the system draws
/// nothing. Without it, it follows the system's changes and the OSD stays.
/// Always on and absent from Settings — it is feedback for a key the user
/// pressed, not a feature to discover.
///
/// No timer of its own: the monitors are push-driven, and the arbiter's
/// one-shot expiry timer exists only while the HUD is up.
@MainActor
final class SystemHUDModule: NotchModule {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "SystemHUD")

    /// Permanent. See `ModuleID`.
    let id: ModuleID = "system-hud"
    let displayName = "Volume & Brightness"
    /// A direct result of a key press: it interrupts a track-change pop.
    let priority: ModulePriority = .urgent
    let liveActivityStyle: LiveActivityStyle = .hud
    let showsInSettings = false
    var wantsCompactDisplay: Bool { false }
    var hasExpandedContent: Bool { false }

    /// How long the strip stays after the last key is released (or, with no
    /// key to watch, after the last change). 1.0 (user, 2026-11-03: 2.5
    /// lingered).
    static let duration: TimeInterval = 1.0

    /// While a key is held the strip stays down; each auto-repeat renews
    /// this. Only a cap, for a release that never arrives: the release
    /// itself starts `duration`. Longer than the slowest initial key-repeat
    /// delay, so the gap before the first repeat never retracts it.
    static let heldDuration: TimeInterval = 3.0

    var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                volume.start()
                brightness.start()
                keys.start()
            } else {
                volume.stop()
                brightness.stop()
                keys.stop()
                heldKeys.removeAll()
            }
        }
    }

    /// Set by AppDelegate to the coordinator; the module never touches it.
    var onLiveActivityRequest: ((LiveActivityRequest) -> Void)?

    private let state = SystemHUDState()
    private let volume: VolumeMonitor
    private let brightness = BrightnessController()
    private let keys = HUDKeyMonitor()
    /// The keys down right now.
    private var heldKeys: Set<HUDKeyEvent.Key> = []
    /// The volume and brightness last set here; see `HUDStep.base`.
    private var lastVolume: Double?
    private var lastBrightness: Double?

    /// Defaulted via nil: a default argument is evaluated nonisolated, and
    /// the monitor is `@MainActor`.
    init(volume: VolumeMonitor? = nil) {
        let volume = volume ?? VolumeMonitor()
        self.volume = volume
        volume.onChange = { [weak self] reading in
            guard let self else { return }
            // The bar shows the step, not the hardware's rounding of it.
            let level = reading.isMuted ? 0 : HUDStep.base(reading: reading.displayLevel,
                                                            lastSet: self.lastVolume)
            self.present(.volume, level: level, muted: reading.isMuted)
        }
        // Auto-brightness changes constantly: a change alone never shows the
        // HUD, it only moves the bar while a brightness HUD is up.
        brightness.onChange = { [weak self] level in
            guard let self, self.state.kind == .brightness else { return }
            self.state.level = level
        }
        keys.onKey = { [weak self] event in
            self?.handle(event) ?? false
        }
    }

    // MARK: - Keys

    /// Returns whether the key was applied here (and so must be swallowed).
    /// A press shows the strip even when the value cannot move (already at
    /// 0% or 100%), and holds it until the release.
    private func handle(_ event: HUDKeyEvent) -> Bool {
        guard isEnabled else { return false }
        if event.isDown {
            heldKeys.insert(event.key)
        } else {
            heldKeys.remove(event.key)
        }
        let modifiers = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let fine = modifiers.contains(.option) && modifiers.contains(.shift)

        if event.key.isVolume {
            let applied = keys.isIntercepting && applyVolume(event, fine: fine)
            if let reading = volume.reading, !applied {
                present(.volume, level: reading.displayLevel, muted: reading.isMuted)
            }
            return applied
        } else {
            let applied = keys.isIntercepting && applyBrightness(event, fine: fine)
            if let level = brightness.level, !applied {
                present(.brightness, level: level, muted: false)
            }
            return applied
        }
    }

    /// Whether this key has something to act on; if not it goes to the
    /// system, press and release alike.
    private func canApply(_ key: HUDKeyEvent.Key) -> Bool {
        switch key {
        case .volumeUp, .volumeDown: return volume.canSetLevel && volume.reading != nil
        case .mute: return volume.hasMute && volume.reading != nil
        case .brightnessUp, .brightnessDown: return brightness.level != nil
        }
    }

    private func applyVolume(_ event: HUDKeyEvent, fine: Bool) -> Bool {
        guard canApply(event.key), let reading = volume.reading else { return false }
        // The release was the system's too only if the press was; ours.
        guard event.isDown else { return true }
        var next = reading
        switch event.key {
        case .mute:
            guard !event.isRepeat else { break }
            next.isMuted.toggle()
            volume.setMuted(next.isMuted)
        case .volumeUp, .volumeDown:
            let up = event.key == .volumeUp
            if up, reading.isMuted {
                next.isMuted = false
                volume.setMuted(false)
            }
            let base = HUDStep.base(reading: reading.level, lastSet: lastVolume)
            next.level = HUDStep.next(base, up: up, fine: fine)
            volume.setLevel(next.level)
            lastVolume = next.level
        default:
            return false
        }
        // Shown now, not when the listener echoes it back.
        present(.volume, level: next.displayLevel, muted: next.isMuted)
        return true
    }

    private func applyBrightness(_ event: HUDKeyEvent, fine: Bool) -> Bool {
        guard let level = brightness.level else { return false }
        guard event.isDown else { return true }
        let base = HUDStep.base(reading: level, lastSet: lastBrightness)
        let next = HUDStep.next(base, up: event.key == .brightnessUp, fine: fine)
        guard brightness.setLevel(next) else { return false }
        lastBrightness = next
        present(.brightness, level: next, muted: false)
        return true
    }

    // MARK: - Presenting

    private func present(_ kind: SystemHUDState.Kind, level: Double, muted: Bool) {
        guard isEnabled else { return }
        state.kind = kind
        state.isMuted = muted
        state.level = level
        let duration = heldKeys.isEmpty ? Self.duration : Self.heldDuration
        onLiveActivityRequest?(LiveActivityRequest(
            moduleID: id, priority: priority, duration: duration))
    }

    func makeCompactView() -> AnyView { AnyView(EmptyView()) }

    /// The strip itself. Only ever drawn as the HUD: the module is never in
    /// the standby stack, and the coordinator yields the HUD when the panel
    /// opens.
    func makeExpandedView() -> AnyView { AnyView(SystemHUDView(state: state)) }
}
