import SwiftUI
import Observation
import os

/// Now playing in the notch — the reason the app exists.
///
/// Owns the player adapters; the active snapshot is whichever source
/// reported most recently. Sources observe by push (no timers), so the
/// module hears track changes even while not displayed and answers them by
/// requesting a live activity: the notch pops open with the new song.
@MainActor
@Observable
final class MediaModule: NotchModule {

    @ObservationIgnored
    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Media")

    /// Permanent settings key; never rename.
    @ObservationIgnored let id: ModuleID = "media"
    @ObservationIgnored let displayName = "Now Playing"
    @ObservationIgnored let priority: ModulePriority = .elevated
    /// Switching on is what starts observation and pulls the players: at
    /// launch, where `NotchCoordinator.register` applies the stored
    /// preference, and again when re-enabled from Settings. Switching off
    /// stops every source — notifications, the system stream, artwork and
    /// lyrics lookups — and clears what was showing. Neither happens in
    /// `init`, so a user who has media switched off never sends an Apple
    /// Event, never sees the Automation prompt, and never runs the system
    /// now-playing subprocess, not even briefly at launch.
    @ObservationIgnored var isEnabled = true {
        didSet { applyEnabled() }
    }

    /// Whether the sources are currently observing, so a repeated
    /// assignment of the same value neither restarts nor re-stops them.
    @ObservationIgnored private(set) var sourcesObserving = false

    /// Seconds the notch stays open on a track change.
    @ObservationIgnored static let popDuration: TimeInterval = 4

    /// Wired by AppDelegate to the coordinator.
    @ObservationIgnored var onLiveActivityRequest: ((LiveActivityRequest) -> Void)?

    /// Fires when whether-there-is-anything-to-show flips — the coordinator
    /// resizes the collapsed panel between idle and compact on it. Content
    /// *changes* do not fire it; the wing views observe those themselves.
    @ObservationIgnored var onPresenceChange: (() -> Void)?

    /// Fires when expanded-content height changes shape (lyrics appearing or
    /// clearing), so the coordinator can re-measure the open panel.
    @ObservationIgnored var onContentReflow: (() -> Void)?

    private(set) var nowPlaying: NowPlaying?
    /// Synced lyrics for the current track, nil while absent or unfetched.
    private(set) var lyrics: [LyricsLine]?

    /// True while a lyrics lookup is running for a track that *replaced* a
    /// track which had lyrics. The view keeps the lyric area at full height
    /// while it is set, so the panel does not shrink on the transient nil.
    ///
    /// This exists because the panel is top-anchored: shrinking pulls the
    /// bottom edge up past the transport buttons, so the cursor that just
    /// pressed Next ends up outside the frame and AppKit fires a *correct*
    /// mouseExited, which collapses the panel. Measured: a 59pt drop, from a
    /// 275pt panel to 216pt, with the transport row sitting inside the band
    /// that vanishes.
    private(set) var lyricsReserved = false

    /// Whether the lyric area currently occupies its full height — either
    /// showing lyrics, or holding the space for a lookup in flight. Reflow is
    /// driven by changes to *this*, not to `lyrics`, so content swapping
    /// inside an unchanged height never resizes the panel.
    var lyricsOccupiesHeight: Bool { lyrics != nil || lyricsReserved }
    /// Accent pulled from the current artwork; views fall back to the fixed
    /// peach when nil (colorless art, or artwork not yet loaded).
    private(set) var artworkAccent: Color?
    /// Decoded once per artwork change rather than per render — the
    /// visualizer needs an NSImage and SwiftUI bodies run often.
    private(set) var artworkImage: NSImage?
    /// The glow palette, computed once per artwork change beside the accent.
    /// It used to be computed in the visualiser's `onAppear` — a TIFF encode
    /// and three Core Image renders on the main thread on every expand.
    private(set) var artworkPalette: ArtworkPalette?
    @ObservationIgnored private var accentSourceData: Data?

    /// Up Next and favourite, mirrored from the active source.
    private(set) var upNext: UpNextTrack?
    private(set) var likedCurrent: Bool?
    /// Shuffle and repeat, mirrored from the active source the same way
    /// `likedCurrent` and `upNext` are. The mirror is the point: the
    /// adapters are not `@Observable`, so a view reading them directly
    /// renders whatever was true at its last unrelated re-evaluation.
    /// These are observable stored properties, and writing them is what
    /// makes the buttons redraw.
    private(set) var shuffling: Bool?
    private(set) var repeating: Bool?
    /// The current player's own volume, and whether it has one, mirrored
    /// for the same reason. `volume` is also where a drag writes first, so
    /// the slider redraws under the pointer before the Apple Event lands.
    private(set) var volume: Int?
    private(set) var volumeSupported = false
    /// Every scripted player's volume by bundle ID, as last read or written;
    /// `volume` above is this for the active source. The mixer page's
    /// Spotify and Music rows read and write it through
    /// `ScriptedPlayerVolumes`, so the row and the player slider are one
    /// value: moving either moves the other.
    private(set) var playerVolumes: [String: Int] = [:]

