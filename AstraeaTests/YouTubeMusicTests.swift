import XCTest
@testable import Astraea

/// The YouTube Music adapter's pure layer (scan output, replies, page state)
/// and its place in the module's arbitration.
///
/// Arbitration tests use a real `YouTubeMusicAdapter` that never starts
/// observing, and drive it through the same `onUpdate` closure its reads
/// call, so no Apple Event is sent.
@MainActor
final class YouTubeMusicTests: XCTestCase {

    // MARK: - Scan

    func testScanParsesChromeTabs() {
        let output = "101\t7\thttps://music.youtube.com/watch?v=abc\n102\t9\thttps://music.youtube.com/\n"
        let tabs = YouTubeMusicScripts.parseScan(output, browser: .chrome)
        XCTAssertEqual(tabs, [
            YouTubeMusicTab(browser: .chrome, windowID: 101, tabRef: 7),
            YouTubeMusicTab(browser: .chrome, windowID: 102, tabRef: 9)
        ])
        XCTAssertEqual(tabs[0].specifier, "tab id 7 of window id 101")
    }

    func testScanIgnoresOtherSitesAndJunk() {
        let output = "1\t2\thttps://www.youtube.com/watch?v=abc\nnot a line\n\n3\tx\thttps://music.youtube.com/\n"
        XCTAssertTrue(YouTubeMusicScripts.parseScan(output, browser: .chrome).isEmpty,
                      "regular YouTube must never be mistaken for YouTube Music")
    }

    func testSafariTabsAreAddressedByIndex() {
        let tabs = YouTubeMusicScripts.parseScan("55\t3\thttps://music.youtube.com/\n", browser: .safari)
        XCTAssertEqual(tabs.first?.specifier, "tab 3 of window id 55")
    }

    // MARK: - Replies

    func testChromeJavaScriptOffIsRecognised() {
        let output = YouTubeMusicScripts.errorMarker
            + "12|Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events."
        XCTAssertEqual(YouTubeMusicScripts.classify(output, browser: .chrome), .javaScriptOff)
    }

    func testSafariJavaScriptOffIsRecognised() {
        let output = YouTubeMusicScripts.errorMarker
            + "8|You must enable 'Allow JavaScript from Apple Events' in the Developer section of Safari Settings to use 'do JavaScript'."
        XCTAssertEqual(YouTubeMusicScripts.classify(output, browser: .safari), .javaScriptOff)
    }

    func testDeniedTimeoutAndLostAreDistinct() {
        let marker = YouTubeMusicScripts.errorMarker
        XCTAssertEqual(YouTubeMusicScripts.classify(marker + "-1743|Not authorized", browser: .chrome), .denied)
        XCTAssertEqual(YouTubeMusicScripts.classify(marker + "-1712|Timed out", browser: .chrome), .transient)
        XCTAssertEqual(YouTubeMusicScripts.classify(marker + "-1728|Can't get tab id 4", browser: .chrome), .lost)
        XCTAssertEqual(YouTubeMusicScripts.classify(nil, browser: .chrome), .lost)
        XCTAssertEqual(YouTubeMusicScripts.classify("ok", browser: .chrome), .value("ok"))
    }

