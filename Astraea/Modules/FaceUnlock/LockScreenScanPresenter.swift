import AppKit
import os

/// Shows, changes and removes the lock-screen overlay. Behind a protocol so
/// the controller's rules run in tests without windows or SkyLight.
@MainActor
protocol LockScreenOverlayPresenting: AnyObject {
    var isPresented: Bool { get }
    /// A dismissed window still fading out. It is on screen until the fade
    /// ends, so the kill switch must still be able to reach it.
    var isFadingOut: Bool { get }
    /// Called once the last fade-out has finished and torn down.
    var onFadeOutFinished: (() -> Void)? { get set }
    /// Creates the window and its SkyLight space. False, having logged why
    /// and left nothing behind, when nothing could be shown.
    func present(_ phase: LockScreenOverlayPhase, reduceMotion: Bool) -> Bool
    /// Changes the phase in place; no window is rebuilt.
    func update(_ phase: LockScreenOverlayPhase)
    /// Removes the window and destroys the space: after a short alpha fade
    /// when `animated`, at once otherwise. Not animated also ends every fade
    /// still running, at once.
    func dismiss(animated: Bool, reason: String)
}

/// The real presenter: a `LockScreenScanPanel` in a level-400 SkyLight space
/// on the built-in, notched screen. Both exist only while presented.
@MainActor
final class LockScreenScanPresenter: LockScreenOverlayPresenting {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "FaceUnlock")

    /// Window fade in and out. Under Reduce Motion there is none: `present`
    /// skips the fade-in, and the controller never asks for an animated
    /// dismissal.
    static let fadeDuration: TimeInterval = LockScreenScanMotion.windowFadeDuration

    private let loadSkyLight: () -> SkyLightAPI?
    private let findScreen: () -> NSScreen?

    private var panel: LockScreenScanPanel?
    private var space: SkyLightSpace?
    private var model: LockScreenScanModel?
    private var occlusionObserver: NSObjectProtocol?
    /// Panels fading out, each with its space, until their fade completes.
    private var fadingOut: [Int: (panel: LockScreenScanPanel, space: SkyLightSpace)] = [:]
    private var nextFadeID = 0

    var isPresented: Bool { panel != nil }
    var isFadingOut: Bool { !fadingOut.isEmpty }
    var onFadeOutFinished: (() -> Void)?

    /// Both default to the real Mac. Tests pass a loader returning nil.
    init(loadSkyLight: (() -> SkyLightAPI?)? = nil, findScreen: (() -> NSScreen?)? = nil) {
        self.loadSkyLight = loadSkyLight ?? { SkyLightAPI.system }
        // Clamshell or no notch: nil, and no overlay.
        self.findScreen = findScreen ?? { ScreenPolicy.builtInNotchedScreen() }
    }

    func present(_ phase: LockScreenOverlayPhase, reduceMotion: Bool) -> Bool {
        guard panel == nil else {
            update(phase)
            return true
        }
        // SkyLight first: without it nothing is created at all.
        guard let api = loadSkyLight() else {
            Self.logger.notice("Lock-screen overlay not shown: SkyLight unavailable")
            return false
        }
        guard let screen = findScreen() else {
            Self.logger.notice("Lock-screen overlay not shown: no screen with a notch")
            return false
        }
        let notch = NotchPanel.notchRect(on: screen)
        let frame = LockScreenScanLayout.overlayFrame(notchRect: notch)
        let model = LockScreenScanModel(phase: phase, reduceMotion: reduceMotion,
                                        layout: LockScreenScanLayout(notchRect: notch))
        let panel = LockScreenScanPanel(frame: frame, model: model)
        panel.alphaValue = 0
        // The verified order: on screen first, then into the space.
        panel.orderFrontRegardless()
        guard let space = SkyLightSpace(api: api) else {
            panel.orderOut(nil)
            panel.close()
            Self.logger.notice("Lock-screen overlay not shown: SkyLight space refused")
            return false
        }
        space.addWindow(number: panel.windowNumber)
        self.panel = panel
        self.space = space
        self.model = model
        observeOcclusion(of: panel)
        Self.logger.notice("Lock-screen overlay presented: \(String(describing: phase), privacy: .public), screen \(screen.localizedName, privacy: .public), frame \(NSStringFromRect(frame), privacy: .public), reduce motion \(reduceMotion, privacy: .public)")
        guard let fade = LockScreenScanMotion.windowFadeIn(reduceMotion: reduceMotion) else {
            panel.alphaValue = 1
            return true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fade
            panel.animator().alphaValue = 1
        }
        return true
    }

    func update(_ phase: LockScreenOverlayPhase) {
        guard let model, model.phase != phase else { return }
        model.phase = phase
    }

    func dismiss(animated: Bool, reason: String) {
        // An instant dismissal also ends any fade still running: nothing may
        // linger above a screen that just unlocked or slept.
        if !animated && !fadingOut.isEmpty {
            let fading = fadingOut.values
            fadingOut = [:]
            fading.forEach { Self.tearDown($0.panel, $0.space) }
            Self.logger.notice("Lock-screen overlay: \(fading.count, privacy: .public) fading window(s) removed at once (\(reason, privacy: .public))")
        }
        guard let panel, let space else { return }
        self.panel = nil
        self.space = nil
        self.model = nil
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        Self.logger.notice("Lock-screen overlay dismissed (\(animated ? "fade" : "instant", privacy: .public)): \(reason, privacy: .public)")
        guard animated else {
            Self.tearDown(panel, space)
            return
        }
        let id = nextFadeID
        nextFadeID &+= 1
        fadingOut[id] = (panel, space)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishFade(id) }
        })
    }

    /// A kill switch may already have torn everything down; then this does
    /// nothing.
    private func finishFade(_ id: Int) {
        guard let faded = fadingOut.removeValue(forKey: id) else { return }
        Self.tearDown(faded.panel, faded.space)
        if fadingOut.isEmpty { onFadeOutFinished?() }
    }

    /// Window off screen first, then the space: destroying the space first
    /// could hand the window back to the user's space, at full alpha, over
    /// a desktop that just unlocked.
    private static func tearDown(_ panel: LockScreenScanPanel, _ space: SkyLightSpace) {
        panel.alphaValue = 0
        panel.orderOut(nil)
        space.destroy()
        panel.close()
    }

    /// Our only runtime evidence that the window is really visible at the
    /// lock screen: occlusion tracked it faithfully on hardware.
    private func observeOcclusion(of panel: LockScreenScanPanel) {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow else { return }
                let visible = window.occlusionState.contains(.visible)
                Self.logger.notice("Lock-screen overlay occlusion: \(visible ? "visible" : "not visible", privacy: .public)")
            }
        }
    }
}
