import AppKit
import CoreGraphics
import os

/// Reads, sets and watches the built-in display's brightness through the
/// private DisplayServices framework (approved, 2026-11-03). Loaded with
/// `dlopen`, so a macOS that drops a symbol degrades to "no brightness
/// control" instead of failing to launch; the HUD then shows nothing for
/// brightness and the system keeps its own OSD.
///
/// Push-driven: DisplayServices posts each change (key, Control Center,
/// auto-brightness). No timer (hard rule 9).
@MainActor
final class BrightnessController {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "SystemHUD")

    /// Every change of the built-in display's brightness, from anywhere.
    /// Auto-brightness included, so the receiver must not show a HUD for
    /// this alone.
    var onChange: ((Double) -> Void)?

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias RegisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?, CFNotificationCallback) -> Int32
    private typealias UnregisterFn = @convention(c) (CGDirectDisplayID, UnsafeRawPointer?) -> Int32

    private struct Symbols {
        let get: GetFn
        let set: SetFn
        let can: CanFn?
        let register: RegisterFn?
        let unregister: UnregisterFn?
    }

    private static let symbols: Symbols? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            logger.error("DisplayServices could not be loaded")
            return nil
        }
        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }
        guard let get = load("DisplayServicesGetBrightness", as: GetFn.self),
              let set = load("DisplayServicesSetBrightness", as: SetFn.self) else {
            logger.error("DisplayServices has no brightness get/set")
            return nil
        }
        return Symbols(get: get, set: set,
                       can: load("DisplayServicesCanChangeBrightness", as: CanFn.self),
                       register: load("DisplayServicesRegisterForBrightnessChangeNotifications", as: RegisterFn.self),
                       unregister: load("DisplayServicesUnregisterForBrightnessChangeNotifications", as: UnregisterFn.self))
    }()

    /// The display the notifications are registered on.
    private var watched: CGDirectDisplayID?
    private var isRunning = false
    private var screenObserver: NSObjectProtocol?

    /// The built-in panel, if it is on and controllable. Nil in clamshell
    /// mode, where the brightness keys belong to the external display and
    /// the system handles them.
    var display: CGDirectDisplayID? {
        guard let symbols = Self.symbols else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        guard let builtIn = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }),
              CGDisplayIsActive(builtIn) != 0 else { return nil }
        if let can = symbols.can, !can(builtIn) { return nil }
        return builtIn
    }

    /// 0...1, or nil with no controllable built-in display.
    var level: Double? {
        guard let symbols = Self.symbols, let display else { return nil }
        var value: Float = 0
        guard symbols.get(display, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    /// Returns false when there is nothing to set, so the caller can let
    /// the system handle the key instead.
    @discardableResult
    func setLevel(_ level: Double) -> Bool {
        guard let symbols = Self.symbols, let display else { return false }
        let status = symbols.set(display, Float(min(max(level, 0), 1)))
        if status != 0 {
            Self.logger.error("Setting brightness failed: \(status, privacy: .public)")
        }
        return status == 0
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        watch()
        // Clamshell open/close and display changes can swap which display
        // is the built-in one we watch.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.watch() }
            }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        unwatch()
    }

    private var observerToken: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    }

    private func watch() {
        let next = display
        guard next != watched else { return }
        unwatch()
        guard let next, let register = Self.symbols?.register else {
            Self.logger.notice("Brightness: no controllable built-in display")
            return
        }
        // Posted on a DisplayServices thread; the observer is this object,
        // unretained, and outlives the registration (stop() unregisters).
        let status = register(next, observerToken) { _, observer, _, _, _ in
            guard let observer else { return }
            let controller = Unmanaged<BrightnessController>.fromOpaque(observer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = controller.takeUnretainedValue()
                    guard me.isRunning, let level = me.level else { return }
                    me.onChange?(level)
                }
            }
        }
        if status == 0 {
            watched = next
            Self.logger.notice("Brightness monitor on display \(next, privacy: .public), level \(self.level ?? -1, privacy: .public)")
        } else {
            Self.logger.error("Brightness change notifications failed: \(status, privacy: .public)")
        }
    }

    private func unwatch() {
        if let watched, let unregister = Self.symbols?.unregister {
            _ = unregister(watched, observerToken)
        }
        watched = nil
    }
}
