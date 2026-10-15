import AppKit
import os

/// Reads and controls Spotify.
///
/// Metadata arrives two ways:
/// - **Push:** Spotify broadcasts `com.spotify.client.PlaybackStateChanged`
///   as a distributed notification on every track/state change, with title,
///   artist, album, duration, and position in userInfo. No polling, no
///   permission needed.
/// - **Pull:** an AppleScript query fills in what the notification lacks —
///   initial state at launch and the artwork URL. Apple Events need the
///   Automation permission (one system prompt, first call).
///
/// Artwork itself is an image fetch from the URL Spotify's scripting
/// interface hands us — a network call permitted by the hard rule 6 decision
/// recorded in PROJECT-CONTEXT.md. `artwork url` is the only usable route:
/// the dictionary's `artwork` property is image data that Spotify does not
/// populate, so reading it yields nothing.
///
/// What this dictionary cannot do, verified against `sdef`:
/// - **No queue.** There is no playlist, context, or queue class. `next
///   track` is a *command* that skips; it returns no data. `upNext` is
///   therefore always nil here, and never derived by skipping.
/// - **No favourite state.** `starred` is in the dictionary with
///   `access="r"`, but Spotify does not implement the handler: reading it
///   throws **-10000 (errAEEventFailed)** against the live app, measured
///   2026-08-28. It was briefly in the query script and took every other
///   field down with it, because AppleScript aborts the whole `return`
///   expression when one property fails — which is how nine working fields,
///   artwork included, were lost to one unimplemented term. Favourite is
///   therefore `.unsupported` here, not `.readOnly`. Do not re-add it.
@MainActor
final class SpotifyAdapter: MediaSource {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Spotify")
    static let bundleID = "com.spotify.client"
    static let notificationName = Notification.Name("com.spotify.client.PlaybackStateChanged")

    /// Spelled once. History rows carry this string and are matched against
    /// it later, so a literal in two places would silently stop agreeing.
    static let sourceIdentifier = "spotify"

    let sourceID = SpotifyAdapter.sourceIdentifier
    var onUpdate: ((NowPlaying?) -> Void)?
    private(set) var permissionDenied = false

    private var observer: NSObjectProtocol?
    /// Last fetched artwork, keyed by its URL so a track change refetches
    /// exactly once and pause/resume does not refetch at all.
    private var artworkCache: (url: String, data: Data)?
    private var lastSnapshot: NowPlaying?
    private var artworkTask: URLSessionDataTask?
    /// One-shot re-anchor after a transport command. Cancelled and replaced
    /// on rapid skipping so only the last press pulls.
    private var reanchorTask: Task<Void, Never>?

    /// Shuffle and repeat, as of the last successful modes read.
    ///
    /// `nil` until one succeeds, and **kept across a failure** rather than
    /// reset: a dropped Apple Event is not the user turning shuffle off, and
    /// blanking the controls on a transient error would make them flicker.
    private(set) var shuffling: Bool?
    private(set) var repeating: Bool?

    /// Constant: Spotify exposes no readable favourite over AppleScript at
    /// all (see the header note on `starred`), and with the account features
    /// removed (2026-09-28) there is no other route, so the notch never
    /// offers Spotify a favourite control.
    let favorite: FavoriteState = .unsupported

    /// Spaces out pull retries while Automation is denied. See
    /// `handleNotification`.
    private var deniedRetry = PullRetryBackoff()

