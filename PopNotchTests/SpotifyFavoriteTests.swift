import XCTest
@testable import PopNotch

/// With the Spotify account removed, nothing can like a Spotify track: its
/// `starred` is unimplemented and there is no Web API path any more. The
/// heart must be absent, not a control that does nothing.
@MainActor
final class SpotifyFavoriteTests: XCTestCase {

    private func playing() -> NowPlaying {
        var track = NowPlaying()
        track.title = "Track"
        track.artist = "Artist"
        track.isPlaying = true
        track.sourceBundleID = SpotifyAdapter.bundleID
        return track
    }

    func testASpotifyTrackIsNeverOfferedALikeToggle() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [spotify])
        spotify.publish(playing())

        XCTAssertFalse(module.canToggleFavorite)
        XCTAssertNil(module.likedCurrent, "no value, so the heart is not drawn")
    }

    func testToggleLikeIsInertForSpotify() {
        let spotify = StubMediaSource(id: "spotify", running: true)
        let module = MediaModule(sources: [spotify])
        spotify.publish(playing())

        module.toggleLike()

        XCTAssertNil(module.likedCurrent, "no optimistic value for a control that is not there")
    }
}
