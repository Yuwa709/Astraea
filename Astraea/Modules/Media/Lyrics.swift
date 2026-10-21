import Foundation
import os

/// One timestamped lyric line. `Codable` so the disk cache can round-trip it.
struct LyricsLine: Equatable, Codable {
    let time: TimeInterval
    let text: String
}

/// Pure LRC parsing and lookup, split out for tests.
enum LyricsParser {

    /// Parses LRC text: lines of `[mm:ss.xx] words`, possibly with several
    /// timestamps sharing one text. Unparseable lines and empty texts are
    /// skipped; the result is sorted by time.
    static func parse(lrc: String) -> [LyricsLine] {
        var result: [LyricsLine] = []
        let tagPattern = /\[(\d+):(\d+(?:\.\d+)?)\]/

        for rawLine in lrc.components(separatedBy: .newlines) {
            let matches = rawLine.matches(of: tagPattern)
            guard let last = matches.last else { continue }

            let text = String(rawLine[last.range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            for match in matches {
                guard let minutes = Double(match.output.1),
                      let seconds = Double(match.output.2) else { continue }
                result.append(LyricsLine(time: minutes * 60 + seconds, text: text))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    /// A line is shown fractionally early so it appears as it starts being
    /// sung rather than strictly after.
    static let lead: TimeInterval = 0.2

    /// Index of the line being sung at `elapsed` — the last line whose
    /// timestamp has passed. Nil before the first line.
    ///
    /// Binary search, not a scan: `parse` guarantees the array is sorted by
    /// time, and this is called from a view body on every progress tick, so
    /// it runs far more often than it is worth being linear about.
    static func currentIndex(at elapsed: TimeInterval, in lines: [LyricsLine]) -> Int? {
        guard !lines.isEmpty else { return nil }
        let cutoff = elapsed + lead
        var low = 0
        var high = lines.count - 1
        var found: Int?
        while low <= high {
            let mid = low + (high - low) / 2
            if lines[mid].time <= cutoff {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return found
    }

    /// The line being sung at `elapsed`. Nil before the first line.
    static func currentLine(at elapsed: TimeInterval, in lines: [LyricsLine]) -> LyricsLine? {
        currentIndex(at: elapsed, in: lines).map { lines[$0] }
    }
}
