import XCTest
@testable import Astraea

/// Motion-artwork payload decoding. The view treats a nil video URL as
/// "show the still", so the lenient cases matter as much as the happy one:
/// a bad link must cost the motion, never the whole payload.
final class MediaArtworkModelTests: XCTestCase {

    private func decode(_ json: String) throws -> MediaArtworkModel {
        try JSONDecoder().decode(MediaArtworkModel.self, from: Data(json.utf8))
    }

    func testDecodesFullPayload() throws {
        let model = try decode("""
            {"canvas_url": "https://example.com/loop.mp4",
             "fallback_cover_url": "https://example.com/cover.jpg",
             "media_source": "spotify"}
            """)
        XCTAssertEqual(model.canvasURL?.absoluteString, "https://example.com/loop.mp4")
        XCTAssertEqual(model.fallbackCoverURL?.absoluteString, "https://example.com/cover.jpg")
        XCTAssertEqual(model.mediaSource, .spotify)
    }

    func testMissingNullAndEmptyURLsDecodeAsNil() throws {
        let missing = try decode(#"{"media_source": "apple_music"}"#)
        XCTAssertNil(missing.canvasURL)
        XCTAssertNil(missing.fallbackCoverURL)

        let blank = try decode(#"{"canvas_url": null, "fallback_cover_url": "  ", "media_source": "apple_music"}"#)
        XCTAssertNil(blank.canvasURL)
        XCTAssertNil(blank.fallbackCoverURL)
    }

    func testSchemelessURLDecodesAsNil() throws {
        let model = try decode(#"{"canvas_url": "loop.mp4", "media_source": "spotify"}"#)
        XCTAssertNil(model.canvasURL)
    }

    func testFileURLIsAccepted() throws {
        let model = try decode(#"{"canvas_url": "file:///tmp/loop.mov", "media_source": "apple_music"}"#)
        XCTAssertEqual(model.canvasURL?.isFileURL, true)
    }

    func testUnknownSourceFailsDecoding() {
        XCTAssertThrowsError(try decode(#"{"media_source": "tidal"}"#))
    }

    func testAspectRatios() {
        XCTAssertEqual(MediaArtworkModel.Source.spotify.aspectRatio, 9.0 / 16.0)
        XCTAssertEqual(MediaArtworkModel.Source.appleMusic.aspectRatio, 1)
    }

    func testRoundTripsThroughEncoding() throws {
        let original = MediaArtworkModel(canvasURL: URL(string: "https://example.com/a.mp4"),
                                         fallbackCoverURL: nil, mediaSource: .appleMusic)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(MediaArtworkModel.self, from: data), original)
    }
}