    /// When true the expanded notch shows full scrolling lyrics instead of
    /// the player, and stays open regardless of hover until dismissed.
    private(set) var showFullLyrics = false

    @ObservationIgnored private let sources: [MediaSource]
    @ObservationIgnored private let lyricsService = LyricsService()
    /// Injected, not owned. The progress row renders the spectrum, and this
    /// module is what tells the service whether they may capture: the
    /// tracked player's play state, and whether the player screen, whose
    /// progress row draws it, is on screen. Nil in tests that do not care.
    @ObservationIgnored let visualizer: AudioVisualizerService?
    /// The open panel's live-sync clock. Exists only between
    /// `didBecomeVisible()` and `didResignVisible()`, and is stopped by
    /// display sleep in between — hard rule 9, all three clauses.
    @ObservationIgnored private var liveSyncTimer: Timer?
    @ObservationIgnored private var liveSyncWanted = false
    /// Between `didBecomeVisible()` and `didResignVisible()`: this module's
    /// expanded view is on screen. The spectrum needs this as well as the
    /// screen, because the player stays the current screen of a closed panel.
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private var displayAsleep = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []

    /// Two seconds: the three-property read costs ~50ms on the main actor, so
    /// this is a 2.5% duty cycle. One second would double it for a playhead
    /// the local projection already keeps smooth between reads.
    static let liveSyncInterval: TimeInterval = 2

    /// Whether the clock is running. Exposed so "nothing polls while the panel
    /// is closed" is a test rather than a comment.
    var isLiveSyncing: Bool { liveSyncTimer != nil }

    /// How long after the panel opens the volume is read: past the expand
    /// animation (0.21s plus a 0.13s settle, `NotchPanel`), because the read
    /// is a synchronous Apple Event that would otherwise drop frames from it.
    static let volumeReadDelay: Duration = .milliseconds(400)

    /// At most one volume write per this interval while dragging. A write
    /// is ~17ms of main-actor IPC, so this caps a drag at roughly 8% of the
    /// main thread, and the player's volume audibly follows five times a
    /// second. The release always writes the final value regardless.
    static let volumeSendInterval: TimeInterval = 0.2

    @ObservationIgnored private var volumeReadTask: Task<Void, Never>?
    @ObservationIgnored private var volumeThrottle = VolumeSendThrottle(interval: MediaModule.volumeSendInterval)
    @ObservationIgnored private var pendingVolume: Int?
    @ObservationIgnored private var trailingVolumeSend: Task<Void, Never>?
    /// True from the first drag event to the release. While set, reads and
    /// publishes leave `volume` alone, or a read landing mid-drag would
    /// snap the slider back to a value from before the latest write.
    @ObservationIgnored private(set) var isEditingVolume = false
    /// The player the open edit writes to, fixed when the edit begins: the
    /// active source for the player slider, the row's own player for the
    /// mixer page. Fixed so a change of active source mid-drag cannot
    /// redirect the writes. Nil falls back to the active source.
    @ObservationIgnored private var volumeEditSource: (any MediaSource)?

    @ObservationIgnored private var lastTrackKey: String?
    @ObservationIgnored private var hadPresence = false
    @ObservationIgnored private var hadExpandedContent = false

    /// Which adapter currently owns the notch. Written only by
    /// `handleUpdate(_:from:)`; every command routes here rather than to
    /// "the first running player", which was correct only while one adapter
    /// existed.
    @ObservationIgnored private var activeSource: (any MediaSource)?

    /// What each source last reported, keyed by `sourceID`, holding only
    /// snapshots with content. `shouldTakeOver` needs to know whether a
    /// *dedicated* adapter has anything, which cannot be answered from the
    /// one snapshot currently being delivered.
    @ObservationIgnored private var snapshots: [ModuleID: NowPlaying] = [:]

    /// True when Spotify or Music has a track — playing or paused. The system
    /// source is a fallback and may not take the notch while this holds.
    private var dedicatedSourceHasContent: Bool {
        sources.contains { !($0 is SystemMediaAdapter) && snapshots[$0.sourceID] != nil }
    }

    /// Where the notch goes when the owner falls silent: whoever still has
    /// something, dedicated adapters ahead of the system source.
    private func fallbackSource(excluding source: any MediaSource) -> (any MediaSource)? {
        let candidates = sources.filter { $0 !== source && snapshots[$0.sourceID] != nil }
        return candidates.first { !($0 is SystemMediaAdapter) } ?? candidates.first
    }

    /// Whether the current track's favourite can be changed: only when the
    /// source itself can write it. Spotify never can — its `starred` is
    /// unimplemented in the dictionary — so the UI never offers it a toggle.
    var canToggleFavorite: Bool {
        activeSource?.favorite.isEditable ?? false
    }

