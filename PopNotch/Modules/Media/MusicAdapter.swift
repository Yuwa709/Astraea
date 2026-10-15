import AppKit
import os

/// Reads and controls Apple Music (Music.app).
///
/// Same two-channel shape as `SpotifyAdapter`:
/// - **Push:** Music broadcasts `com.apple.Music.playerInfo` on track and
///   state changes. Used only as a *trigger* — its payload is thinner than
///   the scripting dictionary and its key names have moved across releases,
///   so nothing is decoded from it.
/// - **Pull:** one AppleScript query per change returns every field at once,
///   including the queue lookup. One Apple Event, not five.
///
/// Where this differs from Spotify, and why, verified against `sdef`:
/// - **`duration` is in seconds** here, milliseconds there. Getting this
///   backwards yields a 1000x progress bar, so it is asserted in tests.
/// - **`favorited` is read-write**, so this source reports `.editable` and
///   implements `setFavorite`. Spotify's `starred` is `access="r"`.
/// - **A real queue exists**, via `current playlist` + the track's `index`.
///   See `upNextScriptFragment` for the three cases where it is refused.
@MainActor
final class MusicAdapter: MediaSource {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Music")
    static let bundleID = "com.apple.Music"
    static let notificationName = Notification.Name("com.apple.Music.playerInfo")

    /// Spelled once. History rows carry this string and are matched against
    /// it later, so a literal in two places would silently stop agreeing.
    static let sourceIdentifier = "music"

    let sourceID = MusicAdapter.sourceIdentifier
    var onUpdate: ((NowPlaying?) -> Void)?
    private(set) var permissionDenied = false
    private(set) var upNext: UpNextTrack?
    private(set) var favorite: FavoriteState = .unsupported

    private var observer: NSObjectProtocol?
    private var lastSnapshot: NowPlaying?
    /// One-shot re-anchor after a transport command; see the note on
    /// `reanchorAfterTransport`.
    private var reanchorTask: Task<Void, Never>?
    /// Keyed by persistent ID so artwork is pulled once per track, never on
    /// pause/resume. Artwork here is raw bytes from the app, not a URL.
    private var artworkCache: (trackID: String, data: Data)?

    /// Every Apple Event this adapter sends goes through `runScript`, and
    /// "is Music open" through `playerRunning`. Production uses the real
    /// runner and `NSWorkspace`; tests inject both, so the pull path is
    /// exercised without driving — or launching — the real Music.app.
    typealias ScriptRunner = @MainActor (String) -> Result<NSAppleEventDescriptor, AppleScriptRunner.Failure>
    private let runScript: ScriptRunner
    private let playerRunning: @MainActor () -> Bool

    init(runScript: @escaping ScriptRunner = { AppleScriptRunner.run($0) },
         playerRunning: @escaping @MainActor () -> Bool = {
             // `isTerminated` matters while Music quits: it is still in the
             // list for a moment, and an Apple Event then relaunches it.
             NSWorkspace.shared.runningApplications.contains {
                 $0.bundleIdentifier == MusicAdapter.bundleID && !$0.isTerminated
             }
         }) {
        self.runScript = runScript
        self.playerRunning = playerRunning
    }

    var isPlayerRunning: Bool { playerRunning() }

    // MARK: - Observing

