import XCTest
@testable import PopNotch

/// A controllable MediaSource for exercising MediaModule logic without
/// AppleScript, players, or the network.
@MainActor
final class StubMediaSource: MediaSource {
    let sourceID: String
    var isPlayerRunning: Bool
    var permissionDenied: Bool
    var onUpdate: ((NowPlaying?) -> Void)?

    init(id: String, running: Bool = false, denied: Bool = false) {
        sourceID = id
        isPlayerRunning = running
        permissionDenied = denied
    }

    /// Commands the module routed here, for asserting command routing.
    private(set) var sent: [MediaCommand] = []

    /// Playback modes, settable so mirror tests can drive them. The recorded
    /// set-calls assert routing without any AppleScript.
    var shuffling: Bool?
    var repeating: Bool?
    private(set) var shuffleSetTo: Bool?
    private(set) var repeatSetTo: Bool?
    func setShuffling(_ on: Bool) { shuffleSetTo = on }
    func setRepeating(_ on: Bool) { repeatSetTo = on }

    /// Player volume. Off by default, like the system source; a test opts
    /// in. `nextRead` is what a `refreshVolume()` finds, nil for a failed
    /// read; every write is recorded, in order, with no AppleScript.
    var supportsVolume = false
    var volume: Int?
    /// Nil like the system source unless a test names the player, which is
    /// how the mixer page's row finds it.
    var bundleID: String?
    var nextRead: Int?
    private(set) var volumeReads = 0
    private(set) var volumeWrites: [Int] = []
    func refreshVolume() {
        volumeReads += 1
        if let nextRead { volume = nextRead }
    }
    func setVolume(_ value: Int) {
        volumeWrites.append(value)
        volume = value
    }

    func startObserving() {}
    func stopObserving() {}
    func refresh() {}
    func send(_ command: MediaCommand) { sent.append(command) }
    func seek(to seconds: TimeInterval) {}

    /// Drives the module's real update path, exactly as an adapter would.
    func publish(_ snapshot: NowPlaying?) { onUpdate?(snapshot) }
}

/// The in-notch permission banner shows only when a RUNNING player is
/// denied — that is the only case where denial explains an empty widget.
@MainActor
final class MediaModulePermissionTests: XCTestCase {

    func testDeniedRunningPlayerSurfacesBanner() {
        // The regression: Spotify denied while Music's flag is still false.
        // allSatisfy hid the banner; the rule is "any running player denied".
        let spotify = StubMediaSource(id: "spotify", running: true, denied: true)
        let music = StubMediaSource(id: "music", running: false, denied: false)
        let module = MediaModule(sources: [spotify, music])
        XCTAssertTrue(module.permissionDenied)
    }

    func testDeniedButClosedPlayerDoesNotSurfaceBanner() {
        // Granting a closed player would display nothing; the widget is
        // empty because nothing is playing. The Permissions tab owns this.
        let spotify = StubMediaSource(id: "spotify", running: false, denied: true)
        let module = MediaModule(sources: [spotify])
        XCTAssertFalse(module.permissionDenied)
    }

    func testRunningGrantedPlayerDoesNotSurfaceBanner() {
        let spotify = StubMediaSource(id: "spotify", running: true, denied: false)
        let module = MediaModule(sources: [spotify])
        XCTAssertFalse(module.permissionDenied)
    }

    func testNeverProbedSecondPlayerDoesNotMaskADenial() {
        // Music running but never probed (flag false) must not hide
        // Spotify's real denial.
        let spotify = StubMediaSource(id: "spotify", running: true, denied: true)
        let music = StubMediaSource(id: "music", running: true, denied: false)
        let module = MediaModule(sources: [spotify, music])
        XCTAssertTrue(module.permissionDenied)
    }

    func testNoSourcesMeansNoBanner() {
        XCTAssertFalse(MediaModule(sources: []).permissionDenied)
    }
}

/// The lyric area holds its height across a track change so the panel does
/// not shrink, pull its bottom edge past the cursor on the transport
/// buttons, and collapse. Reflow follows the area's HEIGHT, never its
/// content.
@MainActor
final class LyricsReflowTests: XCTestCase {

    private func track(_ title: String) -> NowPlaying {
        var s = NowPlaying()
        s.title = title
        s.artist = "Artist"
        s.isPlaying = true
        s.artworkIdentifier = "spotify:track:\(title)"
        return s
    }

    func testFreshModuleReservesNothing() {
        let module = MediaModule(sources: [])
        XCTAssertFalse(module.lyricsReserved)
        XCTAssertFalse(module.lyricsOccupiesHeight, "no lyrics and no lookup means no height")
    }

    func testTrackChangeDoesNotReflowOnTheTransientNil() {
        // The regression. Clearing lyrics for the incoming track used to
        // reflow immediately, dropping the panel ~59pt while the replacement
        // lyrics were still resolving.
        var reflows = 0
        let source = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [source])
        module.onContentReflow = { reflows += 1 }

        source.publish(track("A"))
        source.publish(track("B"))
        source.publish(track("C"))

        XCTAssertEqual(reflows, 0,
                       "clearing lyrics for a new track must never resize the panel")
    }

    func testStalePlaceholderIsReleasedWhenThereIsNothingToLookUp() {
        // A track with no artist or title never reaches the lyrics service,
        // so nothing would ever release the reservation and the area would
        // hold empty space indefinitely.
        var bare = NowPlaying()
        bare.artworkData = Data([0xFF])   // hasContent without title or artist
        bare.isPlaying = true
        bare.artworkIdentifier = "spotify:track:bare"

        let source = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [source])
        source.publish(bare)

        XCTAssertFalse(module.lyricsReserved, "the reservation must not be left held")
        XCTAssertFalse(module.lyricsOccupiesHeight)
    }
}