    var isPlayerRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == Self.bundleID
        }
    }

    // MARK: - Observing

    func startObserving() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                self?.handleNotification(note.userInfo ?? [:])
            }
        }
        Self.logger.notice("Observing Spotify playback notifications")
    }

    func stopObserving() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        artworkTask?.cancel()
        reanchorTask?.cancel()
        reanchorTask = nil
    }

    private func handleNotification(_ userInfo: [AnyHashable: Any]) {
        guard let snapshot = SpotifyParsing.decode(notification: userInfo) else {
            lastSnapshot = nil
            onUpdate?(nil)
            return
        }
        let isNewTrack = snapshot.artworkIdentifier != lastSnapshot?.artworkIdentifier
        publish(snapshot)
        // The notification carries no artwork; fetch it via AppleScript once
        // per track. After a denial the pull is still retried on track
        // changes — that is the only way a grant made later in System
        // Settings is noticed without a relaunch — but spaced out by
        // `deniedRetry`. A denial returns -1743 at once and never re-prompts,
        // so a retry costs one instant failed event, not a dialog.
        guard isNewTrack else { return }
        if !permissionDenied || deniedRetry.allows(at: ProcessInfo.processInfo.systemUptime) {
            refresh()
        }
    }

    // MARK: - Pull

    /// Exposed for the regression test that asserts `starred` never returns.
    static var queryScriptSource: String { queryScript }
    /// Exposed so a test can pin the separator escape to match the others.
    static var modesScriptSource: String { modesScript }

    /// One query returning newline-separated fields; see SpotifyParsing.
    private static let queryScript = """
        tell application "Spotify"
            if player state is stopped then return "stopped"
            set t to current track
            return (player state as text) & "\\n" & name of t & "\\n" & artist of t \
                & "\\n" & album of t & "\\n" & (duration of t as text) \
                & "\\n" & (player position as text) & "\\n" & artwork url of t \
                & "\\n" & (id of t as text)
        end tell
        """

    // MARK: - Playback modes

    /// Reads `shuffling` and `repeating`, and **nothing else**.
    ///
    /// Deliberately a separate script from `queryScript`, not fields 9 and
    /// 10 on it. AppleScript evaluates a `return` expression as one unit, so
    /// a single unimplemented property aborts the whole thing — that is the
    /// `starred` incident, where one bad term took eight working fields with
    /// it and silently killed album artwork for a release. Both properties
    /// were probed live and answered (`shuffling: false`, `repeating: true`,
    /// 2026-09-03), but "callable" is not "safe to co-locate": these two
    /// share an expression only with each other, so the worst case is losing
    /// the two controls, never the track.
    private static let modesScript = """
        tell application "Spotify"
            return (shuffling as text) & "\\n" & (repeating as text)
        end tell
        """

    // MARK: - Live poll

    /// Exactly three properties — the three that go stale while the panel is
    /// open and arrive by no notification: position (a seek in Spotify's own
    /// window), shuffling, repeating. Nothing else, deliberately: each
    /// property is one ~16.7ms IPC round-trip on the main actor, so this
    /// costs ~50ms where the eight-field query costs 167ms. Play/pause and
    /// track changes already arrive by notification and are not read here.
    ///
    /// No `player state` guard, which would be a fourth property: the caller
    /// skips the tick while paused, so a stopped player is excluded upstream
    /// and a failure here costs one logged miss, not the track.
    ///
    /// Its own script, separate from `queryScript` — same isolation reason as
    /// `modesScript`, and it must stay that way.
    private static let liveScriptSource = """
        tell application "Spotify"
            return (player position as text) & "\\n" & (shuffling as text) & "\\n" & (repeating as text)
        end tell
        """

    /// Compiled once, on first use, and reused for every tick. Nil only if
    /// the static source above fails to compile, which is a build-time bug.
    private lazy var liveScript: NSAppleScript? = AppleScriptRunner.compile(Self.liveScriptSource)

    /// Parses the three-line live output. Pure, for tests.
    nonisolated static func parseLive(_ output: String)
        -> (position: TimeInterval, shuffling: Bool, repeating: Bool)? {
        guard output != "stopped" else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 3,
              // AppleScript renders reals with the locale's decimal separator.
              let position = Double(lines[0].trimmingCharacters(in: .whitespaces)
                                        .replacingOccurrences(of: ",", with: ".")),
              let shuffling = Bool(lines[1].trimmingCharacters(in: .whitespaces)),
              let repeating = Bool(lines[2].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (position, shuffling, repeating)
    }

    /// One narrow read for the open panel. Re-anchors position and refreshes
    /// the modes; publishes nothing new.
    ///
    /// Position goes out by the mechanism `reanchor()` already uses for
    /// transport: the *existing* snapshot with `elapsed` and `capturedAt`
    /// re-stamped, so the local projection restarts from the truth. No new
    /// `NowPlaying` is built here.
    ///
    /// Modes are written before the publish, not after — publishing is what
    /// makes `MediaModule` mirror them, so they must be current when it looks.
    /// A failure logs and leaves every last-known value standing.
    func refreshLive() {
        guard isPlayerRunning, let script = liveScript else { return }
        switch AppleScriptRunner.run(script) {
        case .success(let descriptor):
            guard let output = descriptor.stringValue,
                  let live = Self.parseLive(output) else {
                Self.logger.error("Live read returned unparseable output; keeping last known state")
                return
            }
            let modesChanged = live.shuffling != shuffling || live.repeating != repeating
            shuffling = live.shuffling
            repeating = live.repeating
            if modesChanged {
                Self.logger.notice(
                    "Modes: shuffling=\(live.shuffling, privacy: .public) repeating=\(live.repeating, privacy: .public)")
            }
            guard var snapshot = lastSnapshot else { return }
            snapshot.elapsed = live.position
            snapshot.capturedAt = Date()
            lastSnapshot = snapshot
            onUpdate?(snapshot)
        case .failure(let failure):
            Self.logger.error(
                "Live read failed (\(failure.code, privacy: .public)); keeping last known state")
        }
    }

    /// Parses the two-line modes output. Pure, for tests.
    nonisolated static func parseModes(_ output: String) -> (shuffling: Bool, repeating: Bool)? {
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2 else { return nil }
        guard let shuffling = Bool(lines[0].trimmingCharacters(in: .whitespaces)),
              let repeating = Bool(lines[1].trimmingCharacters(in: .whitespaces))
        else { return nil }
        return (shuffling, repeating)
    }

    /// Runs the modes script on the main query's cadence, in isolation.
    ///
    /// Never touches `permissionDenied` and never publishes a snapshot: a
    /// failure here must not be able to change what the main query
    /// concluded. It logs and leaves the last known state standing.
    private func refreshPlaybackModes() {
        switch AppleScriptRunner.run(Self.modesScript) {
        case .success(let descriptor):
            guard let output = descriptor.stringValue,
                  let modes = Self.parseModes(output) else {
                Self.logger.error("Modes read returned unparseable output; keeping last known state")
                return
            }
            let changed = modes.shuffling != shuffling || modes.repeating != repeating
            shuffling = modes.shuffling
            repeating = modes.repeating
            if changed {
                Self.logger.notice(
                    "Modes: shuffling=\(modes.shuffling, privacy: .public) repeating=\(modes.repeating, privacy: .public)")
            }
        case .failure(let failure):
            // Logged, and that is all. The controls keep showing the last
            // state that was actually read.
            Self.logger.error(
                "Modes read failed (\(failure.code, privacy: .public)); keeping last known state")
        }
    }

    /// Sets shuffle. One-shot script of its own, for the same isolation
    /// reason as the read.
    func setShuffling(_ on: Bool) {
        setMode("shuffling", to: on)
    }

    func setRepeating(_ on: Bool) {
        setMode("repeating", to: on)
    }

    /// `property` is a compile-time literal from the two callers above and
    /// never user input, so there is nothing here to escape.
    private func setMode(_ property: String, to on: Bool) {
        guard isPlayerRunning else { return }
        let script = "tell application \"Spotify\" to set \(property) to \(on)"
        switch AppleScriptRunner.run(script) {
        case .success:
            // Optimistic, then confirmed: the control responds immediately
            // and the next refresh reads back what actually took.
            if property == "shuffling" { shuffling = on } else { repeating = on }
            Self.logger.notice("Set \(property, privacy: .public) to \(on, privacy: .public)")
        case .failure(let failure):
            Self.logger.error(
                "Set \(property, privacy: .public) failed (\(failure.code, privacy: .public))")
        }
    }

    // MARK: - Volume

    /// Spotify's own `sound volume`, the value its in-app slider shows.
    /// Spotify posts no notification when it changes, so it is only as
    /// fresh as the last `refreshVolume()`.
    private(set) var volume: Int?
    var supportsVolume: Bool { true }
    var bundleID: String? { Self.bundleID }
    private let scriptedVolume = ScriptedVolume(application: "Spotify")
    /// Spotify reads a written value back one lower; see `VolumeReadBack`.
    private var readBack = VolumeReadBack()

    /// A failure logs and keeps the last value read, like the modes read.
    func refreshVolume() {
        // Never Apple-Event a dead app: "tell application" would launch it.
        guard isPlayerRunning else { return }
        switch scriptedVolume.read() {
        case .success(let raw):
            let value = readBack.adjust(raw)
            if value != volume {
                Self.logger.notice(
                    "Volume read: \(value, privacy: .public)\(value != raw ? " (raw \(raw), read back one below the write)" : "", privacy: .public)")
            }
            volume = value
        case .failure(let failure):
            Self.logger.error(
                "Volume read failed (\(failure.code, privacy: .public)); keeping last known value")
        }
    }

    /// Chatter, not a state transition: the module logs the value a drag
    /// settles on at `.notice`, not every intermediate write.
    func setVolume(_ value: Int) {
        guard isPlayerRunning else { return }
        switch scriptedVolume.write(value) {
        case .success(let written):
            volume = written
            readBack.recordWrite(written)
            Self.logger.debug("Volume write: \(written, privacy: .public)")
        case .failure(let failure):
            Self.logger.error("Volume write failed (\(failure.code, privacy: .public))")
        }
    }

    func refresh() {
        // Never Apple-Event a dead app: "tell application" would launch it.
        guard isPlayerRunning else {
            lastSnapshot = nil
            onUpdate?(nil)
            return
        }
        // Deliberately no `guard !permissionDenied`. refresh() runs when the
        // module is switched on and, while denied, on track changes behind
        // `deniedRetry` (see `handleNotification`) — so a user who grants
        // access in System Settings recovers on a later track change instead
        // of having to relaunch. A genuine denial returns -1743 immediately
        // without re-prompting, so retrying cannot produce a dialog loop.
        switch AppleScriptRunner.run(Self.queryScript) {
        case .success(let descriptor):
            deniedRetry.reset()
            if permissionDenied {
                permissionDenied = false
                Self.logger.notice("Automation permission now granted; pull path re-enabled")
            }
            guard let output = descriptor.stringValue,
                  let parsed = SpotifyParsing.parse(scriptOutput: output)
            else {
                lastSnapshot = nil
                onUpdate?(nil)
                return
            }
            Self.logger.notice(
                "Pull ok: artwork=\(parsed.artworkURL == nil ? "none" : "url", privacy: .public), upNext=nil (no queue in dictionary)"
            )
            // BEFORE publish, deliberately: publishing is what makes
            // `MediaModule` mirror this adapter's extras onto its observable
            // properties, so the modes must already be current when it looks.
            // The old order read them after the publish, and the mirror was
            // permanently one refresh behind. Still skipped when the query
            // failed: no point probing modes on a pull path that is already
            // dead.
            refreshPlaybackModes()
            publish(parsed.snapshot)
            if let url = parsed.artworkURL { fetchArtwork(from: url) }
        case .failure(let failure):
            // Log every failure, not just denials. A -10000 from one
            // unimplemented property used to produce no adapter-level line
            // at all, so a totally dead pull path looked identical to a
            // healthy one — artwork silently missing with permission
            // reporting green. Never let a failure mode be silent again.
            if failure.isPermissionDenied {
                permissionDenied = true
                deniedRetry.recordFailure(at: ProcessInfo.processInfo.systemUptime)
                Self.logger.notice(
                    "Automation permission denied for Spotify; next pull retry on a track change after \(self.deniedRetry.currentDelay, privacy: .public)s")
            } else if failure.isTimeout {
                Self.logger.error(
                    "Spotify pull timed out (busy or hung); transient, retried on the next pull")
            } else {
                Self.logger.error(
                    "Spotify pull failed (\(failure.code, privacy: .public)) — not a permission problem; artwork and pull-only fields will be missing"
                )
            }
        }
    }

    private func publish(_ snapshot: NowPlaying) {
        var merged = snapshot
        // Keep artwork across pause/resume and metadata-only updates.
        if merged.artworkData == nil, let cache = artworkCache,
           merged.artworkIdentifier == lastSnapshot?.artworkIdentifier {
            merged.artworkData = cache.data
        }
        // Only the pull path parses an artwork URL; the notification path
        // has no such field. Same track means the last one still describes
        // it, so a notification-driven update does not blank it.
        if merged.artworkURL == nil,
           merged.artworkIdentifier == lastSnapshot?.artworkIdentifier {
            merged.artworkURL = lastSnapshot?.artworkURL
        }
        lastSnapshot = merged
        onUpdate?(merged)
    }

    // MARK: - Artwork

    private func fetchArtwork(from urlString: String) {
        if let cache = artworkCache, cache.url == urlString {
            attachArtwork(cache.data)
            return
        }
        guard let url = URL(string: urlString), url.scheme == "https" else { return }

        artworkTask?.cancel()
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                // The track may have changed while this downloaded: a
                // notification for the next track publishes before its own
                // pull. Attaching now would put this track's cover on that
                // one, and caching it would evict the right one.
                guard Self.artworkStillCurrent(downloadedFrom: urlString,
                                               current: self.lastSnapshot) else {
                    Self.logger.notice("Dropped artwork download for a track no longer current")
                    return
                }
                self.artworkCache = (urlString, data)
                self.attachArtwork(data)
            }
        }
        artworkTask?.resume()
    }

    /// Whether a download from `url` still belongs on the current snapshot.
    /// The URL is the identity: only the pull sets it, and a notification
    /// for a different track arrives without one, so a track change clears
    /// it (`publish` carries it forward only within the same track). Pure,
    /// for tests.
    nonisolated static func artworkStillCurrent(downloadedFrom url: String,
                                                current: NowPlaying?) -> Bool {
        current?.artworkURL == url
    }

    private func attachArtwork(_ data: Data) {
        guard var snapshot = lastSnapshot else { return }
        snapshot.artworkData = data
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    // MARK: - Commands

    func seek(to seconds: TimeInterval) {
        guard isPlayerRunning else { return }
        // Integer seconds sidestep locale decimal-separator issues in the
        // script source; nobody scrubs to sub-second precision by hand.
        let target = max(0, Int(seconds))
        if case .failure(let failure) = AppleScriptRunner.run(
            "tell application \"Spotify\" to set player position to \(target)"
        ) {
            if failure.isPermissionDenied { permissionDenied = true }
            return
        }
        // Optimistic: reflect the jump immediately rather than waiting for
        // Spotify's next notification.
        if var snapshot = lastSnapshot {
            snapshot.elapsed = TimeInterval(target)
            snapshot.capturedAt = Date()
            lastSnapshot = snapshot
            onUpdate?(snapshot)
        }
    }

    func send(_ command: MediaCommand) {
        guard isPlayerRunning else { return }
        let verb: String
        switch command {
        case .play: verb = "play"
        case .pause: verb = "pause"
        case .togglePlayPause: verb = "playpause"
        case .nextTrack: verb = "next track"
        case .previousTrack: verb = "previous track"
        }
        if case .failure(let failure) = AppleScriptRunner.run("tell application \"Spotify\" to \(verb)") {
            if failure.isPermissionDenied { permissionDenied = true }
            return
        }
        // Play/pause always broadcast, so they need nothing. Next and
        // previous move the playhead and cannot be trusted to: see
        // `reanchorAfterTransport`.
        switch command {
        case .nextTrack, .previousTrack: reanchorAfterTransport()
        case .play, .pause, .togglePlayPause: break
        }
    }

    // MARK: - Re-anchor after transport

    /// Spotify broadcasts `PlaybackStateChanged` on play, pause, and any real
    /// track change — but **not** when `previous track` restarts the track
    /// already playing, which is what it does whenever you are more than a
    /// few seconds in. Measured 2026-08-29: position went 6.1s -> 0 with no
    /// notification in the following 15 seconds.
    ///
    /// Position is projected locally from `(elapsed, capturedAt)`, so with no
    /// notification that anchor stays on the old value and the bar keeps
    /// counting *up* past where the audio actually is, until a play/pause
    /// happens to re-anchor it. `seek(to:)` already solves this same class of
    /// problem optimistically; this is the transport equivalent, except the
    /// new position has to be read back rather than assumed, because
    /// "previous" means restart-or-step-back depending on the position.
    ///
    /// One delayed shot, never a poll: the player needs a moment to settle
    /// before it reports the new position (notifications for real track
    /// changes were measured at 137-259ms), and this runs only in response to
    /// a transport button being pressed.
    private func reanchorAfterTransport() {
        reanchorTask?.cancel()
        reanchorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.transportSettleMS))
            guard !Task.isCancelled else { return }
            self?.reanchor()
        }
    }

    private static let transportSettleMS = 350

    /// Two fields only. Everything else the notch shows is either unchanged
    /// (same track) or arrives with the full pull (new track).
    private static let anchorScript = """
        tell application "Spotify"
            if player state is stopped then return "stopped"
            return (player position as text) & "\\n" & (id of current track as text)
        end tell
        """

    private func reanchor() {
        guard isPlayerRunning else { return }
        switch AppleScriptRunner.run(Self.anchorScript) {
        case .success(let descriptor):
            guard let output = descriptor.stringValue,
                  let anchor = SpotifyParsing.parseAnchor(output) else { return }

            // Track changed: hand off to the full pull, which publishes
            // complete metadata. MediaModule's existing new-track path then
            // sees the changed identifier and re-fetches lyrics.
            guard anchor.trackID == lastSnapshot?.artworkIdentifier else {
                Self.logger.notice("Transport changed track; pulling full state")
                refresh()
                return
            }
            guard var snapshot = lastSnapshot else { return }
            snapshot.elapsed = anchor.position
            snapshot.capturedAt = Date()
            lastSnapshot = snapshot
            onUpdate?(snapshot)
            Self.logger.notice(
                "Re-anchored same track at \(anchor.position, format: .fixed(precision: 2), privacy: .public)s"
            )
        case .failure(let failure):
            Self.logger.error("Re-anchor pull failed (\(failure.code, privacy: .public))")
        }
    }
}

