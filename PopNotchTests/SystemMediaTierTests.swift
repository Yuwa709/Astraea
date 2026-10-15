import XCTest
@testable import PopNotch

/// Music-versus-video inside the system now-playing source.
///
/// macOS surfaces one session at a time, so the adapter can never compare two
/// candidates — it can only decide whether to accept the one it was handed.
/// `album` is the whole tier signal: a YouTube Music track carries one, a
/// YouTube video does not, and every other field (bundle id and pid included)
/// is identical between them.
///
/// The hold that suppression depends on is deliberately fragile. It survives
/// only for the same app, the same item, still playing — see
/// `releasesHold(_:against:)`. A different item is a different session, and a
/// paused track is not something to outrank a video with.
///
/// Driven through `ingest`, the same entry point the stream's read handler
/// uses, so these exercise the real merge and publish path.
@MainActor
final class SystemMediaTierTests: XCTestCase {

    private let browser = "org.mozilla.firefox"

    private func line(title: String, artist: String, album: String,
                      bundle: String, id: String, playing: Bool = true) -> SystemMediaEnvelope {
        let json = """
        {"type":"data","diff":false,"payload":{
          "title":"\(title)","artist":"\(artist)","album":"\(album)",
          "bundleIdentifier":"\(bundle)","contentItemIdentifier":"\(id)",
          "playing":\(playing),"elapsedTime":1.0,"duration":100.0}}
        """
        guard let envelope = SystemMediaParsing.decode(line: Data(json.utf8)) else {
            fatalError("test fixture did not decode")
        }
        return envelope
    }

