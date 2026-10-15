import XCTest
@testable import PopNotch

/// Shuffle and repeat, read in a script of their own.
///
/// The isolation is the point. `starred` proved that one unimplemented
/// property aborts a whole `return` expression and takes every other field
/// with it — artwork included — so these two share an expression only with
/// each other. The worst case is losing two controls, never the track.
@MainActor
final class PlaybackModesTests: XCTestCase {

    // MARK: - Parsing

    func testParsesBothBooleans() {
        let modes = SpotifyAdapter.parseModes("false\ntrue")
        XCTAssertEqual(modes?.shuffling, false)
        XCTAssertEqual(modes?.repeating, true)
    }

    func testParsesTheLiveProbeOutput() {
        // Exactly what the live app returned on 2026-09-03.
        XCTAssertEqual(SpotifyAdapter.parseModes("false\ntrue")?.repeating, true)
    }

    func testToleratesSurroundingWhitespace() {
        XCTAssertEqual(SpotifyAdapter.parseModes(" true \n false ")?.shuffling, true)
    }

    /// Anything unrecognisable is nil, never a guessed default — the caller
    /// keeps the last state it actually read rather than inventing "off".
    func testGarbageDoesNotBecomeFalse() {
        for bad in ["", "true", "yes\nno", "1\n0", "true\n", "missing value\ntrue"] {
            XCTAssertNil(SpotifyAdapter.parseModes(bad), "\(bad) must not parse")
        }
    }

    // MARK: - Source defaults

    /// Music and the system source answer nil, so the controls are absent
    /// rather than showing a state nobody read.
    func testNonSpotifySourcesReportNoModes() {
        let music = MusicAdapter()
        let system = SystemMediaAdapter()
        XCTAssertNil(music.shuffling)
        XCTAssertNil(music.repeating)
        XCTAssertNil(system.shuffling)
        XCTAssertNil(system.repeating)
    }

    /// And their writers are no-ops that cannot throw or crash.
    func testNonSpotifyWritersAreSafeNoOps() {
        let music = MusicAdapter()
        music.setShuffling(true)
        music.setRepeating(true)
        XCTAssertNil(music.shuffling, "a no-op must not invent state")
        XCTAssertNil(music.repeating)
    }

    /// Spotify starts unknown too: nothing is claimed before a read lands.
    func testSpotifyStartsWithUnknownModes() {
        let spotify = SpotifyAdapter()
        XCTAssertNil(spotify.shuffling)
        XCTAssertNil(spotify.repeating)
    }

    // MARK: - Module gating

    private func moduleShowing(_ id: String) -> (StubMediaSource, MediaModule) {
        let source = StubMediaSource(id: id, running: true)
        let module = MediaModule(sources: [source])
        var snap = NowPlaying()
        snap.title = "3005"
        snap.artist = "Childish Gambino"
        snap.isPlaying = true
        source.publish(snap)
        return (source, module)
    }

    /// A stub is not a SpotifyAdapter, so the controls stay hidden — which
    /// is also the Music and system case.
    func testControlsHiddenForNonSpotifySources() {
        for id in ["music", "system", "spotify"] {
            let (source, module) = moduleShowing(id)
            withExtendedLifetime(module) {
                XCTAssertFalse(module.showsPlaybackModes,
                               "\(id): a source that cannot answer shows nothing")
            }
            _ = source
        }
    }

    func testNoActiveSourceShowsNothing() {
        let module = MediaModule(sources: [])
        XCTAssertFalse(module.showsPlaybackModes)
        XCTAssertFalse(module.isShuffling)
        XCTAssertFalse(module.isRepeating)
    }

    /// Toggling with no source that answers must be inert, not a crash.
    func testTogglingWithoutASourceIsInert() {
        let module = MediaModule(sources: [])
        module.toggleShuffle()
        module.toggleRepeat()
        XCTAssertFalse(module.isShuffling)
        XCTAssertFalse(module.isRepeating)
    }

    // MARK: - The observable mirror

    /// The adapters are not `@Observable`; the module's mirror is. A publish
    /// must move the source's modes onto it, or the view renders a stale
    /// snapshot from its last unrelated re-evaluation — which is exactly the
    /// bug this pattern replaced.
    func testPublishMirrorsModesOntoTheModule() {
        let (source, module) = moduleShowing("spotify")
        withExtendedLifetime(module) {
            source.shuffling = true
            source.repeating = false
            var snap = NowPlaying()
            snap.title = "Sweatpants"
            snap.artist = "Childish Gambino"
            source.publish(snap)
            XCTAssertEqual(module.shuffling, true)
            XCTAssertEqual(module.repeating, false)
            XCTAssertTrue(module.isShuffling)
            XCTAssertFalse(module.isRepeating)
        }
    }

    func testSourceWithoutModesMirrorsNil() {
        let (source, module) = moduleShowing("music")
        withExtendedLifetime(module) {
            XCTAssertNil(module.shuffling)
            XCTAssertNil(module.repeating)
        }
        _ = source
    }

    func testSourceGoingQuietClearsTheMirror() {
        let (source, module) = moduleShowing("spotify")
        withExtendedLifetime(module) {
            source.shuffling = true
            var snap = NowPlaying()
            snap.title = "3005"
            source.publish(snap)
            XCTAssertEqual(module.shuffling, true)
            source.publish(nil)
            XCTAssertNil(module.shuffling, "no owner means no state to show")
        }
    }

    /// The press must redraw immediately: the mirror flips before any read
    /// confirms it, and the set-call reaches the source that owns the notch.
    func testToggleIsOptimisticOnTheMirrorAndRoutedToTheSource() {
        let (source, module) = moduleShowing("spotify")
        withExtendedLifetime(module) {
            source.shuffling = false
            source.repeating = true
            var snap = NowPlaying()
            snap.title = "3005"
            source.publish(snap)

            module.toggleShuffle()
            XCTAssertTrue(module.isShuffling, "mirror flips under the click, before any read")
            XCTAssertEqual(source.shuffleSetTo, true, "and the source was told")

            module.toggleRepeat()
            XCTAssertFalse(module.isRepeating)
            XCTAssertEqual(source.repeatSetTo, false)
        }
    }

    /// With no state ever read, a toggle has nothing to invert and must do
    /// nothing rather than guess.
    func testToggleWithoutAReadStateIsInert() {
        let (source, module) = moduleShowing("spotify")
        withExtendedLifetime(module) {
            module.toggleShuffle()
            XCTAssertNil(module.shuffling)
            XCTAssertNil(source.shuffleSetTo, "nothing was sent on a guess")
        }
    }

    /// Unknown reads as off for display, but `showsPlaybackModes` is what
    /// decides whether anything is drawn — so "off" is never shown for a
    /// state that was never read.
    func testUnknownIsNotRenderedAsOff() {
        let (source, module) = moduleShowing("spotify")
        withExtendedLifetime(module) {
            XCTAssertNil(source.shuffling)
            XCTAssertFalse(module.showsPlaybackModes,
                           "nil state must hide the control, not draw it off")
        }
    }
}
