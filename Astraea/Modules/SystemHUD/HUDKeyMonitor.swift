import AppKit
import os

/// One press or release of a volume or brightness key, decoded from a
/// system-defined event. Pure, so the decoding is testable without a
/// keyboard.
struct HUDKeyEvent: Equatable, Sendable {
    enum Key: Equatable, Hashable, Sendable {
        case volumeUp, volumeDown, mute, brightnessUp, brightnessDown

        var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
    }

    let key: Key
    /// True for the press and each auto-repeat while held; false for the
    /// release.
    let isDown: Bool
    /// An auto-repeat of a held key, not a fresh press.
    var isRepeat = false

    /// `NX_SUBTYPE_AUX_CONTROL_BUTTONS`: the media, volume and brightness keys.
    nonisolated static let auxControlSubtype: Int16 = 8

    /// Decodes an event's subtype and `data1`. The key code is the high 16
    /// bits; bits 8...15 hold the state, 0xA pressed and 0xB released; bit 0
    /// marks a repeat. `NX_KEYTYPE_SOUND_UP` 0, `SOUND_DOWN` 1,
    /// `BRIGHTNESS_UP` 2, `BRIGHTNESS_DOWN` 3, `MUTE` 7; anything else
    /// (play/pause, keyboard backlight) is not ours.
    nonisolated static func decode(subtype: Int16, data1: Int) -> HUDKeyEvent? {
        guard subtype == auxControlSubtype else { return nil }
        let code = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        let isRepeat = data1 & 0x1 != 0
        let key: Key
        switch code {
        case 0: key = .volumeUp
        case 1: key = .volumeDown
        case 2: key = .brightnessUp
        case 3: key = .brightnessDown
        case 7: key = .mute
        default: return nil
        }
        switch state {
        case 0xA: return HUDKeyEvent(key: key, isDown: true, isRepeat: isRepeat)
        case 0xB: return HUDKeyEvent(key: key, isDown: false)
        default: return nil
        }
    }
}

/// Watches the volume and brightness keys, in one of two modes:
///
/// - **Intercepting** (Accessibility granted): a session event tap. `onKey`
///   returns whether it applied the key itself; a handled key is swallowed,
///   so the system neither changes the value nor draws its own OSD. An
///   unhandled one (an output device with no volume control, a lid closed
///   on the built-in display) passes through and the system does as usual.
/// - **Observing** (no Accessibility): a global monitor. The system still
///   applies the key and draws its OSD; the notch follows along.
///
/// Never prompts for Accessibility: it shares the grant window layouts ask
/// for, and upgrades to intercepting the moment it arrives (the system's
/// distributed notification, not a poll; hard rule 9).
@MainActor
final class HUDKeyMonitor {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "SystemHUD")

    /// Returns true when the key was applied and should be swallowed. Only
    /// consulted for the return value while intercepting.
    var onKey: ((HUDKeyEvent) -> Bool)?

    /// True while the event tap owns the keys.
    var isIntercepting: Bool { tap != nil }

    private var monitor: Any?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var trustObserver: NSObjectProtocol?
    private var isRunning = false

    /// `NX_SYSDEFINED`; CGEventType has no case for it.
    private static let systemDefinedType: UInt32 = 14

    func start() {
        guard !isRunning else { return }
        isRunning = true
        trustObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil, queue: .main) { [weak self] _ in
                // The trust database lands a moment after the notification.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MainActor.assumeIsolated { self?.chooseMode() }
                }
            }
        chooseMode()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let trustObserver { DistributedNotificationCenter.default().removeObserver(trustObserver) }
        trustObserver = nil
        removeTap()
        removeMonitor()
    }

    private func chooseMode() {
        guard isRunning else { return }
        if AXIsProcessTrusted() {
            if tap == nil, installTap() {
                removeMonitor()
                Self.logger.notice("HUD keys: intercepting (system OSD suppressed)")
            }
        } else if tap != nil {
            // Revoked: a tap left installed without trust stops receiving.
            removeTap()
            Self.logger.notice("HUD keys: Accessibility revoked")
        }
        if tap == nil, monitor == nil {
            installMonitor()
            Self.logger.notice("HUD keys: observing (no Accessibility; system OSD stays)")
        }
    }

    // MARK: - Observing

    private func installMonitor() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard let key = HUDKeyEvent.decode(subtype: event.subtype.rawValue,
                                               data1: event.data1) else { return }
            // Global monitor handlers run on the main thread.
            MainActor.assumeIsolated { _ = self?.onKey?(key) }
        }
        if monitor == nil {
            Self.logger.error("HUD key monitor could not be installed")
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: - Intercepting

    private func installTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HUDKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            // The tap runs on the main run loop.
            return MainActor.assumeIsolated {
                monitor.handleTapEvent(type: type, event: event)
            }
        }
        let mask = CGEventMask(1) << CGEventMask(Self.systemDefinedType)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Self.logger.error("HUD key event tap could not be created")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        return true
    }

    private func removeTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Self.logger.notice("HUD key tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public)")
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              let key = HUDKeyEvent.decode(subtype: nsEvent.subtype.rawValue,
                                           data1: nsEvent.data1) else {
            return Unmanaged.passUnretained(event)
        }
        let handled = onKey?(key) ?? false
        return handled ? nil : Unmanaged.passUnretained(event)
    }
}
