import Foundation
import CoreGraphics

/// One track's motion artwork: a looping video, a still cover to fall back
/// on, and which player's format the video is in.
///
/// Decodes the JSON shape `{"canvas_url", "fallback_cover_url",
/// "media_source"}`. Nothing in the app produces this payload yet: the
/// Spotify Canvas endpoint was declined (PROJECT-CONTEXT.md, *Network
/// endpoints*), so a caller has to supply it from an approved source.
///
/// Both URLs decode leniently. A missing, empty, or malformed string becomes
/// nil rather than failing the whole payload, because every consumer already
/// treats nil as "show the still" — a bad video link should cost the motion,
/// not the cover.
nonisolated struct MediaArtworkModel: Codable, Equatable, Sendable {
    enum Source: String, Codable {
        case spotify
        case appleMusic = "apple_music"

        /// Width over height. Spotify's Canvas is a vertical 9:16 clip;
        /// Apple Music's motion artwork is square, like the cover it replaces.
        var aspectRatio: CGFloat {
            switch self {
            case .spotify: 9.0 / 16.0
            case .appleMusic: 1
            }
        }
    }

    var canvasURL: URL?
    var fallbackCoverURL: URL?
    var mediaSource: Source

    init(canvasURL: URL?, fallbackCoverURL: URL?, mediaSource: Source) {
        self.canvasURL = canvasURL
        self.fallbackCoverURL = fallbackCoverURL
        self.mediaSource = mediaSource
    }

    private enum CodingKeys: String, CodingKey {
        case canvasURL = "canvas_url"
        case fallbackCoverURL = "fallback_cover_url"
        case mediaSource = "media_source"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        canvasURL = Self.url(try container.decodeIfPresent(String.self, forKey: .canvasURL))
        fallbackCoverURL = Self.url(try container.decodeIfPresent(String.self, forKey: .fallbackCoverURL))
        mediaSource = try container.decode(Source.self, forKey: .mediaSource)
    }

    /// A string worth handing to AVFoundation or AsyncImage: non-empty and
    /// with a scheme, so a bare path or stray whitespace reads as absent.
    static func url(_ string: String?) -> URL? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil else { return nil }
        return url
    }
}
