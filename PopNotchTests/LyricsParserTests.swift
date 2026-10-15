import XCTest
@testable import PopNotch

final class LyricsParserTests: XCTestCase {

    func testParsesTimestampedLines() {
        let lrc = """
            [00:12.50] And the world's gonna know your name
            [00:16.10] Cause you burn with the brightest flame
            """
        let lines = LyricsParser.parse(lrc: lrc)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].time, 12.5, accuracy: 0.001)
        XCTAssertEqual(lines[0].text, "And the world's gonna know your name")
        XCTAssertEqual(lines[1].time, 76.1 - 60, accuracy: 0.001)
    }

    func testMinutesConvert() {
        let lines = LyricsParser.parse(lrc: "[02:05.00] two five")
        XCTAssertEqual(lines.first?.time ?? -1, 125, accuracy: 0.001)
    }

    func testMultipleTimestampsShareOneText() {
        let lines = LyricsParser.parse(lrc: "[00:10.00][01:10.00] chorus")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["chorus", "chorus"])
        XCTAssertEqual(lines.map(\.time), [10, 70])
    }

    func testSkipsEmptyAndUntimedLines() {
        let lrc = """
            [ar: The Script]
            plain untimed text
            [00:05.00]
            [00:07.00] real line
            """
        let lines = LyricsParser.parse(lrc: lrc)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "real line")
    }

    func testResultIsSortedEvenIfInputIsNot() {
        let lines = LyricsParser.parse(lrc: "[00:30.00] later\n[00:10.00] earlier")
        XCTAssertEqual(lines.map(\.text), ["earlier", "later"])
    }

    func testCurrentLineLookup() {
        let lines = [
            LyricsLine(time: 10, text: "one"),
            LyricsLine(time: 20, text: "two"),
            LyricsLine(time: 30, text: "three"),
        ]
        XCTAssertNil(LyricsParser.currentLine(at: 5, in: lines), "before the first line")
        XCTAssertEqual(LyricsParser.currentLine(at: 15, in: lines)?.text, "one")
        XCTAssertEqual(LyricsParser.currentLine(at: 29.9, in: lines)?.text, "three",
                       "the 0.2s lead lets a line appear as it starts")
        XCTAssertEqual(LyricsParser.currentLine(at: 300, in: lines)?.text, "three",
                       "last line holds to the end")
    }
}