    /// Drives the in-notch "allow Automation" banner, which renders only
    /// when the widget is empty. Denial explains emptiness only for a player
    /// that is actually **running**: its pull path is dead, so there is
    /// nothing to show. A denied-but-closed player is not the reason the
    /// widget is empty — granting it would display nothing — and belongs to
    /// the Permissions tab, not this banner.
    ///
    /// Was `allSatisfy` when one adapter existed; with two, a never-probed
    /// MusicAdapter kept its flag false forever and a denied Spotify could
    /// never surface the banner.
    var permissionDenied: Bool {
        sources.contains { $0.isPlayerRunning && $0.permissionDenied }
    }

    /// What the expanded view shows, in branch order: the full-lyrics
    /// takeover, the player, the permission banner, or nothing.
    ///
    /// The one place that condition lives. `MediaExpandedView` switches on
    /// it and `hasExpandedContent` tests it for nil; neither restates the
    /// tests, so the panel's chrome-only decision cannot drift from what
    /// the view would actually draw.
    enum ExpandedScreen {
        case fullLyrics
        case player(NowPlaying)
        case permissionDenied
    }

    var expandedScreen: ExpandedScreen? {
        if showFullLyrics { return .fullLyrics }
        if let playing = nowPlaying, playing.hasContent { return .player(playing) }
        if permissionDenied { return .permissionDenied }
        return nil
    }

    var hasExpandedContent: Bool { expandedScreen != nil }

