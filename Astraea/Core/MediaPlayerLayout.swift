import Foundation

/// Which media player layout the expanded notch draws.
///
/// Both ship because people split on them (2026-10-31): `simple` is the
/// 1.5.1 redesign, with the transport on its own centred row and the
/// secondary controls behind a "more" button; `classic` is the 1.5.0
/// player, with the controls row, the heart and the volume button always
/// showing, and the lyric line on its own row. Named for what each shows,
/// not its size: the 1.5.1 player ended up no shorter than 1.5.0's. The
/// data, the sources and the full-lyrics page are the same either way;
/// only the player screen differs.
nonisolated enum MediaPlayerLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case simple
    case classic

    /// The redesign, for new installs and for upgraded ones: it is what 1.5.1
    /// already shows, so nobody's notch changes until they choose.
    static let `default`: MediaPlayerLayout = .simple

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: "Simple"
        case .classic: "Classic (1.5)"
        }
    }
}