    func testAppleScriptLiteralEscapes() {
        XCTAssertEqual(YouTubeMusicScripts.appleScriptLiteral(#"a"b\c"#), #""a\"b\\c""#)
    }

    func testPageScriptsCarryNoDoubleQuotes() {
        // Escaped anyway, but a double quote here would mean a selector or
        // string someone changed without reading the escaping.
        let scripts = [YouTubeMusicScripts.stateJavaScript, YouTubeMusicScripts.artworkJavaScript,
                       YouTubeMusicScripts.seekJavaScript(to: 12.5)]
            + [MediaCommand.play, .pause, .togglePlayPause, .nextTrack, .previousTrack]
                .map(YouTubeMusicScripts.commandJavaScript)
        for script in scripts { XCTAssertFalse(script.contains("\""), script) }
    }

    func testSeekUsesAPointDecimal() {
        XCTAssertTrue(YouTubeMusicScripts.seekJavaScript(to: 61.25).contains("v.currentTime=61.250"))
        XCTAssertTrue(YouTubeMusicScripts.seekJavaScript(to: -4).contains("v.currentTime=0.000"))
    }

    // MARK: - Page state

    func testStateParses() throws {
        let json = #"{"ok":true,"title":"Together Forever","artist":"Rick Astley","album":"","art":"https://i.ytimg.com/a.jpg","artReady":true,"duration":203.3,"elapsed":1.2,"playing":true,"id":"yPYZ"}"#
        let state = try XCTUnwrap(YouTubeMusicScripts.parseState(json))
        XCTAssertEqual(state.title, "Together Forever")
        XCTAssertNil(state.album, "an empty album is absent, not blank")
        XCTAssertEqual(state.duration, 203.3)
        XCTAssertTrue(state.isPlaying)
        XCTAssertTrue(state.artworkReady)
        XCTAssertEqual(state.videoID, "yPYZ")
    }

    func testStateFromAnotherPageIsNil() {
        XCTAssertNil(YouTubeMusicScripts.parseState(#"{"ok":false}"#))
        XCTAssertNil(YouTubeMusicScripts.parseState("garbage"))
    }

    func testUnloadedDurationIsAbsent() throws {
        let json = #"{"ok":true,"title":"T","artist":"A","duration":null,"elapsed":0,"playing":false}"#
        XCTAssertNil(try XCTUnwrap(YouTubeMusicScripts.parseState(json)).duration)
    }

    func testPageWithNoTrackIsNoSession() {
        let state = YouTubeMusicPageState(artworkReady: false, isPlaying: false)
        XCTAssertNil(YouTubeMusicScripts.snapshot(from: state, browser: .chrome,
                                                  artwork: nil, capturedAt: Date()))
    }

    func testSnapshotNamesTheBrowserAndTrack() throws {
        let state = YouTubeMusicPageState(title: "T", artist: "A", artworkReady: false,
                                          duration: 100, elapsed: 5, isPlaying: true, videoID: "v1")
        let snapshot = try XCTUnwrap(YouTubeMusicScripts.snapshot(
            from: state, browser: .safari, artwork: nil, capturedAt: Date()))
        XCTAssertEqual(snapshot.sourceBundleID, "com.apple.Safari")
        XCTAssertEqual(snapshot.artworkIdentifier, "youtube-music:v1")
    }

    func testDataURLDecodes() {
        let data = Data([0xFF, 0xD8, 0xFF])
        XCTAssertEqual(YouTubeMusicScripts.decodeDataURL("data:image/jpeg;base64," + data.base64EncodedString()), data)
        XCTAssertNil(YouTubeMusicScripts.decodeDataURL(""))
        XCTAssertNil(YouTubeMusicScripts.decodeDataURL("https://i.ytimg.com/a.jpg"))
    }

    // MARK: - Publishing and choosing

    private func snapshot(_ title: String, playing: Bool, elapsed: TimeInterval = 10,
                          at date: Date, bundle: String = "com.google.Chrome") -> NowPlaying {
        var s = NowPlaying()
        s.title = title
        s.artist = "Artist"
        s.isPlaying = playing
        s.elapsed = elapsed
        s.duration = 200
        s.capturedAt = date
        s.sourceBundleID = bundle
        return s
    }

    func testOnTimeClockReadIsNotRepublished() {
        let t0 = Date()
        let old = snapshot("T", playing: true, elapsed: 10, at: t0)
        let new = snapshot("T", playing: true, elapsed: 13.1, at: t0 + 3)
        XCTAssertTrue(YouTubeMusicScripts.isClockOnlyChange(new, from: old, at: t0 + 3))
    }

    func testSeekTrackChangeAndPauseAreRepublished() {
        let t0 = Date()
        let old = snapshot("T", playing: true, elapsed: 10, at: t0)
        XCTAssertFalse(YouTubeMusicScripts.isClockOnlyChange(
            snapshot("T", playing: true, elapsed: 90, at: t0 + 3), from: old, at: t0 + 3), "seek")
        XCTAssertFalse(YouTubeMusicScripts.isClockOnlyChange(
            snapshot("U", playing: true, elapsed: 13, at: t0 + 3), from: old, at: t0 + 3), "track")
        XCTAssertFalse(YouTubeMusicScripts.isClockOnlyChange(
            snapshot("T", playing: false, elapsed: 13, at: t0 + 3), from: old, at: t0 + 3), "pause")
    }

    func testPlayingTabIsChosenOverTheFollowedOne() {
        let a = YouTubeMusicTab(browser: .chrome, windowID: 1, tabRef: 1)
        let b = YouTubeMusicTab(browser: .safari, windowID: 2, tabRef: 1)
        let paused = YouTubeMusicPageState(title: "A", artworkReady: false, isPlaying: false)
        let playing = YouTubeMusicPageState(title: "B", artworkReady: false, isPlaying: true)
        XCTAssertEqual(YouTubeMusicScripts.choose([(a, paused), (b, playing)], current: a)?.tab, b)
        XCTAssertEqual(YouTubeMusicScripts.choose([(b, paused), (a, paused)], current: a)?.tab, a)
        let empty = YouTubeMusicPageState(artworkReady: false, isPlaying: false)
        XCTAssertNil(YouTubeMusicScripts.choose([(a, empty)], current: nil))
    }

    // MARK: - Arbitration

    private func browserVideo(playing: Bool = true) -> SystemMediaEnvelope {
        let json = """
        {"type":"data","diff":false,"payload":{
          "title":"Some Video","artist":"Channel","album":"",
          "bundleIdentifier":"com.google.Chrome","contentItemIdentifier":"video-1",
          "playing":\(playing),"elapsedTime":1.0,"duration":100.0}}
        """
        guard let envelope = SystemMediaParsing.decode(line: Data(json.utf8)) else {
            fatalError("test fixture did not decode")
        }
        return envelope
    }

    func testYouTubeVideoDoesNotReplaceYouTubeMusic() {
        let ytm = YouTubeMusicAdapter()
        let system = SystemMediaAdapter()
        let module = MediaModule(sources: [SpotifyAdapter(), MusicAdapter(), ytm, system])

        ytm.onUpdate?(snapshot("Song", playing: false, at: Date()))
        system.ingest([browserVideo()])

        XCTAssertEqual(module.nowPlaying?.title, "Song",
                       "a paused YouTube Music track holds the notch against other browser media")
    }

    func testFallsBackToSystemMediaWhenYouTubeMusicGoes() {
        let ytm = YouTubeMusicAdapter()
        let system = SystemMediaAdapter()
        let module = MediaModule(sources: [ytm, system])

        ytm.onUpdate?(snapshot("Song", playing: true, at: Date()))
        system.ingest([browserVideo()])
        ytm.onUpdate?(nil)

        XCTAssertEqual(module.nowPlaying?.title, "Some Video",
                       "with the tab gone the notch returns to normal system detection")
    }

    func testPlayingSpotifyStillBeatsPausedYouTubeMusic() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let ytm = YouTubeMusicAdapter()
        let module = MediaModule(sources: [spotify, ytm])

        ytm.onUpdate?(snapshot("Song", playing: false, at: Date()))
        spotify.publish(snapshot("Spotify Track", playing: true, at: Date(), bundle: "com.spotify.client"))

        XCTAssertEqual(module.nowPlaying?.title, "Spotify Track")
    }

    func testPlayingYouTubeMusicTakesOverFromPausedSpotify() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let ytm = YouTubeMusicAdapter()
        let module = MediaModule(sources: [spotify, ytm])

        spotify.publish(snapshot("Spotify Track", playing: false, at: Date(), bundle: "com.spotify.client"))
        ytm.onUpdate?(snapshot("Song", playing: true, at: Date()))

        XCTAssertEqual(module.nowPlaying?.title, "Song")
    }

    func testNoSetupHintWithoutAnUnreadableTab() {
        let ytm = YouTubeMusicAdapter()
        let system = SystemMediaAdapter()
        let module = MediaModule(sources: [ytm, system])

        system.ingest([browserVideo()])

        XCTAssertEqual(module.nowPlaying?.title, "Some Video")
        XCTAssertNil(module.browserSetupHint,
                     "browser media alone is not a reason to ask the user to change a setting")
    }
}