    init(sources: [MediaSource],
         visualizer: AudioVisualizerService? = nil) {
        self.sources = sources
        self.visualizer = visualizer
        for source in sources {
            source.onUpdate = { [weak self, weak source] snapshot in
                guard let source else { return }
                self?.handleUpdate(snapshot, from: source)
            }
            // Not started here: `isEnabled`'s setter starts observation, so
            // a module registered disabled never starts it at all.
        }

        // Display sleep stops the clock and the spectrum capture even with
        // the panel pinned open — the same observers every polling service in
        // this app carries. Block-based rather than selector-based: this
        // class is not an NSObject, and `SpotifyAdapter` already uses this
        // exact form.
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setDisplayAsleep(true) }
            },
            center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                               object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setDisplayAsleep(false) }
            }
        ]
    }

    /// Display sleep and wake. Internal so tests can drive it without a
    /// real display.
    func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        Self.logger.notice("Display \(asleep ? "asleep" : "awake", privacy: .public); live sync and spectrum re-evaluated")
        updateLiveSync()
        updateSpectrumVisibility()
        // A system now-playing stream that died, and used up its restart
        // budget, gets another chance on wake — only while media is on.
        if !asleep, isEnabled {
            for case let system as SystemMediaAdapter in sources { system.recoverStream() }
        }
    }

    /// Starts or stops every source to match `isEnabled`. The one place
    /// observation changes, so it cannot drift from the setting.
    private func applyEnabled() {
        if isEnabled {
            if !sourcesObserving {
                sourcesObserving = true
                sources.forEach { $0.startObserving() }
                Self.logger.notice("Media enabled; sources observing")
            }
            pullSources()
        } else if sourcesObserving {
            sourcesObserving = false
            sources.forEach { $0.stopObserving() }
            clearForDisable()
            Self.logger.notice("Media disabled; sources stopped")
        }
    }

    /// Drops everything the sources had reported, so nothing stale shows on
    /// re-enable and the visualiser's tap, gated on "playing", comes down.
    /// Re-enabling pulls fresh state.
    private func clearForDisable() {
        snapshots.removeAll()
        activeSource = nil
        lastTrackKey = nil
        lyrics = nil
        lyricsReserved = false
        showFullLyrics = false
        adoptSourceExtras()
        handleUpdate(nil)
    }

    deinit {
        // This app runs for days; a timer that outlives its module compounds.
        liveSyncTimer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for observer in sleepObservers { center.removeObserver(observer) }
    }

    /// Picks which player owns the notch when more than one is running.
    ///
    /// Rules, in order:
    /// 0. **Dedicated adapters outrank the system source, playing or paused.**
    ///    `SystemMediaAdapter` reports whatever owns the system session, which
    ///    includes a browser tab; without this a YouTube Music tab would take
    ///    the notch off a paused Spotify. It may only take over when neither
    ///    Spotify nor Music has anything at all. This deliberately overrides
    ///    rule 1 for that source: audible does not beat dedicated.
    /// 1. Between the two dedicated adapters, a source reporting *playing*
    ///    audio wins. Two players cannot both be audible for long, and the
    ///    audible one is what the user means.
    /// 2. Otherwise the incumbent keeps the notch, so a paused Spotify in the
    ///    background cannot stomp a paused Music the user is actually looking
    ///    at. This is the "never switch silently" rule from Phase 4 task 2.
    /// 3. A source losing content only clears the notch if it *held* it; the
    ///    notch then falls back to any other source that still has something.
    ///
    /// Before this existed the module was last-writer-wins, which was correct
    /// only because exactly one adapter was registered.
    private func shouldTakeOver(_ snapshot: NowPlaying?, from source: any MediaSource) -> Bool {
        // Rule 0, both directions: the system source waits for the dedicated
        // ones to be empty, and yields the moment either has something.
        if source is SystemMediaAdapter { return !dedicatedSourceHasContent }
        if snapshot?.hasContent == true, activeSource is SystemMediaAdapter { return true }

        if snapshot?.isPlaying == true { return true }
        guard let active = activeSource else { return snapshot?.hasContent == true }
        return active === source
    }

    private func handleUpdate(_ snapshot: NowPlaying?, from source: any MediaSource) {
        // A callback already in flight when media was switched off (an
        // artwork download landing, a deferred re-anchor) must not repopulate
        // the notch or start a lyrics lookup.
        guard isEnabled else { return }
        // Recorded before arbitrating, so `dedicatedSourceHasContent` answers
        // for the state including this update rather than the one before it.
        snapshots[source.sourceID] = snapshot?.hasContent == true ? snapshot : nil

        guard shouldTakeOver(snapshot, from: source) else { return }

        if activeSource !== source, snapshot?.hasContent == true {
            Self.logger.notice("Active media source -> \(source.sourceID, privacy: .public)")
        }

        if snapshot?.hasContent == true {
            activeSource = source
        } else if activeSource === source {
            // The owner went quiet. Promote whoever still has something —
            // republished, not just recorded: the other source has no reason
            // to emit again, so without this the notch blanks even though a
            // usable snapshot is sitting right here.
            if let next = fallbackSource(excluding: source) {
                activeSource = next
                Self.logger.notice(
                    "Active media source -> \(next.sourceID, privacy: .public) (owner went quiet)")
                adoptSourceExtras()
                handleUpdate(snapshots[next.sourceID])
                return
            }
            activeSource = nil
        }

        adoptSourceExtras()
        handleUpdate(snapshot)
    }

    /// Resolves Up Next and favourite for whichever source owns the notch.
    ///
    /// Precedence is per source, because the two dictionaries expose
    /// genuinely different things:
    /// - **Music** answers both itself, with no network: a real queue via
    ///   `current playlist`, and a read-write `favorited`.
    /// - **Spotify** answers neither. It has no queue class at all, and
    ///   `starred` is unimplemented, so it reports nil and `.unsupported` and
    ///   the notch shows neither for it.
    ///
    /// Synchronous and free — the adapter refreshed these during its own
    /// Apple Event before calling back.
    private func adoptSourceExtras() {
        guard let active = activeSource else {
            setUpNext(nil)
            likedCurrent = nil
            shuffling = nil
            repeating = nil
            volumeSupported = false
            volume = nil
            return
        }
        shuffling = active.shuffling
        repeating = active.repeating
        volumeSupported = active.supportsVolume
        if !isEditingVolume { mirrorVolume(active.volume, of: active) }
        setUpNext(active.upNext)
        likedCurrent = active.favorite.value
    }

    // MARK: - Playback modes

    /// Whether shuffle and repeat apply to whoever owns the notch.
    ///
    /// Spotify only this task. Music's dictionary has the terms but they are
    /// unread here, and the system source's payload carries neither — so the
    /// controls are **absent** for those, not dimmed. A control that cannot
    /// act must not occupy space pretending it might.
    ///
    /// Reads the mirror, so the panel re-renders when a read changes it.
    var showsPlaybackModes: Bool {
        activeSource is SpotifyAdapter && shuffling != nil
    }

    var isShuffling: Bool { shuffling == true }
    var isRepeating: Bool { repeating == true }

    func toggleShuffle() {
        guard let on = shuffling else { return }
        activeSource?.setShuffling(!on)
        // Optimistic, onto the MIRROR, which is what redraws the glyph under
        // the click. The adapter made the same assumption internally; the
        // next modes read confirms both or corrects both.
        shuffling = !on
    }

    func toggleRepeat() {
        guard let on = repeating else { return }
        activeSource?.setRepeating(!on)
        repeating = !on
    }

    // MARK: - Player volume

    /// Whether the player's own volume control applies to whoever owns the
    /// notch: Spotify and Music, never the system source. Absent rather than
    /// dimmed, like the playback modes. Deliberately not waiting on a read:
    /// the button stays put while the first read is still in flight.
    var showsVolumeControl: Bool { volumeSupported }

    /// Called as the slider opens. Reads now if nothing has been read yet —
    /// a click-driven Apple Event, not one inside an animation. False when
    /// there is still no value to show, so the view keeps the transport.
    func prepareVolumeSlider() -> Bool {
        if volume == nil { readVolume() }
        return volume != nil
    }

    /// The player slider's edit: always the active source.
    func beginVolumeEdit() {
        beginVolumeEdit(on: activeSource)
    }

    private func beginVolumeEdit(on source: (any MediaSource)?) {
        isEditingVolume = true
        volumeEditSource = source
    }

    /// One drag step. The mirror moves immediately; the write to the player
    /// is thinned to one per `volumeSendInterval`, with the latest value
    /// sent when the wait runs out.
    func setVolume(_ value: Int) {
        stepVolume(value, on: volumeEditSource ?? activeSource)
    }

    private func stepVolume(_ value: Int, on source: (any MediaSource)?) {
        let target = PlayerVolume.clamp(value)
        mirrorVolume(target, of: source)
        pendingVolume = target
        let wait = volumeThrottle.wait(at: ProcessInfo.processInfo.systemUptime)
        if wait == 0 {
            flushVolume()
        } else if trailingVolumeSend == nil {
            // One-shot, never a poll: it exists only between two drag steps.
            trailingVolumeSend = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.trailingVolumeSend = nil
                self.flushVolume()
            }
        }
    }

    /// The release: the final value goes out now, unthrottled.
    func endVolumeEdit() {
        trailingVolumeSend?.cancel()
        trailingVolumeSend = nil
        flushVolume()
        let edited = volumeEditSource ?? activeSource
        isEditingVolume = false
        volumeEditSource = nil
        if let edited, let value = edited.volume ?? volume {
            Self.logger.notice("Volume set to \(value, privacy: .public) on \(edited.sourceID, privacy: .public)")
        }
    }

    private func flushVolume() {
        guard let target = pendingVolume, let source = volumeEditSource ?? activeSource,
              source.supportsVolume else {
            pendingVolume = nil
            return
        }
        pendingVolume = nil
        source.setVolume(target)
        volumeThrottle.recordSend(at: ProcessInfo.processInfo.systemUptime)
    }

    /// One Apple Event against the current player, mirrored. Skipped while a
    /// drag owns the value.
    private func readVolume() {
        guard !isEditingVolume, let active = activeSource, active.supportsVolume else { return }
        active.refreshVolume()
        mirrorVolume(active.volume, of: active)
    }

    /// The one place a player's volume lands in the observable state: its
    /// bundle-ID entry, which the mixer row reads, and — for the active
    /// source, or when there is no source to key by — `volume`, which the
    /// player slider reads. A nil leaves the bundle-ID entry at its last
    /// good value; `volume` takes the nil, as it always has.
    private func mirrorVolume(_ value: Int?, of source: (any MediaSource)?) {
        if let value, let id = source?.bundleID { playerVolumes[id] = value }
        if source == nil || source === activeSource { volume = value }
    }

    /// The Up Next slot is removed from the layout entirely when there is
    /// nothing queued, so its arrival or departure changes the expanded
    /// panel's height and the coordinator has to re-measure.
    ///
    /// Only *presence* reflows. Swapping one queued title for another leaves
    /// the slot the same size, and reflowing on every track change would
    /// re-measure the panel for nothing.
    private func setUpNext(_ next: UpNextTrack?) {
        let had = upNext != nil
        upNext = next
        if had != (next != nil) { onContentReflow?() }
    }

    private func handleUpdate(_ snapshot: NowPlaying?) {
        nowPlaying = snapshot
        // The visualiser's tap is whole-system, so it is gated on the player
        // the notch is actually showing: paused, stopped or empty means the
        // tap comes down rather than reacting to unrelated system audio.
        visualizer?.setPlaying(snapshot?.isPlaying == true)
        // This update can change which screen is showing — content arriving
        // or leaving, the full-lyrics takeover ending on a new track — so the
        // spectrum follows at every exit below.
        defer { updateSpectrumVisibility() }

        // Recompute the accent only when the artwork bytes actually change —
        // a 24x24 downsample pass, cheap, but not worth repeating per tick.
        if snapshot?.artworkData != accentSourceData {
            accentSourceData = snapshot?.artworkData
            artworkAccent = snapshot?.artworkData.flatMap(ArtworkColor.dominant(in:))
            artworkImage = snapshot?.artworkData.flatMap(NSImage.init(data:))
            artworkPalette = snapshot?.artworkData.flatMap(ArtworkPaletteExtractor.palette(from:))
        }

        let hasPresence = snapshot?.hasContent == true
        let presenceFlipped = hasPresence != hadPresence
        hadPresence = hasPresence
        // Expanded content can flip without presence flipping — the
        // permission banner appearing under an empty snapshot — and the open
        // panel has to move between chrome-only and the card on that too.
        // Presence already re-renders the panel, so only the remaining case
        // reflows: a play or stop never measures twice.
        let expandedFlipped = hasExpandedContent != hadExpandedContent
        hadExpandedContent = hasExpandedContent
        if presenceFlipped {
            onPresenceChange?()
        } else if expandedFlipped {
            onContentReflow?()
        }

        guard let snapshot, snapshot.hasContent else { return }
        let key = snapshot.artworkIdentifier ?? "\(snapshot.title ?? "")|\(snapshot.artist ?? "")"
        guard key != lastTrackKey else { return }

        lastTrackKey = key
        // Auto-announcing track changes (a 4s live-activity pop) shipped and
        // was experienced as a glitch — the notch "expands for a second and
        // goes back" uninvited. Off until it can be a designed banner; the
        // live-activity plumbing stays for whatever earns it next.

        // New track: leave the full-lyrics takeover and clear the old
        // lyrics — but deliberately WITHOUT reflowing. The area holds its
        // current height via `lyricsReserved` until the lookup resolves, so
        // the panel keeps its size across the change. Reflowing here is what
        // collapsed the notch out from under the cursor on every skip.
        showFullLyrics = false
        lyricsReserved = lyrics != nil
        lyrics = nil
        fetchLyrics(for: snapshot, trackKey: key)
    }

    /// The adapter commands go to: whoever owns the notch, falling back to
    /// any running player before the notch has been claimed.
    private var commandTarget: (any MediaSource)? {
        activeSource ?? sources.first { $0.isPlayerRunning }
    }

    func send(_ command: MediaCommand) {
        commandTarget?.send(command)
    }

    func seek(to seconds: TimeInterval) {
        commandTarget?.seek(to: seconds)
    }

    private func fetchLyrics(for snapshot: NowPlaying, trackKey: String) {
        // Disabled: no LRCLIB request and no Apple Event for lyrics.
        guard isEnabled else { return }
        guard let artist = snapshot.artist, let title = snapshot.title else {
            // Nothing to look up, so the reservation would never be released
            // and the area would hold empty space forever.
            finishLyrics(nil, trackKey: trackKey)
            return
        }
        // Music can answer from its own `lyrics` property; Spotify cannot,
        // and returns nil here, sending the lookup straight to LRCLIB.
        // Passed as a closure: the service asks only after both caches miss,
        // so a cached track never pays Music's synchronous Apple Event.
        let source = activeSource
        lyricsService.fetch(
            artist: artist, title: title, duration: snapshot.duration,
            embeddedLRC: { source?.embeddedLyrics() }
        ) { [weak self] lines in
            guard let self else { return }
            self.finishLyrics(lines, trackKey: trackKey)
        }
    }

    /// Applies a resolved lookup and reflows only if the lyric area's height
    /// actually changed.
    ///
    /// - lyrics -> lyrics: same height, no reflow (the common skip).
    /// - lyrics -> none: shrinks, so reflow. This is the honest "this track
    ///   has no lyrics" case the panel should resize for.
    /// - none -> lyrics: grows, so reflow. Growing is safe: the bottom edge
    ///   moves away from the cursor, never past it.
    private func finishLyrics(_ lines: [LyricsLine]?, trackKey: String) {
        guard lastTrackKey == trackKey else { return } // stale reply
        let occupiedBefore = lyricsOccupiesHeight
        lyrics = lines
        lyricsReserved = false
        if occupiedBefore != lyricsOccupiesHeight {
            onContentReflow?()
        }
    }

    // MARK: - NotchModule

    func makeCompactView() -> AnyView { AnyView(MediaCompactView(module: self)) }
    func makeExpandedView() -> AnyView { AnyView(MediaExpandedView(module: self)) }

    /// The wings: artwork left of the housing, waveform right of it — the
    /// "music is on" indicator visible without hovering.
    func makeCompactLeadingView() -> AnyView? {
        guard nowPlaying?.hasContent == true else { return nil }
        return AnyView(MediaWingArtwork(module: self))
    }

    func makeCompactTrailingView() -> AnyView? {
        guard nowPlaying?.hasContent == true else { return nil }
        // The 3pt nudge is wing-placement tuning (user-measured); it lives
        // here so the same waveform sits naturally in the expanded layout.
        return AnyView(MediaWingWaveform(module: self).offset(x: -3))
    }

    /// The expanded view is on screen. Starts the live-sync clock, and lets
    /// the spectrum capture if the player is the screen showing. No pull
    /// here, because `AppleScriptRunner` is synchronous and an Apple Event
    /// per hover would land inside the expand animation. Push observation
    /// keeps the snapshot current in between.
    ///
    /// The one read it does schedule is the player's volume, which no
    /// notification carries, and it waits out the animation first
    /// (`volumeReadDelay`). One-shot, cancelled if the panel closes sooner.
    func didBecomeVisible() {
        isVisible = true
        liveSyncWanted = true
        updateLiveSync()
        updateSpectrumVisibility()
        volumeReadTask?.cancel()
        volumeReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.volumeReadDelay)
            guard !Task.isCancelled, let self, self.isVisible else { return }
            self.volumeReadTask = nil
            self.readVolume()
        }
    }

    /// One pull from every player.
    ///
    /// Sources observe by push and say nothing until playback changes, so
    /// without this a track already playing at launch would not put the
    /// wings up until the next skip. It is also what raises the one-time
    /// Automation prompt. It ran from `didBecomeVisible()` while visibility
    /// meant standby membership, which in practice fired once, at launch.
    private func pullSources() {
        sources.forEach { $0.refresh() }
    }

    // MARK: - Live sync

    /// Runs the clock iff the panel wants it and the display is awake.
    /// One decision point, so the two conditions cannot drift apart.
    private func updateLiveSync() {
        let shouldRun = liveSyncWanted && !displayAsleep
        guard shouldRun != (liveSyncTimer != nil) else { return }
        if shouldRun {
            let timer = Timer.scheduledTimer(withTimeInterval: Self.liveSyncInterval,
                                             repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.liveSyncTick() }
            }
            // `.common`: the panel is open *because* the mouse is tracking,
            // and a `.default`-mode timer does not fire during tracking.
            RunLoop.main.add(timer, forMode: .common)
            liveSyncTimer = timer
            Self.logger.notice("Live sync started (\(Self.liveSyncInterval, privacy: .public)s)")
        } else {
            liveSyncTimer?.invalidate()
            liveSyncTimer = nil
            Self.logger.notice("Live sync stopped")
        }
    }

    /// One beat. A paused player is skipped before any Apple Event: its
    /// position is not moving and its modes rarely change, so they are read
    /// on the next play instead, and its volume was read when the panel
    /// opened.
    ///
    /// Spotify gets its three-property live read. Spotify and Music both get
    /// a volume read, one more property (~17ms), because neither says when
    /// its volume changes — from its own slider, or from a phone. The system
    /// source has neither, so it costs nothing here.
    private func liveSyncTick() {
        guard nowPlaying?.isPlaying == true else { return }
        if let spotify = activeSource as? SpotifyAdapter {
            spotify.refreshLive()
        }
        readVolume()
    }

    // MARK: - Spectrum

    /// Whether a screen draws the spectrum. Only the player does, and only
    /// with a duration: the spectrum lives in its progress row, which a track
    /// without one does not get (`NowPlaying.hasDuration`, the same test the
    /// row makes). The full-lyrics takeover and the permission banner replace
    /// the player without one. Pure, so the mapping is a test rather than a
    /// reading of `MediaExpandedView`.
    static func drawsSpectrum(on screen: ExpandedScreen?) -> Bool {
        guard case .player(let playing) = screen else { return false }
        return playing.hasDuration
    }

    /// Tells the visualiser whether its spectrum is on screen. Called wherever
    /// either input changes — visibility, and the screen showing — and the
    /// service ignores repeats, so calling it freely costs nothing.
    ///
    /// Deliberately not called from `notchDidCollapse()`: that runs while
    /// this module still counts as visible, so leaving the full-lyrics
    /// takeover there would briefly turn capture back on. The resign that
    /// follows it stops capture instead.
    ///
    /// The display being asleep also stops it: a pinned-open panel behind a
    /// sleeping display drew nothing, but kept the tap and the FFT running.
    private func updateSpectrumVisibility() {
        guard let visualizer else { return }
        visualizer.setSpectrumVisible(Self.spectrumShouldCapture(
            isVisible: isVisible, displayAsleep: displayAsleep, screen: expandedScreen))
    }

    /// The whole capture condition in one pure place, for tests.
    static func spectrumShouldCapture(isVisible: Bool, displayAsleep: Bool,
                                      screen: ExpandedScreen?) -> Bool {
        isVisible && !displayAsleep && drawsSpectrum(on: screen)
    }

    /// The app the artwork opens: the one playing the track on screen. The
    /// owning adapter's own app first (Spotify, Music); for the system
    /// source, which speaks for whichever app owns the session, the bundle
    /// ID the snapshot reports. Nil makes the artwork inert.
    var artworkTapBundleID: String? {
        Self.artworkTapTarget(sourceBundleID: activeSource?.bundleID,
                              snapshotBundleID: nowPlaying?.sourceBundleID)
    }

    /// Pure, for tests.
    static func artworkTapTarget(sourceBundleID: String?, snapshotBundleID: String?) -> String? {
        sourceBundleID ?? snapshotBundleID
    }

    /// Brings the playing app forward, and does nothing else. It used to
    /// open Spotify whatever was playing — Music, a browser tab — and launch
    /// it if quit.
    ///
    /// This activates the *player* — permitted because it is a direct
    /// response to the user tapping the artwork, not a hover (hard rule 4
    /// protects against hover-stealing). Astraea itself is never activated.
    ///
    /// **Deliberately not a navigation.** It previously opened a
    /// `spotify:` URI, which could move the user off what they were looking
    /// at. Bringing the app forward is the one behaviour that is the same
    /// every time.
    ///
    /// Behaves like clicking the app in the Dock, which is stronger than
    /// activation in two ways that both matter here: it **launches** the app
    /// if it is quit, and it sends a reopen event if it is already running,
    /// which restores a window the user had minimised.
    /// `NSRunningApplication.activate()` does neither — against a minimised
    /// player it brings forward an app with nothing on screen.
    func openPlayingApp() {
        guard let bundleID = artworkTapBundleID else {
            Self.logger.notice("Artwork tap: no source app known; nothing to open")
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.logger.error("Artwork tap: \(bundleID, privacy: .public) is not installed; nothing to open")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // Captured rather than reached through `Self`: the handler runs off
        // the main actor.
        let logger = Self.logger
        Self.logger.notice("Artwork tap: opening \(bundleID, privacy: .public)")
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard let error else { return }
            logger.error(
                "Artwork tap: could not open \(bundleID, privacy: .public) - \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Toggles the full-lyrics takeover. Pins the notch open while on.
    func toggleFullLyrics() {
        guard lyrics?.isEmpty == false else { return }
        showFullLyrics.toggle()
        updateSpectrumVisibility()
        onContentReflow?()
    }

    /// The notch collapsed (cursor left). Leave the lyrics takeover so the
    /// next hover shows the player, matching how every other view collapses.
    func notchDidCollapse() {
        showFullLyrics = false
        // A mixer-page drag runs while this module is off screen, so the
        // flush in `didResignVisible` never covers it. The collapse does:
        // a throttled write still waiting is sent, and an edit whose release
        // never arrived is closed, rather than left open freezing the mirror.
        if isEditingVolume || trailingVolumeSend != nil {
            endVolumeEdit()
        }
    }

    /// Only ever called when `canToggleFavorite` is true, so only for a
    /// source that writes its own favourite (Music's `favorited`).
    func toggleLike() {
        guard canToggleFavorite, let active = activeSource else { return }
        active.setFavorite(!(likedCurrent ?? false))
        likedCurrent = active.favorite.value
    }

    func didResignVisible() {
        // Observation is push-based and stays on — that is how the collapsed
        // wings follow track changes. The one timer this module owns, the
        // live-sync clock, stops here (hard rule 9): behind the wings with
        // Spotify playing, it was an Apple Event every two seconds for a
        // playhead nobody could see.
        isVisible = false
        liveSyncWanted = false
        updateLiveSync()
        updateSpectrumVisibility()
        volumeReadTask?.cancel()
        volumeReadTask = nil
        // A drag cannot outlive the panel, but a write still waiting on the
        // throttle can: send it rather than drop the value the user chose.
        if isEditingVolume || trailingVolumeSend != nil {
            endVolumeEdit()
        }
    }
}

// MARK: - Scripted player volumes (the mixer page's Spotify and Music rows)

/// The mixer page's route to Spotify's and Music's own volume. Every call
/// goes through the same mirror, throttle and edit guard as the player
/// slider, retargeted at the row's player — so the two controls cannot
/// disagree, and a player that is not the active source is still reachable.
extension MediaModule: ScriptedPlayerVolumes {

    /// The source that owns a bundle ID's volume. Only sources that support
    /// one: the system source has neither a bundle ID nor a volume.
    private func volumeSource(for bundleID: String) -> (any MediaSource)? {
        sources.first { $0.supportsVolume && $0.bundleID == bundleID }
    }

    func handlesVolume(for bundleID: String) -> Bool {
        isEnabled && volumeSource(for: bundleID) != nil
    }

    func volume(for bundleID: String) -> Int? {
        playerVolumes[bundleID]
    }

    func refreshVolume(for bundleID: String) {
        guard isEnabled, !isEditingVolume, let source = volumeSource(for: bundleID) else { return }
        source.refreshVolume()
        mirrorVolume(source.volume, of: source)
    }

    func beginVolumeEdit(for bundleID: String) {
        guard isEnabled, let source = volumeSource(for: bundleID) else { return }
        beginVolumeEdit(on: source)
    }

    func setVolume(_ value: Int, for bundleID: String) {
        guard isEnabled, let source = volumeSource(for: bundleID) else { return }
        guard isEditingVolume else {
            // A lone step — keyboard, VoiceOver, or a click the slider did
            // not bracket with an edit — is one write, with nothing left open.
            beginVolumeEdit(on: source)
            stepVolume(value, on: source)
            endVolumeEdit()
            return
        }
        // Another player's drag owns the edit; there is only one pointer,
        // so this is a stray step, not a second drag.
        guard volumeEditSource === source else { return }
        stepVolume(value, on: source)
    }

    func endVolumeEdit(for bundleID: String) {
        guard isEditingVolume, let source = volumeSource(for: bundleID),
              volumeEditSource === source else { return }
        endVolumeEdit()
    }
}