    private func empty() -> SystemMediaEnvelope {
        guard let envelope = SystemMediaParsing.decode(
            line: Data(#"{"type":"data","diff":false,"payload":{}}"#.utf8))
        else { fatalError("test fixture did not decode") }
        return envelope
    }

    private func adapter() -> (SystemMediaAdapter, () -> [NowPlaying?]) {
        let a = SystemMediaAdapter()
        var seen: [NowPlaying?] = []
        a.onUpdate = { seen.append($0) }
        return (a, { seen })
    }

    /// A YouTube Music track.
    private func music(playing: Bool = true) -> SystemMediaEnvelope {
        line(title: "Sober", artist: "Childish Gambino", album: "Camp",
             bundle: browser, id: "track-1", playing: playing)
    }

    /// The *same* track reported without an album — the transient
    /// misclassification the hold still exists to absorb.
    private func sameTrackWithoutAlbum() -> SystemMediaEnvelope {
        line(title: "Sober", artist: "Childish Gambino", album: "",
             bundle: browser, id: "track-1")
    }

    /// A genuinely different item from the same app.
    private func video() -> SystemMediaEnvelope {
        line(title: "Why NVDA Went Up", artist: "Ticker Symbol: YOU", album: "",
             bundle: browser, id: "video-1")
    }

    // MARK: - Classification

    func testAlbumIsWhatSeparatesMusicFromVideo() {
        var withAlbum = SystemMediaPayload()
        withAlbum.album = "Camp"
        var withoutAlbum = SystemMediaPayload()
        withoutAlbum.album = ""
        XCTAssertEqual(SystemMediaParsing.tier(of: withAlbum), .music)
        XCTAssertEqual(SystemMediaParsing.tier(of: withoutAlbum), .video)
        XCTAssertEqual(SystemMediaParsing.tier(of: SystemMediaPayload()), .video)
    }

    // MARK: - The two new release conditions

    /// A different `contentItemIdentifier` from the same app means macOS is
    /// reporting a different session. Holding the old track there is what
    /// pinned a paused song to the notch on hardware while its scrub bar kept
    /// advancing and the transport buttons drove the video.
    func testDifferentContentItemFromSameAppReleasesTheHold() {
        let (a, seen) = adapter()
        a.ingest([music()])
        a.ingest([video()])
        XCTAssertEqual(seen().last??.title, "Why NVDA Went Up",
                       "a different item is a different session and must publish")
        XCTAssertEqual(seen().last??.artist, "Ticker Symbol: YOU")
    }

    /// Suppression is for an active track outranking a video. A paused one
    /// must stand aside — otherwise the notch runs a scrub bar and scrolls
    /// lyrics against audio that has stopped.
    func testPausedRetainedMusicReleasesTheHold() {
        let (a, seen) = adapter()
        a.ingest([music(playing: false)])
        XCTAssertEqual(seen().last??.title, "Sober", "the paused track still displays")

        a.ingest([sameTrackWithoutAlbum()])
        XCTAssertEqual(seen().last??.album, nil,
                       "a paused track must not suppress anything, even for the same item")
    }

    /// The same check, through the pure decision function, so each condition
    /// is pinned individually rather than only in combination.
    func testReleaseConditionsIndividually() {
        var held = NowPlaying()
        held.title = "Sober"
        held.album = "Camp"
        held.artworkIdentifier = "track-1"
        held.sourceBundleID = browser
        held.isPlaying = true

        var same = held
        XCTAssertFalse(SystemMediaAdapter.releasesHold((browser, held), against: same),
                       "same app, same item, playing: the hold stands")

        same.sourceBundleID = "com.apple.Safari"
        XCTAssertTrue(SystemMediaAdapter.releasesHold((browser, held), against: same),
                      "different app releases")

        var otherItem = held
        otherItem.artworkIdentifier = "video-1"
        XCTAssertTrue(SystemMediaAdapter.releasesHold((browser, held), against: otherItem),
                      "different item releases")

        var pausedHold = held
        pausedHold.isPlaying = false
        XCTAssertTrue(SystemMediaAdapter.releasesHold((browser, pausedHold), against: held),
                      "a paused retained track releases")
    }

    // MARK: - What suppression still covers

    /// The narrow case that survives: the same track, still playing, reported
    /// without its album. Without this the notch would swap to a video-tier
    /// rendering of the song already on screen.
    func testSameTrackReportedWithoutAlbumIsSuppressed() {
        let (a, seen) = adapter()
        a.ingest([music()])
        let afterMusic = seen().count
        a.ingest([sameTrackWithoutAlbum()])

        XCTAssertEqual(seen().count, afterMusic,
                       "nothing is emitted, not even a no-op update")
        XCTAssertEqual(seen().last??.album, "Camp", "the album-carrying snapshot stands")
    }

    /// With the preference off, arrival order wins even for that case.
    func testPreferenceOffLetsTheAlbumlessReportThrough() {
        let (a, seen) = adapter()
        a.prefersMusicOverVideo = false
        a.ingest([music()])
        a.ingest([sameTrackWithoutAlbum()])
        XCTAssertEqual(seen().last??.album, nil, "off means report the session as given")
    }

    // MARK: - The original release conditions, still in force

    func testVideoAloneIsStillPublished() {
        let (a, seen) = adapter()
        a.ingest([video()])
        XCTAssertEqual(seen().last??.artist, "Ticker Symbol: YOU")
    }

    func testDifferentAppIsNotSuppressed() {
        let (a, seen) = adapter()
        a.ingest([music()])
        a.ingest([line(title: "Other", artist: "Elsewhere", album: "",
                       bundle: "com.apple.Safari", id: "track-1")])
        XCTAssertEqual(seen().last??.title, "Other", "the hold is per app, not global")
    }

    func testEmptyPayloadReleasesTheRetainedMusic() {
        let (a, seen) = adapter()
        a.ingest([music()])
        a.ingest([empty()])
        a.ingest([sameTrackWithoutAlbum()])
        XCTAssertEqual(seen().last??.album, nil,
                       "a stopped track must not keep suppressing")
    }

    func testMusicStillReplacesMusic() {
        let (a, seen) = adapter()
        a.ingest([music()])
        a.ingest([line(title: "Bonfire", artist: "Childish Gambino", album: "Camp",
                       bundle: browser, id: "track-2")])
        XCTAssertEqual(seen().last??.title, "Bonfire")
    }

    // MARK: - Registration gate

    /// The source is registered now that the adapter ships in the bundle.
    /// This pins the flag in both directions: unregistering is a deliberate
    /// act with a test to update, not something that drifts.
    func testSourceIsRegisteredNowTheHelperIsVendored() {
        XCTAssertTrue(SystemMediaAdapter.isRegistered,
                      "the adapter is vendored; the source and its setting ship together")
    }

    // MARK: - Argument vector

    private func tool(testClient: String?) -> SystemMediaAdapter.AdapterTool {
        SystemMediaAdapter.AdapterTool(
            perlPath: "/usr/bin/perl",
            scriptPath: "/A/Contents/Resources/mediaremote-adapter.pl",
            frameworkPath: "/A/Contents/Frameworks/MediaRemoteAdapter.framework",
            testClientPath: testClient
        )
    }

    /// Order is fixed by the adapter script: script, framework, optional test
    /// client, then the verb.
    func testArgumentVectorOrdersScriptThenFrameworkThenVerb() {
        let arguments = SystemMediaAdapter.arguments(
            verb: ["stream"], tool: tool(testClient: "/A/Contents/MacOS/MediaRemoteAdapterTestClient")
        )
        XCTAssertEqual(arguments, [
            "/A/Contents/Resources/mediaremote-adapter.pl",
            "/A/Contents/Frameworks/MediaRemoteAdapter.framework",
            "/A/Contents/MacOS/MediaRemoteAdapterTestClient",
            "stream"
        ])
    }

    /// The script decides whether argument two is a helper path by testing it
    /// for a "/". An absent test client must therefore be omitted outright —
    /// an empty string in that slot would be read as the verb.
    func testArgumentVectorOmitsAnAbsentTestClientEntirely() {
        let arguments = SystemMediaAdapter.arguments(verb: ["stream"], tool: tool(testClient: nil))
        XCTAssertEqual(arguments, [
            "/A/Contents/Resources/mediaremote-adapter.pl",
            "/A/Contents/Frameworks/MediaRemoteAdapter.framework",
            "stream"
        ])
        XCTAssertFalse(arguments.contains(""), "an empty slot would be parsed as the verb")
    }

    /// Verbs with parameters keep their operands adjacent and last.
    func testArgumentVectorKeepsVerbOperandsLast() {
        let arguments = SystemMediaAdapter.arguments(
            verb: ["seek", "22.40"], tool: tool(testClient: nil)
        )
        XCTAssertEqual(arguments.suffix(2), ["seek", "22.40"])
    }

    // MARK: - Transport commands (1.0.4 regression)

    /// The whole 1.0.4 bug in one assertion.
    ///
    /// `send(_:)` used to map to `bin/media-control`'s verb names — "play",
    /// "next-track" — which `mediaremote-adapter.pl` rejects outright with
    /// `Invalid function name`. The script takes `send` plus a numeric
    /// MRCommand id, and `MediaCommand`'s raw value is that id.
    func testEveryCommandMapsToSendPlusItsMRCommandID() {
        let expected: [(MediaCommand, [String])] = [
            (.play,            ["send", "0"]),
            (.pause,           ["send", "1"]),
            (.togglePlayPause, ["send", "2"]),
            (.nextTrack,       ["send", "4"]),
            (.previousTrack,   ["send", "5"])
        ]
        for (command, verb) in expected {
            XCTAssertEqual(SystemMediaAdapter.commandVerb(for: command), verb)
        }
    }

    /// The function name must be one the script actually accepts. A verb name
    /// in this slot is the regression, so it is asserted directly rather than
    /// left implied by the id check above.
    func testCommandVerbNeverUsesACLIVerbName() {
        let rejected: Set<String> = [
            "play", "pause", "toggle-play-pause", "next-track", "previous-track"
        ]
        for command in [MediaCommand.play, .pause, .togglePlayPause, .nextTrack, .previousTrack] {
            let verb = SystemMediaAdapter.commandVerb(for: command)
            XCTAssertEqual(verb.first, "send", "the script's function name is 'send', not a verb")
            XCTAssertFalse(rejected.contains(verb.first ?? ""),
                           "'\(verb.first ?? "")' is CLI vocabulary the script rejects")
        }
    }

    /// The full vector a command actually spawns with.
    func testCommandArgumentVectorIsScriptFrameworkClientThenSendID() {
        let arguments = SystemMediaAdapter.arguments(
            verb: SystemMediaAdapter.commandVerb(for: .nextTrack),
            tool: tool(testClient: "/A/Contents/MacOS/MediaRemoteAdapterTestClient")
        )
        XCTAssertEqual(arguments, [
            "/A/Contents/Resources/mediaremote-adapter.pl",
            "/A/Contents/Frameworks/MediaRemoteAdapter.framework",
            "/A/Contents/MacOS/MediaRemoteAdapterTestClient",
            "send",
            "4"
        ])
    }

    /// With no resolvable adapter — which is every test run, by the XCTest
    /// guard — sending reports failure rather than crashing or spawning.
    @MainActor
    func testSendCommandReportsFailureWithNoAdapterAvailable() {
        let adapter = SystemMediaAdapter()
        XCTAssertFalse(adapter.sendCommand(.togglePlayPause),
                       "no adapter resolves under XCTest, so this must return false")
        XCTAssertFalse(adapter.sendCommand(.nextTrack), "and must not start looping or crash")
    }

    /// The stored preference and its schema field must survive the setting
    /// being hidden — hiding a control must never discard the user's choice.
    func testHidingTheSettingDoesNotDiscardTheStoredPreference() {
        let suite = "com.techie.PopNotch.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.update { $0.preferMusicOverVideo = false }

        // A fresh load, as if the app relaunched with the section hidden.
        XCTAssertEqual(SettingsStore(defaults: defaults).settings.preferMusicOverVideo, false,
                       "the choice must come back when the source ships")
        XCTAssertEqual(AppSettings().preferMusicOverVideo, true, "default is unchanged")
    }
}