/// Pure parsing, split out for tests.
enum SpotifyParsing {

    /// Decodes the distributed notification's userInfo. Returns nil when
    /// there is nothing to show (stopped, or the payload is unrecognisable).
    static func decode(notification userInfo: [AnyHashable: Any]) -> NowPlaying? {
        guard let state = userInfo["Player State"] as? String, state != "Stopped" else {
            return nil
        }
        var snapshot = NowPlaying()
        snapshot.isPlaying = state == "Playing"
        snapshot.title = userInfo["Name"] as? String
        snapshot.artist = userInfo["Artist"] as? String
        snapshot.album = userInfo["Album"] as? String
        if let ms = (userInfo["Duration"] as? NSNumber)?.doubleValue {
            snapshot.duration = ms / 1000
        }
        snapshot.elapsed = (userInfo["Playback Position"] as? NSNumber)?.doubleValue
        snapshot.artworkIdentifier = userInfo["Track ID"] as? String
        snapshot.sourceBundleID = SpotifyAdapter.bundleID
        return snapshot.hasContent ? snapshot : nil
    }

    /// Parses the two-field anchor output: position in seconds, track id.
    /// Nil when the player is stopped or the output is not what we asked for.
    static func parseAnchor(_ output: String) -> (position: TimeInterval, trackID: String)? {
        guard output != "stopped" else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2,
              // AppleScript renders reals with the locale's decimal separator.
              let position = Double(lines[0].replacingOccurrences(of: ",", with: ".")),
              !lines[1].isEmpty
        else { return nil }
        return (position, lines[1])
    }

