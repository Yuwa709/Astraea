import AppKit
import SwiftUI
import Sparkle
import os

/// Thin by design: it owns the app's long-lived objects and nothing else.
/// Panel placement, hover, arbitration, and expiry all live in
/// `NotchCoordinator`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "AppDelegate")

    /// The legacy migration runs first: `SettingsStore` reads its payload in
    /// `init`, so a PopNotch install's settings must already be in place.
    let settings: SettingsStore = {
        LegacyDataMigration.run()
        return SettingsStore()
    }()
    /// Session-only; see PinState. Held here so the menu bar and the panel
    /// chrome read the same flag.
    let pinState = PinState()
    private(set) lazy var coordinator = NotchCoordinator(
        settings: settings, caffeinate: caffeinate,
        pinState: pinState, statsPage: statsPage,
        appVolume: appVolume)
    private let statsService = SystemStatsService()
    /// The stats page's own data layer. Both hold no timer until the page
    /// opens — the coordinator starts and stops them on the destination —
    /// so creating them here costs nothing at launch.
    private let batteryService = BatteryService()
    private lazy var statsPage = NotchCoordinator.StatsPageServices(
        stats: statsService, battery: batteryService)
    private let clipboardService = ClipboardService()
    private let fileShelfService = FileShelfService()
    /// App-level. The control renders as panel chrome via the coordinator,
    /// so no module needs to know about it.
    private(set) lazy var caffeinate = CaffeinateService()

    /// Enabled here from the stored setting. Whether it may capture is
    /// MediaModule's to say: only while the player screen, whose progress
    /// row draws the spectrum, is on screen and the tracked player is playing.
    private(set) lazy var audioViz = AudioVisualizerService()

    /// Per-app volume. Phase 4 of its plan: read-only enumeration and naming
    /// of the processes that are playing, shown on the coordinator's mixer
    /// page with inert sliders. No taps; the engine is Phase 5.
    /// `AppVolumeModule`'s toggle is what starts and stops the watching.
    private(set) lazy var appVolume = AppVolumeService()
    /// The Phase 5 tap engine: a service owned here, never a module
    /// (v1 plan, decision 4). Its own serial queue holds every Core Audio
    /// call, so nothing here blocks on the capture permission prompt.
    private(set) lazy var tapEngine = TapEngine()
    /// Face Unlock's session: the one in-memory key for the face data and
    /// the stored password. It starts locked; when Face Unlock is set up,
    /// the launch prompt restores it from the signed session record, or
    /// asks once if there is none. Its auto-locker is created with it and
    /// holds no timer while it is locked.
    private(set) lazy var faceSession: FaceUnlockSession = {
        let session = FaceUnlockSession()
        faceAutoLocker = FaceSessionAutoLocker(session: session) { [settings] in
            settings.settings.faceUnlockAutoLockInterval
        }
        return session
    }()
    private var faceAutoLocker: FaceSessionAutoLocker?
    /// Enrolled faces for Face Unlock, encrypted with the session's key.
    private(set) lazy var faceStore = FaceEnrollmentStore(session: faceSession)
    /// The stored Mac password (phase 2), encrypted with the session's key.
    private(set) lazy var facePasswordStore = FacePasswordStore(session: faceSession)
    /// Face Unlock at the lock screen (phase 3). Created when the setting is
    /// on at launch, when it is turned on, or when Settings opens (its page
    /// shows the status). Creating it starts nothing: the lock monitor runs
    /// only while the setting is on, and the camera, the face model and the
    /// password are touched only by a scan at the lock screen.
    private(set) lazy var faceUnlockCoordinator: FaceUnlockCoordinator = {
        let coordinator = FaceUnlockCoordinator(
            settings: settings, session: faceSession,
            faceStore: faceStore, passwordStore: facePasswordStore)
        lockScreenOverlay = LockScreenOverlayController(source: coordinator)
        return coordinator
    }()
    /// Draws the coordinator's scan above the lock screen (phase 5). Lives
    /// as long as the coordinator; creates a window only while a scan is
    /// visible there.
    private var lockScreenOverlay: LockScreenOverlayController?

    /// The system now-playing source, held only so the music-over-video
    /// preference can be applied live from Settings. MediaModule owns it as
    /// one of its sources; this is a reference, not ownership.
    private(set) var systemMediaSource: SystemMediaAdapter?

    /// The media sources to register, honouring `SystemMediaAdapter.isRegistered`.
    ///
    /// Split out so the flag is consulted in exactly one place rather than
    /// being encoded as a literal array that someone has to remember to edit.
    private func mediaSources(includingSystem system: SystemMediaAdapter) -> [any MediaSource] {
        var sources: [any MediaSource] = [SpotifyAdapter(), MusicAdapter()]
        if SystemMediaAdapter.isRegistered { sources.append(system) }
        return sources
    }

    // MARK: - Updates

    /// What a scheduled check found, and the notch's way to act on it. The
    /// standard user driver's delegate (gentle reminders), so a background
    /// find never opens Sparkle's alert on its own; see `UpdateService`.
    private(set) lazy var updateService = UpdateService()

    /// Sparkle's updater, owned here because it must outlive any view.
    ///
    /// `startingUpdater: true` starts the updater so a check can be requested.
    /// Whether it also checks on its own is the Update Notices module's
    /// switch (`UpdateModule.isEnabled`, on by default), applied through
    /// `updateService` on every launch so a stale stored preference, or a
    /// future Sparkle default, cannot decide it for an app with no Dock icon.
    /// Scheduled checks became acceptable once they had a visible surface:
    /// Sparkle logs a specific warning for `LSUIElement` apps that schedule
    /// them without gentle reminders, because an alert behind other windows
    /// is easy to miss when there is no Dock icon to bounce. The notch is
    /// that surface now.
    ///
    /// The updater delegate is nil: the feed URL and public key come from
    /// `Astraea/Info.plist` (`SUFeedURL`, `SUPublicEDKey`). The standard
    /// user driver's own UI is still what shows once the user clicks through.
    private(set) lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: updateService
    )

    // MARK: - Settings window

    /// Owned here, not by a SwiftUI `Settings` scene.
    ///
    /// The scene version could not be opened from the notch panel:
    /// `@Environment(\.openSettings)` is only populated inside the App's
    /// scene graph, and the panel is an `NSHostingView` outside it. The
    /// workaround was an observer living in `MenuBarExtra`'s label — which
    /// dies the moment the menu bar icon becomes optional, silently taking
    /// the panel's gear button with it. Owning the window here has no scene
    /// dependency at all, so nothing about the icon can reach it.
    private var settingsWindow: NSWindow?

    /// Creates the window on first use and brings it forward.
    func showSettings() {
        // Hard rule 4 carve-out, the same narrow click-driven one as before:
        // without activation the window opens behind the frontmost app. No
        // hover path activates anything, ever.
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            // `.fullSizeContentView` and a transparent titlebar are
            // load-bearing, not cosmetic (measured 2026-09-19 with a
            // throwaway harness).
            //
            // `NavigationSplitView` with a sidebar makes AppKit draw a
            // 52pt titlebar background and scroll pocket — macOS 26's
            // translucent band — across the FULL width of whatever view it
            // is hosted in. Without `.fullSizeContentView` the content view
            // stops below the real titlebar, so that band lands 52pt inside
            // the content instead of over the titlebar, and the hosting
            // view's safe-area inset stays 0. Measured consequence: the
            // detail `Form`'s scroll view began at the very top of the
            // content area with a zero content inset and a minimum scroll
            // offset of 0, which left its first 36pt — the first row —
            // behind the band and impossible to scroll into view.
            //
            // With both set, the window hands SwiftUI a 52pt top safe area:
            // the band coincides with the titlebar, the detail's content
            // starts below it, and the sidebar list gets a matching 52pt
            // content inset so it scrolls under the band the way every
            // other macOS sidebar does.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 715, height: 500),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.title = "Astraea Settings"
            window.contentView = NSHostingView(rootView: SettingsView(
                coordinator: coordinator,
                settings: settings,
                visualizer: audioViz,
                appVolume: appVolume,
                faceStore: faceStore,
                facePasswordStore: facePasswordStore,
                faceUnlockCoordinator: faceUnlockCoordinator,
                updater: updaterController.updater,
                updates: updateService,
                onQuit: { NSApp.terminate(nil) },
                onPreferMusicOverVideoChange: { [weak self] on in
                    self?.systemMediaSource?.prefersMusicOverVideo = on
                }
            ))
            // Closing must not deallocate it; this delegate holds the only
            // reference and reopening has to work.
            window.isReleasedWhenClosed = false
            // contentMinSize, not minSize: the latter is the *frame*, so it
            // silently gains the titlebar and stops matching the number the
            // view asks for. Below this the split view collapses the sidebar
            // into a toolbar menu, which is the failure the sidebar replaced.
            //
            // The width is the load-bearing half and the titlebar does not
            // touch it. The height floor now measures a content view that
            // includes the titlebar band, but `SettingsView`'s own
            // `minHeight: 500` applies below the safe area and grows the
            // window by the band's height, so the usable area stays 500.
            window.contentMinSize = NSSize(width: 715, height: 500)
            window.center()
            window.setFrameAutosaveName("AstraeaSettings")
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        Self.logger.notice("Settings window shown")
    }

    @objc private func openSettingsRequested() {
        showSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The only Keychain call left in the app, and it runs at most once
        // per install: only for settings upgraded from schema 10 or earlier,
        // never for a fresh install. Skipped under XCTest, whose host app
        // launches against the developer's real defaults and Keychain.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            LegacySpotifyKeychain.runIfPending(settings: settings)
            LegacyStatsHistory.removeFile()
        }
        coordinator.start()
        installSignalHandling()

        // The updater exists from here. Whether it checks on its own is set
        // below, when the Update Notices module is registered with its
        // stored preference; the service applies it to the updater either way.
        updateService.updater = updaterController.updater

        // The panel's gear posts this. Observed here rather than in a view so
        // it survives whatever the scene graph is doing.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsRequested),
            name: .astraeaOpenSettings,
            object: nil
        )

        // Modules register here, one line each — the Phase 2 goal made real.
        // Order is not precedence: MediaModule arbitrates by what is actually
        // playing. See MediaModule.shouldTakeOver(_:from:).
        let systemMedia = SystemMediaAdapter()
        // Applied from the stored preference before the source starts, the
        // same way the visualiser's flag is applied below.
        systemMedia.prefersMusicOverVideo = settings.settings.preferMusicOverVideo
        let media = MediaModule(
            // Order is not precedence — MediaModule.shouldTakeOver decides.
            //
            // `systemMedia` is included whenever `SystemMediaAdapter.isRegistered`
            // is true, which it now is. It was left out in 1.0.3 because it
            // shelled out to a Homebrew `media-control` that most users did
            // not have; the helper has since been vendored into the bundle
            // (script in Resources, framework in Frameworks, resolved through
            // `Bundle.main`). A missing helper or `/usr/bin/perl` leaves the
            // source registered but inert — see `SystemMediaAdapter.isRegistered`.
            sources: mediaSources(includingSystem: systemMedia),
            visualizer: audioViz)
        // Held so the Settings toggle can apply live rather than at next
        // launch — and so the source is ready the moment `isRegistered`
        // flips, without this wiring having to be rebuilt.
        self.systemMediaSource = systemMedia
        media.onLiveActivityRequest = { [weak self] request in
            self?.coordinator.requestLiveActivity(request)
        }
        media.onPresenceChange = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        media.onContentReflow = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        // The mixer page's Spotify and Music rows drive those players'
        // own volume through the media module, as a protocol, so the row
        // and the player slider share one value and one write path.
        appVolume.playerVolumes = media
        // The tap engine's inputs and outputs both route through the
        // service: rows down as desires, per-row engine states back up.
        appVolume.tapEngine = tapEngine
        appVolume.settingsStore = settings
        tapEngine.onStatesChange = { [weak appVolume] states in
            appVolume?.applyEngineStates(states)
        }
        // V2 routing. The engine is the one watcher of the device list:
        // it re-resolves routes on a change and hands the list up here for
        // the rows' output menus, so the two cannot disagree.
        tapEngine.onOutputDevicesChange = { [weak appVolume] devices in
            appVolume?.applyOutputDevices(devices)
        }
        tapEngine.refreshOutputDevices()
        // Phase 6. The visualiser's tap excludes whatever the engine is
        // muting and re-rendering, so the spectrum carries our gain-adjusted
        // copy instead of the app's pre-mute stream. Wired here, not between
        // the modules: a feature never reaches into another one.
        let visualizer = audioViz
        tapEngine.onTappedProcessesChange = { [weak visualizer] pids in
            visualizer?.setTappedProcesses(pids)
        }
        // Launch restore: apply the stored taps toggle without a probe, so
        // launch never prompts. Saved volumes then engage lazily when a
        // qualifying app plays (v1 plan; Phase 5 design report).
        appVolume.restoreTapsEnabledFromSettings()
        // Independent of the App Volume module's own on/off: the warning it
        // feeds is about the visualiser too, which runs either way.
        appVolume.startConflictWatch()
        // After media on purpose: the first standby module with wing content
        // provides the wings, so artwork and waveform keep them while music
        // plays and the update badge shows the rest of the time. The found
        // update still opens the notch once, as a live activity.
        let updates = UpdateModule(service: updateService)
        updates.onLiveActivityRequest = { [weak self] request in
            self?.coordinator.requestLiveActivity(request)
        }
        updates.onPresenceChange = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        let clipboard = ClipboardModule(service: clipboardService)
        // Last, so its battery wings show only when neither media nor an
        // update notice wants the wings.
        let stats = SystemStatsModule(service: statsService, battery: BatteryWingMonitor())
        stats.onPresenceChange = { [weak self] in
            self?.coordinator.refreshPresentation()
        }
        let modules: [any NotchModule] = [
            media,
            updates,
            stats
        ]
        // register() applies the stored preference itself, so a module can
        // never start in a state that disagrees with the user's choice.
        modules.forEach { coordinator.register($0) }
        // Off by default: it records everything the user copies, which is
        // not something to opt someone into. Its `isEnabled` setter is what
        // starts and stops the poll, so registering it disabled leaves no
        // timer running.
        coordinator.register(clipboard, enabledByDefault: false)
        // Off by default too: it touches the user's files, and holding
        // references to them is opt-in.
        coordinator.register(FileShelfModule(service: fileShelfService),
                             enabledByDefault: false)
        // Off by default as well: watching enumerates and logs which apps
        // play audio. Its `isEnabled` setter starts and stops the watching,
        // so registering it disabled leaves no listeners registered — this
        // toggle replaces Phase 3's #if DEBUG gate, as that gate's comment
        // said it would.
        coordinator.register(AppVolumeModule(service: appVolume),
                             enabledByDefault: false)
        // The shelf's drag chooser needs to know when a drag is over the
        // panel; the coordinator hears it, the service displays it.
        coordinator.onFileDragActive = { [weak fileShelfService] active in
            fileShelfService?.setDragHovering(active)
        }
        // The reverse direction: a drag *out of* the shelf must suppress the
        // panel's collapse until the session ends. The service reports it,
        // and the coordinator forwards it to the panel, so the module never
        // references it.
        fileShelfService.onDragOutChange = { [weak self] active in
            self?.coordinator.dragOutChanged(active)
        }
        // Off by default: it watches mouse presses system-wide and moves
        // other apps' windows. Its `isEnabled` setter installs and removes
        // the mouse monitor. The module reports the dragged cursor; the
        // coordinator decides whether that is over the notch.
        let windowLayout = WindowLayoutModule()
        windowLayout.onDragMoved = { [weak self] point in
            self?.coordinator.windowDragMoved(to: point) ?? false
        }
        windowLayout.onDragEnded = { [weak self] in
            self?.coordinator.windowDragEnded()
        }
        windowLayout.presetsProvider = { [weak self] in
            self?.settings.settings.windowLayouts.visiblePresets ?? LayoutPreset.builtIn
        }
        coordinator.register(windowLayout, enabledByDefault: false)

        Self.logger.notice("Launched with \(modules.count, privacy: .public) modules registered")

        // The stored preference; off by default. Whether the spectrum is on
        // screen is MediaModule's to report, so no setSpectrumVisible here.
        audioViz.setEnabled(settings.settings.visualizerEnabled)

        startFaceUnlockIfEnabled()
    }

    /// Lock-screen Face Unlock exists only once it is wanted: at launch if
    /// the setting is on, otherwise as soon as it is turned on. Under XCTest
    /// the host app must not prompt, so the ask-once-after-login prompt is
    /// skipped there.
    private func startFaceUnlockIfEnabled() {
        if settings.settings.faceUnlockAtLockScreenEnabled {
            let coordinator = faceUnlockCoordinator
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                coordinator.scheduleLoginPrompt()
            }
        } else {
            observeFaceUnlockSetting()
        }
    }

    /// Observation fires once per registration, so it re-registers until
    /// the setting is first turned on; the coordinator then follows the
    /// setting itself.
    private func observeFaceUnlockSetting() {
        withObservationTracking {
            _ = settings.settings.faceUnlockAtLockScreenEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.settings.settings.faceUnlockAtLockScreenEnabled {
                    _ = self.faceUnlockCoordinator
                } else {
                    self.observeFaceUnlockSetting()
                }
            }
        }
    }

    /// Kept alive for the process lifetime; a released source stops firing.
    private var sigtermSource: DispatchSourceSignal?

    /// Turns SIGTERM into an orderly quit so the adapter child dies with us.
    ///
    /// `applicationWillTerminate` covers Cmd-Q, but a signal bypasses AppKit
    /// entirely — the process dies without unwinding, and the child process
    /// is reparented to launchd still streaming. `scripts/install.sh` does
    /// exactly this on every install (`pkill -x Astraea`), and each one
    /// leaked a `perl ... stream` until this existed (measured 2026-09-02).
    ///
    /// SIGKILL is deliberately not handled, because it cannot be: the child
    /// then outlives us until its next write hits the closed pipe and takes
    /// SIGPIPE. That is bounded by the next media event on the system, not
    /// unbounded, and is the residual this cannot reach.
    private func installSignalHandling() {
        // The default disposition must go first, or the process still dies
        // before the dispatch source ever runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // Routed through AppKit rather than exiting here, so the normal
            // teardown below runs exactly once and by one path.
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Taps first: they are other apps' audio path. Synchronous on the
        // engine queue, reverse order of creation; a clean destroy restores
        // audio within 0.5 s (measured). SIGTERM already routes here, and
        // SIGKILL fails open by `.mutedWhenTapped` (measured, 0.2 s).
        tapEngine.shutdownSync()
        coordinator.stop()
        // appVolume needs no stop here: its Core Audio listeners die with
        // the process, and the module's toggle owns the in-session lifecycle.
        // The adapter runs as a child process, and a child is not reclaimed
        // the way an in-process timer is: on exit it is reparented to launchd
        // and keeps streaming. It only notices we are gone when its next
        // write hits a closed pipe, which for a paused session may be never.
        // Nothing else in the app forks, so this is the one source that needs
        // an explicit stop rather than letting deinit handle it.
        systemMediaSource?.stopObserving()
        // Deterministic on a clean quit. The system would reclaim the
        // assertion on exit anyway (verified with SIGKILL), but releasing
        // here means it goes the moment the user quits rather than whenever
        // the process finishes tearing down.
        caffeinate.release()
    }
}
