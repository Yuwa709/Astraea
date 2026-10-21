import Foundation

/// One lock-screen scan's frame numbers, liveness on or off, for the
/// scan-end `.notice` summary: how fast frames and faces arrived, what
/// recognition cost, and how the similarities fell against the threshold.
/// Times are seconds since the camera started.
///
/// The `.notice` summary gives only `SimilarityBand` counts: it persists,
/// and raw scores there would be a lasting record and an oracle to tune a
/// photo against. The raw min/median/max are `similarityDetail`, for a
/// `.debug` line.
nonisolated struct ScanFrameStats: Sendable {
    /// The scan's match threshold, for the bands.
    let threshold: Float
    /// Frames recognition ran on, with a face or without.
    private(set) var checkedFrames = 0
    private(set) var faceFrames = 0
    private(set) var matchedFrames = 0
    /// The top identity's similarity on each face frame that scored one.
    private(set) var similarities: [Float] = []
    private(set) var firstMatchAfter: TimeInterval?
    private(set) var recognitionSeconds: TimeInterval = 0

    init(threshold: Float) {
        self.threshold = threshold
    }

    /// Every checked frame, face or not.
    mutating func recordChecked(recognitionSeconds seconds: TimeInterval) {
        checkedFrames += 1
        recognitionSeconds += seconds
    }

    mutating func recordFace(similarity: Float?, matched: Bool, after elapsed: TimeInterval) {
        faceFrames += 1
        if let similarity { similarities.append(similarity) }
        guard matched else { return }
        matchedFrames += 1
        if firstMatchAfter == nil { firstMatchAfter = elapsed }
    }

    /// The middle value, or the mean of the middle two; nil when empty.
    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// The best similarity's band, nil when none scored.
    var bestBand: SimilarityBand? {
        similarities.max().map { SimilarityBand(similarity: $0, threshold: threshold) }
    }

    /// Face frames per band, best first, for the `.notice` summary.
    var bandCounts: String {
        let counts = SimilarityBand.allCases.map { band in
            (band, similarities.filter { SimilarityBand(similarity: $0, threshold: threshold) == band }.count)
        }
        return counts.map { "\($0.1) \($0.0.rawValue)" }.joined(separator: ", ")
    }

    /// `elapsed`: seconds from the camera starting to the scan's end. No
    /// raw similarity: see the type's comment.
    func summary(elapsed: TimeInterval) -> String {
        let seconds = max(elapsed, 0.001)
        let rate = String(format: "%d face of %d checked frames in %.1f s (%.2f face/s, %.2f checked/s)",
                          faceFrames, checkedFrames, elapsed, Double(faceFrames) / seconds, Double(checkedFrames) / seconds)
        let firstMatch = firstMatchAfter.map { String(format: "first after %.2f s", $0) } ?? "none"
        let similarity = similarities.isEmpty ? "no similarity" : "similarity bands \(bandCounts)"
        let recognition = checkedFrames > 0 ? recognitionSeconds / Double(checkedFrames) : 0
        return "\(rate), \(matchedFrames) matched (\(firstMatch)), \(similarity), "
            + String(format: "recognition %.1f ms mean", recognition * 1000)
    }

    /// The raw numbers, for `.debug` only.
    var similarityDetail: String {
        guard let low = similarities.min(), let high = similarities.max(), let middle = Self.median(similarities) else {
            return "no similarity"
        }
        return String(format: "similarity min %.3f / median %.3f / max %.3f (threshold %.2f)", low, middle, high, threshold)
    }
}