    /// Parses the query script's newline-separated output:
    /// state, title, artist, album, duration-ms, position-s, artwork URL, id.
    ///
    /// Eight fields, and deliberately no ninth. `starred` was appended here
    /// once and reverted — see the note on `SpotifyAdapter`.
    static func parse(scriptOutput: String)
        -> (snapshot: NowPlaying, artworkURL: String?)? {
        guard scriptOutput != "stopped" else { return nil }
        let lines = scriptOutput.components(separatedBy: "\n")
        guard lines.count >= 8 else { return nil }

        var snapshot = NowPlaying()
        snapshot.isPlaying = lines[0] == "playing"
        snapshot.title = lines[1].isEmpty ? nil : lines[1]
        snapshot.artist = lines[2].isEmpty ? nil : lines[2]
        snapshot.album = lines[3].isEmpty ? nil : lines[3]
        // AppleScript renders reals with the locale's decimal separator.
        if let ms = Double(lines[4].replacingOccurrences(of: ",", with: ".")) {
            snapshot.duration = ms / 1000
        }
        snapshot.elapsed = Double(lines[5].replacingOccurrences(of: ",", with: "."))
        snapshot.artworkIdentifier = lines[7].isEmpty ? nil : lines[7]
        snapshot.sourceBundleID = SpotifyAdapter.bundleID

        guard snapshot.hasContent else { return nil }
        let url = lines[6].isEmpty ? nil : lines[6]
        // Carried on the snapshot as well as in the tuple: history stores a
        // URL rather than bytes, and this is the only source that has one.
        // The tuple member stays because `fetchArtwork` wants it regardless.
        snapshot.artworkURL = url
        return (snapshot, url)
    }
}

/// Spaces out retries of a pull that keeps being refused.
///
/// Exponential from `base`, capped at `cap`: 30s, 60s, 120s ... 10 min.
/// Nothing here schedules anything — it only answers "may I retry yet?"
/// when something else (a track-change notification) already wants to, so
/// it is not a poll (hard rule 9). Pure, for tests; times are
/// `systemUptime` seconds.
nonisolated struct PullRetryBackoff {
    static let base: TimeInterval = 30
    static let cap: TimeInterval = 600

    private(set) var failures = 0
    private(set) var nextAllowed: TimeInterval = 0

    /// The wait the last failure imposed, for the log.
    var currentDelay: TimeInterval {
        failures == 0 ? 0 : min(Self.cap, Self.base * pow(2, Double(failures - 1)))
    }

    func allows(at now: TimeInterval) -> Bool { now >= nextAllowed }

    mutating func recordFailure(at now: TimeInterval) {
        failures += 1
        nextAllowed = now + currentDelay
    }

    mutating func reset() {
        failures = 0
        nextAllowed = 0
    }
}
