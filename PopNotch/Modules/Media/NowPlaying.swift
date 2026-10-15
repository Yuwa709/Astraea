import Foundation

/// A snapshot of what is playing, decoded from MediaRemote's raw dictionary.
///
/// Every field is optional except `isPlaying`: a player may report a title
/// with no artwork, or artwork mid-load with no duration. Views show what is
/// present and omit the rest rather than rendering placeholders.
struct NowPlaying: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    /// Raw image bytes as delivered (usually JPEG). Decoded to an image in the
    /// view layer, not here, so the model stays cheap to compare and copy.
    var artworkData: Data?
    var artworkIdentifier: String?
    /// Where the artwork can be fetched from, when the player says. Only
    /// Spotify's scripting interface offers one; Music hands over raw bytes
    /// through an Apple Event and the system source base64 in its payload,
    /// so both leave this nil.
    ///
    /// Deliberately absent from `==` below: it is derived from the track, so
    /// a snapshot that gains it mid-track is the same player state, and
    /// counting it would publish an extra update for no visible change.
    var artworkURL: String?
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var isPlaying: Bool = false
    /// Bundle id of the app that owns the session, e.g. com.spotify.client.
    var sourceBundleID: String?

    /// True when there is genuinely something to show. An all-nil snapshot
    /// with nothing playing should hide the module, not display an empty box.
    var hasContent: Bool {
        title != nil || artist != nil || artworkData != nil
    }

    /// A usable duration: what the player's progress row, and so the
    /// spectrum drawn in it, needs in order to exist. The row and
    /// `MediaModule.drawsSpectrum` both read this, so capture cannot run for
    /// a row that is not drawn.
    var hasDuration: Bool {
        (duration ?? 0) > 0
    }

    /// When `elapsed` was captured, so it can be projected forward while
    /// playing instead of freezing between player updates.
    var capturedAt: Date = Date()

    /// `elapsed` projected to `date`: advances while playing, holds while
    /// paused, never runs past the duration.
    func elapsedNow(at date: Date = Date()) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard isPlaying else { return elapsed }
        let projected = elapsed + date.timeIntervalSince(capturedAt)
        guard let duration else { return projected }
        return min(projected, duration)
    }

    /// capturedAt is bookkeeping, not identity: two snapshots of the same
    /// player state taken at different moments are equal.
    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title
            && lhs.artist == rhs.artist
            && lhs.album == rhs.album
            && lhs.artworkData == rhs.artworkData
            && lhs.artworkIdentifier == rhs.artworkIdentifier
            && lhs.duration == rhs.duration
            && lhs.elapsed == rhs.elapsed
            && lhs.isPlaying == rhs.isPlaying
            && lhs.sourceBundleID == rhs.sourceBundleID
    }
}
