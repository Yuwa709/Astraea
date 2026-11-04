import AppKit
import Observation
import os

/// The resource page's data: running apps ranked by energy, memory or CPU,
/// and the Quit action.
///
/// **Samples only while the page is open.** The coordinator calls `start()`
/// when the page becomes the destination and `stop()` when it stops being
/// one, and a collapse resets the destination, so closing the notch stops
/// it too. One loop at most: a second `start()` is a no-op, and a sample
/// that lands after `stop()` is dropped by its generation. Suspended while
/// the display sleeps (hard rule 9).
///
/// The first sample comes immediately (memory is right at once), the
/// second a second later (energy and CPU need a delta), then every two
/// seconds. The reads run in a detached task; only the results touch the
/// main actor.
///
/// **No GPU ranking.** macOS has no public per-process GPU figure (the
/// accelerator's utilisation in IOKit is system-wide), so the page ranks
/// by energy, memory and CPU only.
@MainActor
@Observable
final class ResourceUsageService {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "ResourceUsage")

    /// The gap to the second sample, then the steady cadence: as long as the
    /// stats page's, and longer is more accurate, not less.
    @ObservationIgnored static let firstInterval: Duration = .seconds(1)
    @ObservationIgnored static let interval: Duration = .seconds(2)

    /// How long a Quit may go unanswered before the button comes back. The
    /// app may be showing a save sheet the user then cancels; its process
    /// never exits, and the row has to be quittable again.
    @ObservationIgnored static let quitPatience: TimeInterval = 10

    /// The system's own shell apps. Quitting them restarts them or leaves
    /// the session without its desktop, so the page offers no button.
    @ObservationIgnored nonisolated static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight",
    ]

    enum Phase: Equatable {
        case idle
        /// Sampling, but without two samples yet: energy and CPU are unknown.
        case measuring
        case ready
    }

    private(set) var phase: Phase = .idle
    /// Smoothed figures, unsorted.
    private(set) var apps: [ResourceAppUsage] = []
    /// `apps` in the order the page shows them: ranked for `metric`, but
    /// held steady by `ResourceRankStabilizer`.
    private(set) var ranked: [ResourceAppUsage] = []
    var metric: ResourceMetric = .energy {
        didSet { if metric != oldValue { publish() } }
    }
    /// Apps asked to quit that have not exited yet, and when they were asked.
    private(set) var quitting: [pid_t: Date] = [:]
    /// Apps that refused the request outright.
    private(set) var quitRefused: Set<pid_t> = []

    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var icons: [pid_t: NSImage] = [:]
    @ObservationIgnored private var smoother = ResourceSmoother()
    @ObservationIgnored private var stabilizer = ResourceRankStabilizer()
    @ObservationIgnored private var appCache: [pid_t: (object: NSRunningApplication, app: ResourceApp?)] = [:]

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(displayDidSleep),
                           name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(displayDidWake),
                           name: NSWorkspace.screensDidWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(appDidTerminate(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    deinit {
        task?.cancel()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    var isSampling: Bool { task != nil }

    // MARK: - Lifecycle

    /// The page opened. Energy first, every time: the control's first segment.
    func start() {
        guard !wanted else { return }
        wanted = true
        metric = .energy
        updateTask()
    }

    func stop() {
        guard wanted else { return }
        wanted = false
        updateTask()
    }

    @objc private func displayDidSleep() {
        displayAsleep = true
        updateTask()
    }

    @objc private func displayDidWake() {
        displayAsleep = false
        updateTask()
    }

    private func updateTask() {
        let shouldRun = wanted && !displayAsleep
        guard shouldRun != (task != nil) else { return }
        generation += 1
        if shouldRun {
            phase = .measuring
            let generation = generation
            task = Task { [weak self] in await self?.run(generation: generation) }
            Self.logger.notice("Resource sampling started")
        } else {
            task?.cancel()
            task = nil
            // Nothing stale is kept: the next visit measures afresh.
            phase = .idle
            apps = []
            ranked = []
            smoother = ResourceSmoother()
            stabilizer = ResourceRankStabilizer()
            quitting = [:]
            quitRefused = []
            icons = [:]
            appCache = [:]
            Self.logger.notice("Resource sampling stopped")
        }
    }

    private func run(generation: Int) async {
        var reader = ResourceProcessReader()
        var tracker = ResourceCPUTracker()
        var delay = Self.firstInterval
        while !Task.isCancelled, generation == self.generation {
            let apps = runningApps()
            let result = await Task.detached(priority: .utility) {
                [reader, tracker] () -> (ResourceProcessReader, ResourceCPUTracker, [ResourceAppUsage], Bool) in
                var reader = reader
                var tracker = tracker
                let processes = reader.readAll()
                let rates = tracker.advance(processes,
                                            nowNanos: DispatchTime.now().uptimeNanoseconds,
                                            nowAbsolute: mach_absolute_time())
                let rows = ResourceRanking.aggregate(processes: processes, apps: apps, rates: rates)
                return (reader, tracker, rows, rates != nil)
            }.value
            // Stopped, or stopped and restarted, while the read was out.
            guard !Task.isCancelled, generation == self.generation else { return }
            reader = result.0
            tracker = result.1
            apply(result.2, hasRates: result.3)
            try? await Task.sleep(for: delay)
            delay = Self.interval
        }
    }

    private func apply(_ rows: [ResourceAppUsage], hasRates: Bool) {
        let live = Set(rows.map(\.id))
        let now = Date()
        // Exited apps leave the quitting set; one still running long after
        // the request was cancelled by its user and gets its button back.
        quitting = quitting.filter { live.contains($0.key) && now.timeIntervalSince($0.value) < Self.quitPatience }
        quitRefused.formIntersection(live)
        icons = icons.filter { live.contains($0.key) }
        apps = smoother.smooth(rows, at: Self.now)
        if hasRates, phase != .ready {
            // Until now energy and CPU were unknown and the order fell back
            // to memory; rank afresh on the first real figures.
            stabilizer.reset()
            phase = .ready
            Self.logger.notice("Resource usage measured: \(rows.count, privacy: .public) apps")
        }
        publish()
    }

    private func publish() {
        ranked = stabilizer.arrange(apps, by: metric, at: Self.now)
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    /// The apps a user would recognise: every regular app, and third-party
    /// menu bar apps (the system's own agents are not things to quit).
    ///
    /// Each `NSRunningApplication` property is a LaunchServices lookup, and
    /// reading them for every process on every refresh was most of the
    /// page's cost. AppKit hands back the same object for a process's whole
    /// life, so the verdict is kept per object and only a new process is
    /// looked up; the cache holds only processes still running.
    private func runningApps() -> [ResourceApp] {
        let me = ProcessInfo.processInfo.processIdentifier
        var next: [pid_t: (object: NSRunningApplication, app: ResourceApp?)] = [:]
        var result: [ResourceApp] = []
        for running in NSWorkspace.shared.runningApplications {
            let pid = running.processIdentifier
            guard pid > 0 else { continue }
            let app: ResourceApp?
            if let cached = appCache[pid], cached.object === running {
                app = cached.app
            } else {
                app = Self.resourceApp(running, me: me)
            }
            next[pid] = (running, app)
            if let app { result.append(app) }
        }
        appCache = next
        return result
    }

    private static func resourceApp(_ running: NSRunningApplication, me: pid_t) -> ResourceApp? {
        guard !running.isTerminated else { return nil }
        let bundleID = running.bundleIdentifier
        switch running.activationPolicy {
        case .regular: break
        case .accessory where !(bundleID?.hasPrefix("com.apple.") ?? true): break
        default: return nil
        }
        let path = running.bundleURL?.resolvingSymlinksInPath().path
        let name = running.localizedName
            ?? running.bundleURL?.deletingPathExtension().lastPathComponent
            ?? bundleID
            ?? "PID \(running.processIdentifier)"
        let canQuit = running.processIdentifier != me
            && !(bundleID.map(protectedBundleIDs.contains) ?? false)
        return ResourceApp(pid: running.processIdentifier, bundleID: bundleID,
                           name: name, bundlePath: path, canQuit: canQuit)
    }

    // MARK: - Icons

    /// The app's own icon, looked up once per visit; nil draws a placeholder.
    func icon(for app: ResourceApp) -> NSImage? {
        if let cached = icons[app.pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: app.pid)?.icon else { return nil }
        icons[app.pid] = icon
        return icon
    }

    // MARK: - Quit

    /// Asks the app to quit, the way the Dock's Quit does: it may show a
    /// save sheet, and the user may cancel. The row stays until the process
    /// has actually gone. Never forced.
    func quit(_ app: ResourceApp) {
        guard app.canQuit, quitting[app.pid] == nil,
              let running = NSRunningApplication(processIdentifier: app.pid),
              !running.isTerminated,
              // The PID could have been reused since the row was drawn.
              running.bundleIdentifier == app.bundleID else { return }
        if running.terminate() {
            quitting[app.pid] = Date()
            quitRefused.remove(app.pid)
            Self.logger.notice("Asked \(app.name, privacy: .public) (\(app.pid, privacy: .public)) to quit")
        } else {
            quitRefused.insert(app.pid)
            Self.logger.notice("\(app.name, privacy: .public) (\(app.pid, privacy: .public)) refused to quit")
        }
    }

    @objc private func appDidTerminate(_ note: Notification) {
        guard task != nil,
              let running = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        let pid = running.processIdentifier
        guard apps.contains(where: { $0.id == pid }) else { return }
        apps.removeAll { $0.id == pid }
        publish()
        quitting[pid] = nil
        quitRefused.remove(pid)
        icons[pid] = nil
    }
}
