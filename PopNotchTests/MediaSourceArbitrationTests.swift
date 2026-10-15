import XCTest
@testable import PopNotch

/// The Phase 4 task 2 rules, exercised through the module's public surface:
/// stubs fire the same onUpdate closure real adapters do.
@MainActor
final class MediaSourceArbitrationTests: XCTestCase {

    private func snapshot(_ title: String, playing: Bool, source: String) -> NowPlaying {
        var s = NowPlaying()
        s.title = title
        s.artist = "Artist"
        s.isPlaying = playing
        s.sourceBundleID = source
        return s
    }

    func testPlayingSourceWins() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let music = StubMediaSource(id: "music", running: true)
        let module = MediaModule(sources: [spotify, music])

        spotify.publish(snapshot("Paused Spotify", playing: false, source: "com.spotify.client"))
        music.publish(snapshot("Playing Music", playing: true, source: "com.apple.Music"))

        XCTAssertEqual(module.nowPlaying?.title, "Playing Music",
                       "audible audio always takes the notch")
    }

    func testPausedNewcomerCannotStompTheIncumbent() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let music = StubMediaSource(id: "music", running: true)
        let module = MediaModule(sources: [spotify, music])

        spotify.publish(snapshot("Incumbent", playing: true, source: "com.spotify.client"))
        spotify.publish(snapshot("Incumbent", playing: false, source: "com.spotify.client"))
        music.publish(snapshot("Background", playing: false, source: "com.apple.Music"))

        XCTAssertEqual(module.nowPlaying?.title, "Incumbent",
                       "never switch silently: a paused background player must not steal the notch")
    }

    func testIncumbentKeepsPublishingItsOwnUpdates() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [spotify])

        spotify.publish(snapshot("Track A", playing: true, source: "com.spotify.client"))
        spotify.publish(snapshot("Track B", playing: false, source: "com.spotify.client"))

        XCTAssertEqual(module.nowPlaying?.title, "Track B",
                       "the owner's own pause update must land")
    }

    func testCommandsRouteToTheOwner() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let music = StubMediaSource(id: "music", running: true)
        let module = MediaModule(sources: [spotify, music])

        music.publish(snapshot("Owner", playing: true, source: "com.apple.Music"))
        module.send(.togglePlayPause)

        XCTAssertEqual(music.sent, [.togglePlayPause])
        XCTAssertTrue(spotify.sent.isEmpty,
                      "the command must not go to 'the first running player'")
    }

    func testCommandsFallBackToARunningPlayerBeforeAnyOwnerExists() {
        let spotify = StubMediaSource(id: "spotify", running: false)
        let music = StubMediaSource(id: "music", running: true)
        let module = MediaModule(sources: [spotify, music])

        module.send(.play)
        XCTAssertEqual(music.sent, [.play])
    }

    func testOwnerGoingQuietDoesNotLeaveAStaleTitle() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [spotify])

        spotify.publish(snapshot("Gone", playing: true, source: "com.spotify.client"))
        spotify.publish(nil) // player quit

        XCTAssertNil(module.nowPlaying, "a quit player must clear the notch, not freeze it")
    }
}

/// NowPlaying's elapsed-time projection: pure logic, previously untested.
final class NowPlayingTests: XCTestCase {

    private func playing(elapsed: TimeInterval, duration: TimeInterval?, isPlaying: Bool, at date: Date) -> NowPlaying {
        var s = NowPlaying()
        s.title = "T"
        s.elapsed = elapsed
        s.duration = duration
        s.isPlaying = isPlaying
        s.capturedAt = date
        return s
    }

    func testElapsedAdvancesWhilePlaying() {
        let start = Date(timeIntervalSince1970: 1000)
        let s = playing(elapsed: 10, duration: 100, isPlaying: true, at: start)
        XCTAssertEqual(s.elapsedNow(at: start.addingTimeInterval(5)) ?? -1, 15, accuracy: 0.001)
    }

    func testElapsedHoldsWhilePaused() {
        let start = Date(timeIntervalSince1970: 1000)
        let s = playing(elapsed: 10, duration: 100, isPlaying: false, at: start)
        XCTAssertEqual(s.elapsedNow(at: start.addingTimeInterval(60)) ?? -1, 10, accuracy: 0.001)
    }

    func testElapsedNeverRunsPastDuration() {
        let start = Date(timeIntervalSince1970: 1000)
        let s = playing(elapsed: 95, duration: 100, isPlaying: true, at: start)
        XCTAssertEqual(s.elapsedNow(at: start.addingTimeInterval(600)) ?? -1, 100, accuracy: 0.001,
                       "a stalled player update must not show 10:05 of a 1:40 track")
    }

    func testUnknownDurationStillProjects() {
        let start = Date(timeIntervalSince1970: 1000)
        let s = playing(elapsed: 10, duration: nil, isPlaying: true, at: start)
        XCTAssertEqual(s.elapsedNow(at: start.addingTimeInterval(5)) ?? -1, 15, accuracy: 0.001)
    }

    func testNilElapsedStaysNil() {
        var s = NowPlaying()
        s.isPlaying = true
        XCTAssertNil(s.elapsedNow())
    }

    func testEqualityIgnoresCapturedAt() {
        let a = playing(elapsed: 10, duration: 100, isPlaying: true, at: Date(timeIntervalSince1970: 1))
        let b = playing(elapsed: 10, duration: 100, isPlaying: true, at: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(a, b, "capturedAt is bookkeeping, not identity")
    }
}
