import AppKit
import os

/// Reads and controls a YouTube Music tab in Chrome or Safari directly.
///
/// **Why not the system now-playing session.** Tested 2026-11-04 with a
/// YouTube Music track and a YouTube video playing in two Chrome tabs: the
/// system session reports `com.google.Chrome`, the browser's one process ID,
/// title, artist, and an *empty* album for both. It has no URL and no tab, so
/// nothing in it says which site is playing, and it follows whichever tab
/// claimed the session, so its commands go there too. Telling the two apart
/// from it would be guessing from metadata.
///
/// **What this does instead.** The browser's own scripting dictionary lists
/// tabs by URL, which identifies YouTube Music exactly, and runs JavaScript
/// in *that* tab: the page's `navigator.mediaSession` for metadata, its
/// `<video>` element for the clock, and its own transport buttons for
/// commands. Every command is addressed to the one tab, so a video playing
/// in another tab is never touched. Tab URLs need only Automation; the
/// JavaScript needs the browser's "Allow JavaScript from Apple Events"
/// switch, which is off by default. While it is off the tab is still found,
/// `setupHint(forBrowser:)` explains the switch, and the notch keeps showing
/// the system source as before.
///
/// **Priority.** This is a dedicated source in `MediaModule`'s arbitration,
/// like Spotify and Music: while it has a track, playing or paused, the
/// system source (and so any other browser media) cannot take the notch.
///
/// **When it reads.** Never at launch unless Automation for the browser was
/// already granted, so a Chrome user who never opens YouTube Music is not
/// prompted. Otherwise it looks for a tab when the system source reports
/// media from a supported browser (`browserSessionChanged`), when the
/// browser loses focus, and when the panel opens. While it follows a tab it
/// polls with one Apple Event per beat, and only while needed (hard rule 9):
/// every `visibleInterval` with the panel open, every `playingInterval` while
/// playing behind the collapsed notch, and not at all when paused and
/// collapsed, when the display sleeps, or when the module is off.
@MainActor
final class YouTubeMusicAdapter: MediaSource {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "YouTubeMusic")

    static let sourceIdentifier = "youtube-music"
    let sourceID = YouTubeMusicAdapter.sourceIdentifier
    var onUpdate: ((NowPlaying?) -> Void)?

    /// Never true: a declined Automation grant means no tab was found, so
    /// there is nothing here for the module's empty-widget banner to explain.
    /// The other players' rows in Settings cover Automation.
    let permissionDenied = false

    /// Fires when `setupHint(forBrowser:)` may have changed.
    var onSetupHintChange: (() -> Void)?

    static let visibleInterval: TimeInterval = 1.5
    static let playingInterval: TimeInterval = 3

    private(set) var tab: YouTubeMusicTab?
    private var lastSnapshot: NowPlaying?
    private var artworkCache: (source: String, data: Data)?
    private var stateScript: (tab: YouTubeMusicTab, script: NSAppleScript)?

    /// Browsers holding a YouTube Music tab whose JavaScript is switched off.
    private var javaScriptOff: Set<YouTubeMusicBrowser> = [] {
        didSet { if javaScriptOff != oldValue { onSetupHintChange?() } }
    }

    private var observing = false
    private var panelVisible = false
    private var displayAsleep = false
    private var pollTimer: Timer?
    private var pollInterval: TimeInterval?
    private var nudgeTask: Task<Void, Never>?
    private var reanchorTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    var isPlayerRunning: Bool { tab != nil }

    // MARK: - Observing

    func startObserving() {
        guard !observing else { return }
        observing = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            // Leaving the browser is when a tab was most likely opened,
            // closed, played or paused there.
            center.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                              as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let browser = YouTubeMusicBrowser.from(bundleID: bundle) else { return }
                    self?.nudge(reason: "left \(browser.displayName)", evidence: nil)
                }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                               object: nil, queue: .main) { [weak self] note in
                let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                              as? NSRunningApplication)?.bundleIdentifier
                MainActor.assumeIsolated {
                    guard let self, let browser = YouTubeMusicBrowser.from(bundleID: bundle) else { return }
                    self.javaScriptOff.remove(browser)
                    if self.tab?.browser == browser {
                        Self.logger.notice("\(browser.displayName, privacy: .public) quit; YouTube Music tab dropped")
                        self.drop()
                    }
                }
            }
        ]
        Self.logger.notice("Observing browsers for YouTube Music")
    }

    func stopObserving() {
        observing = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers = []
        nudgeTask?.cancel()
        nudgeTask = nil
        reanchorTask?.cancel()
        reanchorTask = nil
        tab = nil
        lastSnapshot = nil
        stateScript = nil
        javaScriptOff = []
        updatePolling()
        Self.logger.notice("Stopped observing browsers for YouTube Music")
    }

    deinit {
        // The run loop retains a scheduled timer; it must not outlive us.
        pollTimer?.invalidate()
    }

    // MARK: - Signals from MediaModule

    /// The system source reported media from this bundle. A supported
    /// browser is the evidence that permits the first Automation prompt.
    func browserSessionChanged(bundleID: String?) {
        guard let browser = YouTubeMusicBrowser.from(bundleID: bundleID) else { return }
        nudge(reason: "\(browser.displayName) media changed", evidence: browser)
    }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible { sync(reason: "panel opened", evidence: nil) }
        updatePolling()
    }

    func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        if !asleep { nudge(reason: "display woke", evidence: nil) }
        updatePolling()
    }

    /// What to tell the user about this browser, or nil when nothing is
    /// wrong.
    func setupHint(forBrowser bundleID: String?) -> String? {
        guard let browser = YouTubeMusicBrowser.from(bundleID: bundleID),
              javaScriptOff.contains(browser) else { return nil }
        return "To control YouTube Music here: \(browser.enableJavaScriptSteps)"
    }

    // MARK: - Pull

    func refresh() {
        sync(reason: "refresh", evidence: nil)
    }

    /// Coalesces bursts (the system stream sends several lines per change)
    /// into one sync.
    private func nudge(reason: String, evidence: YouTubeMusicBrowser?) {
        guard observing else { return }
        nudgeTask?.cancel()
        nudgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.nudgeTask = nil
            self.sync(reason: reason, evidence: evidence)
        }
    }

    /// Reads the followed tab, or looks for one when there is none or it is
    /// gone.
    private func sync(reason: String, evidence: YouTubeMusicBrowser?) {
        guard observing else { return }
        // No running check here: it cost ~10 ms per poll (a full process
        // list), and a quit browser is already dropped by the terminate
        // observer. A read of a vanished tab fails fast and rescans.
        if let tab {
            switch read(tab) {
            case .found(let state):
                apply(state, from: tab)
                return
            case .transient:
                return
            case .unavailable:
                break
            }
        }
        scan(reason: reason, evidence: evidence)
    }

    private enum ReadResult {
        case found(YouTubeMusicPageState)
        /// The browser did not answer in time; keep what is showing.
        case transient
        /// Lost, not YouTube Music any more, JavaScript off, or denied.
        case unavailable
    }

    private func read(_ tab: YouTubeMusicTab) -> ReadResult {
        let script: NSAppleScript
        if let cached = stateScript, cached.tab == tab {
            script = cached.script
        } else {
            let source = YouTubeMusicScripts.runSource(
                javaScript: YouTubeMusicScripts.stateJavaScript, in: tab)
            guard let compiled = AppleScriptRunner.compile(source) else { return .unavailable }
            stateScript = (tab, compiled)
            script = compiled
        }
        switch reply(from: AppleScriptRunner.run(script), browser: tab.browser) {
        case .value(let json):
            javaScriptOff.remove(tab.browser)
            guard let state = YouTubeMusicScripts.parseState(json) else { return .unavailable }
            return .found(state)
        case .javaScriptOff:
            javaScriptOff.insert(tab.browser)
            return .unavailable
        case .transient:
            return .transient
        case .denied, .lost:
            return .unavailable
        }
    }

    private func reply(from result: Result<NSAppleEventDescriptor, AppleScriptRunner.Failure>,
                       browser: YouTubeMusicBrowser) -> YouTubeMusicReply {
        switch result {
        case .success(let descriptor):
            return YouTubeMusicScripts.classify(descriptor.stringValue, browser: browser)
        case .failure(let failure):
            if failure.isPermissionDenied { return .denied }
            if failure.isTimeout { return .transient }
            return .lost
        }
    }

    /// Looks through every running supported browser for YouTube Music tabs
    /// and follows the best one; drops the current tab when none is left.
    private func scan(reason: String, evidence: YouTubeMusicBrowser?) {
        var candidates: [(tab: YouTubeMusicTab, state: YouTubeMusicPageState)] = []
        var foundTabs = 0
        for browser in YouTubeMusicBrowser.allCases where Self.isRunning(browser) {
            guard mayAsk(browser, evidence: evidence) else { continue }
            let output: String
            switch AppleScriptRunner.run(YouTubeMusicScripts.scanSource(for: browser)) {
            case .success(let descriptor):
                output = descriptor.stringValue ?? ""
            case .failure(let failure):
                Self.logger.notice(
                    "Scan of \(browser.displayName, privacy: .public) failed (\(failure.code, privacy: .public))")
                continue
            }
            let tabs = YouTubeMusicScripts.parseScan(output, browser: browser)
            foundTabs += tabs.count
            if tabs.isEmpty { javaScriptOff.remove(browser) }
            // A handful at most; each read is one Apple Event.
            for tab in tabs.prefix(4) {
                if case .found(let state) = read(tab) { candidates.append((tab, state)) }
            }
        }

        guard let chosen = YouTubeMusicScripts.choose(candidates, current: tab) else {
            if tab != nil || lastSnapshot != nil {
                Self.logger.notice(
                    "No readable YouTube Music tab (\(foundTabs, privacy: .public) found, \(reason, privacy: .public)); falling back")
            }
            drop()
            return
        }
        if chosen.tab != tab {
            Self.logger.notice(
                "Following YouTube Music in \(chosen.tab.browser.displayName, privacy: .public) (\(chosen.tab.specifier, privacy: .public), \(reason, privacy: .public))")
        }
        tab = chosen.tab
        apply(chosen.state, from: chosen.tab)
    }

    /// Whether an Apple Event may go to this browser now, decided without
    /// ever sending one that would raise the consent prompt.
    ///
    /// Granted: yes. Denied: no. Not yet asked: only with evidence that the
    /// browser is playing media, and then the prompt is raised by
    /// `requestConsent`, never by a scripted event. A scripted event carries
    /// `AppleScriptRunner`'s 2 s timeout, which dismissed the prompt before
    /// anyone could answer it, and every browser signal raised it again
    /// (seen on hardware 2026-11-04).
    private func mayAsk(_ browser: YouTubeMusicBrowser, evidence: YouTubeMusicBrowser?) -> Bool {
        let status = Self.automationStatus(for: browser, askUserIfNeeded: false)
        switch Int(status) {
        case Int(noErr):
            return true
        case AppleScriptRunner.permissionDeniedCode:
            return false
        default:
            if evidence == browser { requestConsent(for: browser) }
            return false
        }
    }

    /// Browsers whose prompt has been raised this launch. Once each: a
    /// dismissed prompt is not raised again until the next launch, so the
    /// user is never asked in a loop.
    private var consentRequested: Set<YouTubeMusicBrowser> = []

    /// Raises the one-time Automation prompt off the main actor, with no
    /// timeout, and syncs once the user has answered.
    private func requestConsent(for browser: YouTubeMusicBrowser) {
        guard !consentRequested.contains(browser) else { return }
        consentRequested.insert(browser)
        Self.logger.notice("Asking for Automation access to \(browser.displayName, privacy: .public)")
        let bundleID = browser.bundleID
        Task { @MainActor [weak self] in
            let status = await Task.detached(priority: .userInitiated) {
                Self.automationStatus(bundleID: bundleID, askUserIfNeeded: true)
            }.value
            Self.logger.notice(
                "Automation for \(browser.displayName, privacy: .public) answered \(status, privacy: .public)")
            guard status == noErr, let self else { return }
            self.sync(reason: "Automation granted", evidence: browser)
        }
    }

    private static func automationStatus(for browser: YouTubeMusicBrowser,
                                         askUserIfNeeded: Bool) -> OSStatus {
        automationStatus(bundleID: browser.bundleID, askUserIfNeeded: askUserIfNeeded)
    }

    /// Nonisolated so the prompting form can run on a detached task: it
    /// blocks until the user answers.
    private nonisolated static func automationStatus(bundleID: String,
                                                     askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(
                address, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), askUserIfNeeded)
        }
    }

    private static func isRunning(_ browser: YouTubeMusicBrowser) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            .contains { !$0.isTerminated }
    }

    // MARK: - Publishing

    private func apply(_ state: YouTubeMusicPageState, from tab: YouTubeMusicTab) {
        let now = Date()
        guard let snapshot = YouTubeMusicScripts.snapshot(
            from: state, browser: tab.browser, artwork: artwork(for: state, in: tab), capturedAt: now)
        else {
            // The tab is open but nothing is loaded: not a session.
            if lastSnapshot != nil {
                Self.logger.notice("YouTube Music tab has no track; releasing the notch")
            }
            publish(nil)
            updatePolling()
            return
        }
        publish(snapshot, at: now)
    }

    /// Artwork bytes for the state's source: cached per URL, fetched from the
    /// page once it reports them ready.
    private func artwork(for state: YouTubeMusicPageState, in tab: YouTubeMusicTab) -> Data? {
        guard let source = state.artworkSource else { return nil }
        if let cache = artworkCache, cache.source == source { return cache.data }
        guard state.artworkReady else {
            // Keep the previous image until the new one lands, rather than
            // blinking to none at every track change.
            return lastSnapshot?.artworkData
        }
        let script = YouTubeMusicScripts.runSource(
            javaScript: YouTubeMusicScripts.artworkJavaScript, in: tab)
        guard case .value(let text) = reply(from: AppleScriptRunner.run(script), browser: tab.browser),
              let data = YouTubeMusicScripts.decodeDataURL(text)
        else {
            Self.logger.notice("Artwork read failed; keeping the previous image")
            return lastSnapshot?.artworkData
        }
        artworkCache = (source, data)
        return data
    }

    private func publish(_ snapshot: NowPlaying?, at date: Date = Date()) {
        if let snapshot, let last = lastSnapshot,
           YouTubeMusicScripts.isClockOnlyChange(snapshot, from: last, at: date) {
            return
        }
        if snapshot == nil, lastSnapshot == nil { return }
        logTransition(to: snapshot)
        lastSnapshot = snapshot
        onUpdate?(snapshot)
        updatePolling()
    }

    private func logTransition(to snapshot: NowPlaying?) {
        guard let snapshot else {
            Self.logger.notice("YouTube Music: nothing playing")
            return
        }
        let trackChanged = snapshot.title != lastSnapshot?.title || snapshot.artist != lastSnapshot?.artist
        let stateChanged = snapshot.isPlaying != lastSnapshot?.isPlaying
        guard trackChanged || stateChanged else { return }
        Self.logger.notice(
            "YouTube Music: \(snapshot.isPlaying ? "playing" : "paused", privacy: .public) \"\(snapshot.title ?? "", privacy: .public)\" by \(snapshot.artist ?? "", privacy: .public)")
    }

    private func drop() {
        tab = nil
        stateScript = nil
        publish(nil)
        updatePolling()
    }

    // MARK: - Polling

    /// The one decision point for the timer, so its conditions cannot drift.
    private func updatePolling() {
        let wanted: TimeInterval? = {
            guard observing, !displayAsleep, tab != nil else { return nil }
            if panelVisible { return Self.visibleInterval }
            if lastSnapshot?.isPlaying == true { return Self.playingInterval }
            return nil
        }()
        guard wanted != pollInterval else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        pollInterval = wanted
        guard let wanted else {
            Self.logger.notice("YouTube Music polling stopped")
            return
        }
        let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sync(reason: "poll", evidence: nil) }
        }
        timer.tolerance = wanted * 0.2
        // `.common`: the panel is open because the mouse is tracking, and a
        // `.default`-mode timer does not fire during tracking.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Self.logger.notice("YouTube Music polling every \(wanted, privacy: .public)s")
    }

    // MARK: - Commands

    func send(_ command: MediaCommand) {
        guard let tab else { return }
        let reply = run(YouTubeMusicScripts.commandJavaScript(command), in: tab)
        Self.logger.notice(
            "YouTube Music command \(String(describing: command), privacy: .public) -> \(String(describing: reply), privacy: .public)")
        guard case .value("ok") = reply else { return }

        // Optimistic play state, confirmed by the reads below.
        if var snapshot = lastSnapshot {
            let playing: Bool? = switch command {
            case .play: true
            case .pause: false
            case .togglePlayPause: !snapshot.isPlaying
            case .nextTrack, .previousTrack: nil
            }
            if let playing, playing != snapshot.isPlaying {
                snapshot.elapsed = snapshot.elapsedNow()
                snapshot.capturedAt = Date()
                snapshot.isPlaying = playing
                publish(snapshot)
            }
        }
        reanchor()
    }

    func seek(to seconds: TimeInterval) {
        guard let tab else { return }
        let reply = run(YouTubeMusicScripts.seekJavaScript(to: seconds), in: tab)
        guard case .value("ok") = reply, var snapshot = lastSnapshot else { return }
        snapshot.elapsed = seconds
        snapshot.capturedAt = Date()
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    private func run(_ javaScript: String, in tab: YouTubeMusicTab) -> YouTubeMusicReply {
        let source = YouTubeMusicScripts.runSource(javaScript: javaScript, in: tab)
        let result = reply(from: AppleScriptRunner.run(source), browser: tab.browser)
        if result == .javaScriptOff { javaScriptOff.insert(tab.browser) }
        return result
    }

    /// Two reads after a command: one once the page has reacted, one after a
    /// skip has had time to load the next track. Replaced on rapid presses so
    /// only the last one reads.
    private func reanchor() {
        reanchorTask?.cancel()
        reanchorTask = Task { @MainActor [weak self] in
            for delay in [350, 1200] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.sync(reason: "after command", evidence: nil)
            }
        }
    }
}
