import SwiftUI
import AppKit

/// Motion artwork with a still fallback and a legibility vignette.
///
/// Shows the video only when there is one, it has not failed, and Reduce
/// Motion is off (hard rule 8). Under Reduce Motion no player is built at
/// all, the same rule `MediaWingWaveform` follows: the still stands in.
///
/// **`isActive` is the caller's visibility signal** — pass the media
/// module's "expanded view is on screen" state, so the loop pauses when the
/// panel collapses. Display sleep is handled here on top of it, so a panel
/// pinned open behind a sleeping display does not keep decoding (hard rule 9).
///
/// A remote `canvasURL` or `fallbackCoverURL` is a network call. Rule 6
/// applies to whoever builds the model, not to this view.
struct AnimatedArtworkCanvas: View {
    let model: MediaArtworkModel
    let isActive: Bool
    /// The cover the player already handed over, when there is one. Preferred
    /// to `fallbackCoverURL` because it costs no fetch.
    var artwork: NSImage? = nil
    /// Off where nothing is drawn over the artwork, such as the player's
    /// header, whose text sits beside the cover rather than on it.
    var showsVignette = true

    @State private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var displayAsleep = false
    @State private var failedURL: URL?

    private var videoURL: URL? {
        guard !reduceMotion, let url = model.canvasURL, url != failedURL else { return nil }
        return url
    }

    var body: some View {
        // A clear base sized by the aspect ratio, with everything else as
        // overlays: a fill-scaled image inside a plain ZStack would size the
        // stack to the image's overflow instead of the box.
        Color.clear
            .aspectRatio(model.mediaSource.aspectRatio, contentMode: .fit)
            .overlay {
                ZStack {
                    if let videoURL {
                        NativeLoopingPlayerView(url: videoURL,
                                                isPlaying: isActive && !displayAsleep,
                                                onFailure: { failedURL = videoURL })
                            .id(videoURL)
                    } else {
                        ArtworkStill(image: artwork, url: model.fallbackCoverURL)
                    }
                    if showsVignette {
                        ArtworkVignette()
                    }
                }
            }
            .clipped()
        .onReceive(workspaceCenter.publisher(for: NSWorkspace.screensDidSleepNotification)) { _ in
            displayAsleep = true
        }
        .onReceive(workspaceCenter.publisher(for: NSWorkspace.screensDidWakeNotification)) { _ in
            displayAsleep = false
        }
        .onReceive(workspaceCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { _ in
            reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    private var workspaceCenter: NotificationCenter {
        NSWorkspace.shared.notificationCenter
    }
}

/// The still cover: the player's own image first, then the fallback URL,
/// then an empty tile so the layout never collapses.
private struct ArtworkStill: View {
    let image: NSImage?
    let url: URL?

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else if let url {
            AsyncImage(url: url) { phase in
                if let loaded = phase.image {
                    loaded.resizable().scaledToFill()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle().fill(Color.white.opacity(0.08))
    }
}

/// Darkens the lower part of the artwork so controls and track text drawn
/// over it stay readable on a bright frame.
private struct ArtworkVignette: View {
    var body: some View {
        LinearGradient(colors: [.clear, .black.opacity(0.15), .black.opacity(0.55)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}
