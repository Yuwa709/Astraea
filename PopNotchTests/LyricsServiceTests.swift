import XCTest
@testable import PopNotch

/// The lookup path itself needs a network, so what is tested here is the
/// pure logic underneath it: cache identity, the stable filename hash, and
/// the binary-search lookup that runs on every progress tick.
final class LyricsServiceTests: XCTestCase {

    // MARK: - Cache key

    func testCacheKeyIsCaseInsensitive() {
        XCTAssertEqual(
            LyricsService.cacheKey(artist: "Childish Gambino", title: "3005", duration: 234),
            LyricsService.cacheKey(artist: "CHILDISH GAMBINO", title: "3005", duration: 234))
    }

    func testCacheKeySeparatesDifferentEdits() {
        // Duration is in the key precisely so a radio edit and an album cut
        // with the same title do not share cached lyrics.
        XCTAssertNotEqual(
            LyricsService.cacheKey(artist: "A", title: "Song", duration: 234),
            LyricsService.cacheKey(artist: "A", title: "Song", duration: 198))
    }

    func testCacheKeyToleratesMissingDuration() {
        XCTAssertEqual(LyricsService.cacheKey(artist: "A", title: "B", duration: nil),
                       "a|b|?")
    }

    func testCacheKeyRoundsDuration() {
        XCTAssertEqual(LyricsService.cacheKey(artist: "A", title: "B", duration: 233.6),
                       LyricsService.cacheKey(artist: "A", title: "B", duration: 234.0))
    }

    // MARK: - Disk cache filename

    func testFilenameIsStableAcrossCalls() {
        // Swift's own hashValue is seeded per process; if this were built on
        // it the cache would miss on every launch.
        let key = LyricsService.cacheKey(artist: "Childish Gambino", title: "3005", duration: 234)
        XCTAssertEqual(LyricsDiskCache.filename(for: key), LyricsDiskCache.filename(for: key))
    }

    func testFilenameIsKnownConstantForAKnownKey() {
        // Pins FNV-1a specifically: any change to the hash would orphan every
        // cache file already on disk, which should be a deliberate decision.
        XCTAssertEqual(LyricsDiskCache.filename(for: "a|b|234"), "dbc1d9398e302a93.json")
    }

    func testDifferentKeysGiveDifferentFilenames() {
        XCTAssertNotEqual(LyricsDiskCache.filename(for: "a|b|1"),
                          LyricsDiskCache.filename(for: "a|b|2"))
    }

    // MARK: - Disk cache round trip

    func testEntryRoundTripsIncludingAKnownMiss() throws {
        let lines = [LyricsLine(time: 1, text: "one"), LyricsLine(time: 2, text: "two")]
        let hit = LyricsDiskCache.Entry(key: "k", lines: lines)
        let decodedHit = try JSONDecoder().decode(
            LyricsDiskCache.Entry.self, from: JSONEncoder().encode(hit))
        XCTAssertEqual(decodedHit.lines, lines)

        // A miss must round-trip as a miss, not as an absent file, or it gets
        // re-queried on every track change forever.
        let miss = LyricsDiskCache.Entry(key: "k", lines: nil)
        let decodedMiss = try JSONDecoder().decode(
            LyricsDiskCache.Entry.self, from: JSONEncoder().encode(miss))
        XCTAssertNil(decodedMiss.lines)
        XCTAssertEqual(decodedMiss.key, "k")
    }

    // MARK: - Binary search

    private let lines = [
        LyricsLine(time: 0, text: "zero"),
        LyricsLine(time: 10, text: "ten"),
        LyricsLine(time: 20, text: "twenty"),
        LyricsLine(time: 30, text: "thirty"),
    ]

    func testIndexBeforeFirstLineIsNil() {
        XCTAssertNil(LyricsParser.currentIndex(at: -5, in: lines))
    }

    func testIndexAtExactTimestamp() {
        XCTAssertEqual(LyricsParser.currentIndex(at: 20, in: lines), 2)
    }

    func testIndexBetweenTimestampsHoldsPreviousLine() {
        XCTAssertEqual(LyricsParser.currentIndex(at: 19.5, in: lines), 1)
        // 19.9 is inside the 0.2s lead, so the next line is already showing.
        XCTAssertEqual(LyricsParser.currentIndex(at: 19.9, in: lines), 2)
    }

    func testIndexAfterLastLineHoldsLastLine() {
        XCTAssertEqual(LyricsParser.currentIndex(at: 999, in: lines), 3)
    }

    func testLeadShowsLineFractionallyEarly() {
        // 9.85 + 0.2 lead lands past 10, so the line is already showing.
        XCTAssertEqual(LyricsParser.currentIndex(at: 9.85, in: lines), 1)
        XCTAssertEqual(LyricsParser.currentIndex(at: 9.7, in: lines), 0)
    }

    func testEmptyLinesGiveNil() {
        XCTAssertNil(LyricsParser.currentIndex(at: 10, in: []))
    }

    func testBinarySearchAgreesWithLinearScanEverywhere() {
        // The lookup was a `.last { $0.time <= cutoff }` scan before it became
        // a binary search; this pins that the answer did not change.
        let many = (0..<500).map { LyricsLine(time: Double($0) * 1.7, text: "\($0)") }
        for t in stride(from: -2.0, through: 860.0, by: 0.35) {
            let linear = many.last { $0.time <= t + LyricsParser.lead }
            XCTAssertEqual(LyricsParser.currentLine(at: t, in: many), linear, "at \(t)")
        }
    }
}
