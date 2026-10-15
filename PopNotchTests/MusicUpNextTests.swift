import XCTest
@testable import PopNotch

/// Up Next for Music, from the query script through the adapter to the value
/// the expanded view reads (`MediaModule.upNext`).
///
/// No test here talks to Music.app. The adapter's script runner and its
/// "is Music open" check are both injected: the fake runner answers the
/// main query with canned output and refuses everything else, so nothing —
/// not even the artwork fetch — can reach, or launch, the real player.
///
/// The index arithmetic itself runs inside Music, in AppleScript, so it is
/// covered twice over: the script's shape is pinned here, and the parse of
/// every outcome it can return is pinned in `MusicParsingTests`.
@MainActor
final class MusicUpNextTests: XCTestCase {

    // MARK: - Fixtures

    /// Scripted replies to the main query, consumed in order. Anything that
    /// is not the main query fails, as a stopped artwork fetch would.
    private var replies: [Result<NSAppleEventDescriptor, AppleScriptRunner.Failure>] = []
    private var scriptsRun: [String] = []

    private func makeAdapter() -> MusicAdapter {
        MusicAdapter(
            runScript: { [unowned self] source in
                self.scriptsRun.append(source)
                guard source == MusicAdapter.queryScript, !self.replies.isEmpty else {
                    return .failure(AppleScriptRunner.Failure(code: -1728))
                }
                return self.replies.removeFirst()
            },
            playerRunning: { true }
        )
    }

    /// Field order matches `MusicAdapter.queryScript`.
    private func output(nextTitle: String = "", nextArtist: String = "", reason: String = "") -> String {
        ["playing", "3005", "Childish Gambino", "because the internet",
         "212.45", "12.607", "A1B2C3D4E5F6", "false",
         nextTitle, nextArtist, reason].joined(separator: "\n")
    }

    private func reply(_ text: String) -> Result<NSAppleEventDescriptor, AppleScriptRunner.Failure> {
        .success(NSAppleEventDescriptor(string: text))
    }

    private let sweatpants = UpNextTrack(title: "Sweatpants", artist: "Childish Gambino")

    // MARK: - Derivation

    func testQueryDerivesNextTrackFromCurrentPlaylistIndexPlusOne() {
        let script = MusicAdapter.queryScript
        XCTAssertTrue(script.contains("set pl to current playlist"))
        XCTAssertTrue(script.contains("set idx to index of t"))
        XCTAssertTrue(script.contains("set nt to track (idx + 1) of pl"))
        XCTAssertTrue(script.contains("name of nt"))
        XCTAssertTrue(script.contains("artist of nt"))
    }

    func testNextTrackReachesTheModule() {
        replies = [reply(output(nextTitle: "Sweatpants", nextArtist: "Childish Gambino"))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()

        XCTAssertEqual(music.upNext, sweatpants)
        XCTAssertEqual(module.upNext, sweatpants, "the view reads the module's mirror")
        XCTAssertEqual(module.nowPlaying?.title, "3005")
    }

    // MARK: - Shuffle

    func testShuffleIsCheckedBeforeThePlaylistIsRead() throws {
        // The guard has to run first: under shuffle, `index + 1` is a track,
        // just not the next one, so reading it at all invites showing it.
        let script = MusicAdapter.queryScript
        let shuffle = try XCTUnwrap(script.range(of: "if shuffle enabled then"))
        let lookup = try XCTUnwrap(script.range(of: "current playlist"))
        XCTAssertLessThan(shuffle.lowerBound, lookup.lowerBound)
    }

    func testShuffleHidesUpNext() {
        replies = [reply(output(reason: "shuffle"))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()

        XCTAssertNil(module.upNext)
        XCTAssertNotNil(module.nowPlaying, "the track itself still shows")
    }

    func testTurningShuffleOnHidesAShowingUpNext() {
        replies = [reply(output(nextTitle: "Sweatpants", nextArtist: "Childish Gambino")),
                   reply(output(reason: "shuffle"))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()
        XCTAssertEqual(module.upNext, sweatpants)
        music.refresh()
        XCTAssertNil(module.upNext)
    }

    // MARK: - End of playlist, no playlist

    func testLastTrackInPlaylistHidesUpNext() {
        XCTAssertTrue(MusicAdapter.queryScript.contains("if idx < (count of tracks of pl) then"),
                      "the bound check is what keeps idx + 1 inside the playlist")
        replies = [reply(output(reason: "last-in-playlist"))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()

        XCTAssertNil(module.upNext)
    }

    func testNoCurrentPlaylistHidesUpNext() {
        // A bare file or a stream has no current playlist; Music errors on
        // the read and the script's `try` turns that into a reason.
        XCTAssertTrue(MusicAdapter.queryScript.contains("set skipReason to \"no-playlist\""))
        replies = [reply(output(reason: "no-playlist"))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()

        XCTAssertNil(module.upNext)
    }

    // MARK: - Query failure

    func testFailedQueryHidesAShowingUpNextAndKeepsTheTrack() {
        replies = [reply(output(nextTitle: "Sweatpants", nextArtist: "Childish Gambino")),
                   .failure(AppleScriptRunner.Failure(code: -1712))]  // errAETimeout
        let music = makeAdapter()
        let module = MediaModule(sources: [music])
        var reflows = 0
        module.onContentReflow = { reflows += 1 }

        music.refresh()
        XCTAssertEqual(module.upNext, sweatpants)
        let reflowsWhileShowing = reflows

        music.refresh()

        XCTAssertNil(music.upNext)
        XCTAssertNil(module.upNext, "a stale next track may no longer be next")
        XCTAssertEqual(module.nowPlaying?.title, "3005", "one failed read does not blank the player")
        XCTAssertEqual(reflows, reflowsWhileShowing + 1, "the row leaving re-measures the panel")
    }

    func testFailedFirstQueryShowsNoUpNext() {
        replies = [.failure(AppleScriptRunner.Failure(code: -1712))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()

        XCTAssertNil(music.upNext)
        XCTAssertNil(module.upNext)
    }

    func testDeniedQueryHidesUpNext() {
        replies = [reply(output(nextTitle: "Sweatpants", nextArtist: "Childish Gambino")),
                   .failure(AppleScriptRunner.Failure(code: AppleScriptRunner.permissionDeniedCode))]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()
        music.refresh()

        XCTAssertTrue(music.permissionDenied)
        XCTAssertNil(module.upNext)
    }

    func testUnparseableOutputHidesUpNext() {
        replies = [reply(output(nextTitle: "Sweatpants", nextArtist: "Childish Gambino")),
                   reply("playing\n3005")]
        let music = makeAdapter()
        let module = MediaModule(sources: [music])

        music.refresh()
        music.refresh()

        XCTAssertNil(module.upNext)
    }

    // MARK: - Cost

    func testUpNextAddsNoAppleEventToAPull() {
        // The lookup rides inside the main query rather than being a second
        // script: a pull is still the query plus the artwork fetch (refused
        // here, and cached per track in production), nothing else.
        replies = [reply(output(nextTitle: "Sweatpants", nextArtist: "Childish Gambino"))]
        let music = makeAdapter()
        music.refresh()
        XCTAssertEqual(scriptsRun.first, MusicAdapter.queryScript)
        XCTAssertEqual(scriptsRun.count, 2, "main query plus the refused artwork fetch, nothing else")
    }
}