    func startObserving() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            let state = note.userInfo?["Player State"] as? String
            MainActor.assumeIsolated { self?.handlePlayerInfo(playerState: state) }
        }
        Self.logger.notice("Observing Music playback notifications")
    }

    /// One `playerInfo` notification. The payload is still only a trigger,
    /// with one exception: its `Player State`. Music posts "Stopped" while
    /// it quits, and pulling then sends `tell application "Music"` to an app
    /// on its way out — which can relaunch it. A stopped player has nothing
    /// to show anyway, so the state is cleared with no Apple Event at all,
    /// exactly what the pull would have concluded from "stopped".
    ///
    /// Internal so tests can drive it with an injected runner.
    func handlePlayerInfo(playerState: String?) {
        guard Self.shouldPull(afterPlayerState: playerState) else {
            Self.logger.notice("Music reported Stopped; cleared without an Apple Event")
            clearState()
            return
        }
        refresh()
    }

    /// False only for an explicit "Stopped". A missing or unfamiliar state
    /// still pulls: the key names have moved across releases (see the type
    /// note), and a pull is the safe default. Pure, for tests.
    nonisolated static func shouldPull(afterPlayerState state: String?) -> Bool {
        state != "Stopped"
    }

    func stopObserving() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        reanchorTask?.cancel()
        reanchorTask = nil
    }

    // MARK: - Pull

    /// Up Next is refused in three cases, all of which make `index + 1` mean
    /// something other than "the track that plays next":
    /// - `shuffle enabled` — play order is randomised, so the next index is
    ///   not the next track.
    /// - `fixed indexing` — the dictionary defines this as making indices
    ///   "independent of the play order of the owning playlist", which is
    ///   precisely the guarantee this lookup depends on.
    /// - the current track is last in the playlist, or there is no current
    ///   playlist at all (a bare file, or a stream).
    ///
    /// The reason is returned so a nil Up Next can be explained in the log
    /// rather than looking like a failure.
    private static let upNextScriptFragment = """
            if shuffle enabled then
                set skipReason to "shuffle"
            else if fixed indexing then
                set skipReason to "fixed-indexing"
            else
                try
                    set pl to current playlist
                    set idx to index of t
                    if idx < (count of tracks of pl) then
                        set nt to track (idx + 1) of pl
                        set nextName to (name of nt as text)
                        set nextArtist to (artist of nt as text)
                    else
                        set skipReason to "last-in-playlist"
                    end if
                on error
                    set skipReason to "no-playlist"
                end try
            end if
    """

    /// Internal, not private, so tests can pin the Up Next derivation's
    /// shape: the index arithmetic runs inside Music, not in Swift.
    static let queryScript = """
        tell application "Music"
            if player state is stopped then return "stopped"
            set t to current track
            set nextName to ""
            set nextArtist to ""
            set skipReason to ""
        \(upNextScriptFragment)
            return (player state as text) & "\\n" & (name of t as text) \
                & "\\n" & (artist of t as text) & "\\n" & (album of t as text) \
                & "\\n" & (duration of t as text) & "\\n" & (player position as text) \
                & "\\n" & (persistent ID of t as text) & "\\n" & (favorited of t as text) \
                & "\\n" & nextName & "\\n" & nextArtist & "\\n" & skipReason
        end tell
        """

    func refresh() {
        // Never Apple-Event a dead app: "tell application" would launch it.
        guard isPlayerRunning else {
            clearState()
            return
        }
        // No `guard !permissionDenied`, for the same reason as Spotify: a
        // user who grants access in System Settings recovers on the next
        // `playerInfo` notification, which pulls whatever the last outcome
        // was. A real denial returns -1743 without re-prompting, and Music
        // posts only on playback changes, so this is no loop.
        switch runScript(Self.queryScript) {
        case .success(let descriptor):
            if permissionDenied {
                permissionDenied = false
                Self.logger.notice("Automation permission now granted for Music; pull path re-enabled")
            }
            guard let output = descriptor.stringValue,
                  let parsed = MusicParsing.parse(scriptOutput: output)
            else {
                clearState()
                return
            }
            upNext = parsed.upNext
            favorite = .editable(parsed.favorited)
            Self.logger.notice(
                """
                Pull ok: favorited=\(parsed.favorited, privacy: .public), \
                upNext=\(parsed.upNext?.title ?? "none", privacy: .public)\
                \(parsed.upNextSkipReason.map { " (\($0))" } ?? "", privacy: .public)
                """
            )
            publish(parsed.snapshot)
            fetchArtworkIfNeeded(trackID: parsed.snapshot.artworkIdentifier)
        case .failure(let failure):
            if failure.isPermissionDenied {
                permissionDenied = true
                Self.logger.notice("Automation permission denied for Music; pull path disabled")
            }
            dropUpNext(afterFailure: failure.code)
        }
    }

    /// A failed pull says nothing about the queue, and a next track kept
    /// from before the failure may no longer be next — so the row hides
    /// rather than risk being wrong. The rest of the snapshot is kept: the
    /// track the user is hearing has not changed because one read failed.
    ///
    /// Republished because the module mirrors `upNext` only inside an
    /// update; setting it here alone would leave the row on screen.
    private func dropUpNext(afterFailure code: Int) {
        guard upNext != nil else { return }
        upNext = nil
        Self.logger.notice("Pull failed (\(code, privacy: .public)); Up Next hidden")
        if let lastSnapshot { onUpdate?(lastSnapshot) }
    }

    private func clearState() {
        lastSnapshot = nil
        upNext = nil
        favorite = .unsupported
        onUpdate?(nil)
    }

    private func publish(_ snapshot: NowPlaying) {
        var merged = snapshot
        if merged.artworkData == nil, let cache = artworkCache,
           cache.trackID == merged.artworkIdentifier {
            merged.artworkData = cache.data
        }
        lastSnapshot = merged
        onUpdate?(merged)
    }

    // MARK: - Artwork

    /// Music hands over raw image bytes rather than a URL, so there is no
    /// network call here at all — this is the one place Apple Music is
    /// cheaper than Spotify. Best-effort: artwork can be genuinely absent
    /// (streams, unmatched files), which is not an error worth surfacing.
    private func fetchArtworkIfNeeded(trackID: String?) {
        guard let trackID, !trackID.isEmpty else { return }
        if artworkCache?.trackID == trackID {
            attachArtwork(artworkCache?.data)
            return
        }
        let script = """
            tell application "Music"
                if (count of artworks of current track) is 0 then return missing value
                return data of artwork 1 of current track
            end tell
            """
        guard case .success(let descriptor) = runScript(script) else { return }
        guard let data = descriptor.data as Data?, !data.isEmpty,
              NSImage(data: data) != nil else {
            Self.logger.notice("No usable artwork for track \(trackID, privacy: .public)")
            return
        }
        artworkCache = (trackID, data)
        attachArtwork(data)
    }

    private func attachArtwork(_ data: Data?) {
        guard let data, var snapshot = lastSnapshot else { return }
        snapshot.artworkData = data
        lastSnapshot = snapshot
        onUpdate?(snapshot)
    }

    // MARK: - Volume

    /// Music's own application-level `sound volume`, the value its in-app
    /// slider shows. Like Spotify, no notification says when it changes.
    private(set) var volume: Int?
    var supportsVolume: Bool { true }
    var bundleID: String? { Self.bundleID }
    private let scriptedVolume = ScriptedVolume(application: "Music")

    /// A failure logs and keeps the last value read. It deliberately does
    /// not set `permissionDenied`: a read on the live-sync cadence must not
    /// be able to change what the main query concluded.
    func refreshVolume() {
        // Never Apple-Event a dead app: "tell application" would launch it.
        guard isPlayerRunning else { return }
        switch scriptedVolume.read() {
        case .success(let value):
            if value != volume {
                Self.logger.notice("Volume read: \(value, privacy: .public)")
            }
            volume = value
        case .failure(let failure):
            Self.logger.error(
                "Volume read failed (\(failure.code, privacy: .public)); keeping last known value")
        }
    }

    /// A user-driven write, so a denial is recorded the way `send` records
    /// one. The module logs the value a drag settles on at `.notice`.
    func setVolume(_ value: Int) {
        guard isPlayerRunning else { return }
        switch scriptedVolume.write(value) {
        case .success(let written):
            volume = written
            Self.logger.debug("Volume write: \(written, privacy: .public)")
        case .failure(let failure):
            if failure.isPermissionDenied { permissionDenied = true }
            Self.logger.error("Volume write failed (\(failure.code, privacy: .public))")
        }
    }

    // MARK: - Commands

    func seek(to seconds: TimeInterval) {
        guard isPlayerRunning else { return }
        let target = max(0, Int(seconds))
        if case .failure(let failure) = runScript(
            "tell application \"Music\" to set player position to \(target)"
        ) {
            if failure.isPermissionDenied { permissionDenied = true }
            return
        }
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
        if case .failure(let failure) = runScript("tell application \"Music\" to \(verb)") {
            if failure.isPermissionDenied { permissionDenied = true }
            return
        }
        switch command {
        case .nextTrack, .previousTrack: reanchorAfterTransport()
        case .play, .pause, .togglePlayPause: break
        }
    }

    // MARK: - Re-anchor after transport

    /// Same reasoning as `SpotifyAdapter`: position is projected locally from
    /// `(elapsed, capturedAt)`, so a transport command that moves the
    /// playhead without producing a notification leaves the notch counting up
    /// from a stale anchor. Applied here for parity — Music's notification
    /// behaviour on a restarting "previous" has not been measured, and
    /// assuming it is better than Spotify's is exactly the assumption this
    /// project keeps getting burned by.
    ///
    /// One delayed shot, never a poll, and only on a transport press.
    private func reanchorAfterTransport() {
        reanchorTask?.cancel()
        reanchorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.transportSettleMS))
            guard !Task.isCancelled else { return }
            self?.reanchor()
        }
    }

    private static let transportSettleMS = 350

    /// `persistent ID` is wrapped in a `try` on purpose. It is still in the
    /// UNVERIFIED column of the property audit (docs/BLOCKED.md), and the
    /// `starred` incident showed that one unimplemented property aborts the
    /// entire `return`. Degrading to an empty id costs a track-change check;
    /// taking the whole script down would cost the position too.
    private static let anchorScript = """
        tell application "Music"
            if player state is stopped then return "stopped"
            set tid to ""
            try
                set tid to (persistent ID of current track as text)
            end try
            return (player position as text) & "\\n" & tid
        end tell
        """

    private func reanchor() {
        guard isPlayerRunning else { return }
        switch runScript(Self.anchorScript) {
        case .success(let descriptor):
            guard let output = descriptor.stringValue,
                  let anchor = MusicParsing.parseAnchor(output) else { return }

            // A known, changed id means a new track: the full pull publishes
            // complete metadata and MediaModule's new-track path handles
            // lyrics. An empty id means the property failed, so fall through
            // to re-anchoring position only — which is the stale value.
            if let trackID = anchor.trackID, trackID != lastSnapshot?.artworkIdentifier {
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

    /// Music's `favorited` is read-write, so unlike Spotify this is a real
    /// toggle. Optimistic: the UI reflects the change immediately and the
    /// next pull corrects it if the write was refused.
    func setFavorite(_ on: Bool) {
        guard isPlayerRunning, case .editable = favorite else { return }
        favorite = .editable(on)
        if case .failure(let failure) = runScript(
            "tell application \"Music\" to set favorited of current track to \(on)"
        ) {
            if failure.isPermissionDenied { permissionDenied = true }
            Self.logger.notice("Favourite write refused (\(failure.code, privacy: .public)); reverting")
            favorite = .editable(!on)
            return
        }
        Self.logger.notice("Favourited set to \(on, privacy: .public)")
    }

    /// Music's `lyrics` property, read on demand rather than in the main
    /// query — most tracks have none, and a whole lyric sheet is not worth
    /// carrying through the per-tick snapshot script.
    ///
    /// Usually plain text. `LyricsService` decides whether it is timed.
    func embeddedLyrics() -> String? {
        guard isPlayerRunning, !permissionDenied else { return nil }
        let script = "tell application \"Music\" to get lyrics of current track"
        guard case .success(let descriptor) = runScript(script),
              let text = descriptor.stringValue, !text.isEmpty
        else {
            Self.logger.notice("No embedded lyrics on current Music track")
            return nil
        }
        Self.logger.notice("Read \(text.count, privacy: .public) chars of embedded lyrics from Music")
        return text
    }
}

/// Pure parsing, split out for tests.
enum MusicParsing {

    /// Parses the two-field anchor output: position in seconds, track id.
    /// The id is optional — see the note on `MusicAdapter.anchorScript`.
    /// A stopped Music reports `missing value` for position, which is not a
    /// number and correctly yields nil rather than zero.
    static func parseAnchor(_ output: String) -> (position: TimeInterval, trackID: String?)? {
        guard output != "stopped" else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 2,
              let position = Double(lines[0].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return (position, lines[1].isEmpty ? nil : lines[1])
    }

    /// Field order matches `MusicAdapter.queryScript`: state, title, artist,
    /// album, duration-s, position-s, persistent ID, favorited, next title,
    /// next artist, skip reason.
    static func parse(scriptOutput: String)
        -> (snapshot: NowPlaying,
            favorited: Bool,
            upNext: UpNextTrack?,
            upNextSkipReason: String?)? {

        guard scriptOutput != "stopped" else { return nil }
        let lines = scriptOutput.components(separatedBy: "\n")
        guard lines.count >= 11 else { return nil }

        var snapshot = NowPlaying()
        snapshot.isPlaying = lines[0] == "playing"
        snapshot.title = lines[1].isEmpty ? nil : lines[1]
        snapshot.artist = lines[2].isEmpty ? nil : lines[2]
        snapshot.album = lines[3].isEmpty ? nil : lines[3]
        // Music reports seconds; Spotify reports milliseconds. Do not divide.
        // AppleScript renders reals with the locale's decimal separator.
        snapshot.duration = Double(lines[4].replacingOccurrences(of: ",", with: "."))
        snapshot.elapsed = Double(lines[5].replacingOccurrences(of: ",", with: "."))
        snapshot.artworkIdentifier = lines[6].isEmpty ? nil : lines[6]
        snapshot.sourceBundleID = MusicAdapter.bundleID

        guard snapshot.hasContent else { return nil }

        let favorited = lines[7] == "true"
        let nextTitle = lines[8]
        let nextArtist = lines[9]
        let reason = lines[10]

        // A next track requires a title; the artist may legitimately be blank.
        let upNext = nextTitle.isEmpty ? nil : UpNextTrack(title: nextTitle, artist: nextArtist)
        return (snapshot, favorited, upNext, reason.isEmpty ? nil : reason)
    }
}
