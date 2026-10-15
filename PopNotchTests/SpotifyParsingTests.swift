import XCTest
@testable import PopNotch

/// The AppleScript and notification payloads are strings from another
/// process; parsing them is the part most likely to break quietly. Pure
/// functions, so fully testable.
final class SpotifyParsingTests: XCTestCase {

    // MARK: - Distributed notification

    private func playingInfo() -> [AnyHashable: Any] {
        [
            "Player State": "Playing",
            "Name": "Pink Dolphin Sunset",
            "Artist": "Tory Lanez",
            "Album": "Alone At Prom",
            "Duration": 212450,          // milliseconds
            "Playback Position": 12.6,   // seconds
            "Track ID": "spotify:track:abc123"
        ]
    }

    func testDecodesPlayingNotification() {
        let snapshot = SpotifyParsing.decode(notification: playingInfo())
        XCTAssertEqual(snapshot?.title, "Pink Dolphin Sunset")
        XCTAssertEqual(snapshot?.artist, "Tory Lanez")
        XCTAssertEqual(snapshot?.album, "Alone At Prom")
        XCTAssertEqual(snapshot?.duration ?? -1, 212.45, accuracy: 0.001, "Duration arrives in ms")
        XCTAssertEqual(snapshot?.elapsed ?? -1, 12.6, accuracy: 0.001)
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.artworkIdentifier, "spotify:track:abc123")
        XCTAssertEqual(snapshot?.sourceBundleID, "com.spotify.client")
    }

    func testPausedIsContentButNotPlaying() {
        var info = playingInfo()
        info["Player State"] = "Paused"
        let snapshot = SpotifyParsing.decode(notification: info)
        XCTAssertEqual(snapshot?.isPlaying, false)
        XCTAssertEqual(snapshot?.hasContent, true, "paused music still displays")
    }

    func testStoppedDecodesToNil() {
        var info = playingInfo()
        info["Player State"] = "Stopped"
        XCTAssertNil(SpotifyParsing.decode(notification: info))
    }

    func testUnrecognisablePayloadDecodesToNil() {
        XCTAssertNil(SpotifyParsing.decode(notification: [:]))
        XCTAssertNil(SpotifyParsing.decode(notification: ["Player State": "Playing"]),
                     "state without any content must not display an empty box")
    }

    func testIntegerDurationAlsoDecodes() {
        // NSNumber bridging differs between Int and Double payloads.
        var info = playingInfo()
        info["Duration"] = Int(180000)
        XCTAssertEqual(SpotifyParsing.decode(notification: info)?.duration ?? -1, 180, accuracy: 0.001)
    }

    // MARK: - Query script output

    private let goodOutput = """
        playing
        Pink Dolphin Sunset
        Tory Lanez
        Alone At Prom
        212450
        12.607
        https://i.scdn.co/image/ab67616d0000b273
        spotify:track:abc123
        """

    func testParsesQueryOutput() {
        let parsed = SpotifyParsing.parse(scriptOutput: goodOutput)
        XCTAssertEqual(parsed?.snapshot.title, "Pink Dolphin Sunset")
        XCTAssertEqual(parsed?.snapshot.isPlaying, true)
        XCTAssertEqual(parsed?.snapshot.duration ?? -1, 212.45, accuracy: 0.001)
        XCTAssertEqual(parsed?.snapshot.elapsed ?? -1, 12.607, accuracy: 0.001)
        XCTAssertEqual(parsed?.artworkURL, "https://i.scdn.co/image/ab67616d0000b273")
    }

    func testParsesCommaDecimalLocale() {
        // AppleScript renders reals with the locale's decimal separator.
        let output = goodOutput.replacingOccurrences(of: "12.607", with: "12,607")
        XCTAssertEqual(SpotifyParsing.parse(scriptOutput: output)?.snapshot.elapsed ?? -1,
                       12.607, accuracy: 0.001)
    }

    func testStoppedOutputParsesToNil() {
        XCTAssertNil(SpotifyParsing.parse(scriptOutput: "stopped"))
    }

    func testTruncatedOutputParsesToNil() {
        XCTAssertNil(SpotifyParsing.parse(scriptOutput: "playing\nTitle\nArtist"))
    }

    func testPausedQueryOutputIsNotPlaying() {
        let output = goodOutput.replacingOccurrences(of: "playing", with: "paused")
        XCTAssertEqual(SpotifyParsing.parse(scriptOutput: output)?.snapshot.isPlaying, false)
    }
}
