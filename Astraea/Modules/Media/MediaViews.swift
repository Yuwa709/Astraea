import SwiftUI
import AppKit

extension Color {
    /// The media accent: a warm peach, user-chosen against the Sapphire
    /// reference. A future nicety could derive it from the artwork; for now
    /// it is deliberately fixed.
    static let mediaAccent = Color(red: 1.0, green: 0.72, blue: 0.52)
}

/// Every tunable governing lyric motion, in one place so feel can be retuned
/// without hunting through the file. Shared by the one-line ticker, the
/// full-lyrics page, and the zoom transition between them.
private enum LyricsMotion {
    /// Governs a line's own movement on the full lyrics page when the active
    /// index changes.
    static let lineSpringResponse: Double = 0.30
    static let lineSpringDamping: Double = 0.86
    static var lineSpring: Animation {
        .spring(response: lineSpringResponse, dampingFraction: lineSpringDamping, blendDuration: 0)
    }

    /// Opacity lost per line of distance from the active one, floored at 0 —
    /// distance 1 reads at `1 - fadePerLine`, distance 2 at `1 - 2*fadePerLine`.
    /// Used only by the full lyrics page, which renders every line unwindowed
    /// (see its own doc comment for why that makes a continuous curve safe).
    static let fadePerLine: Double = 0.42

    /// How much larger the active line grows on the full lyrics page, where
    /// there is room for it. The ticker shows its one line at natural size.
    static let fullPageActiveScale: CGFloat = 1.22

    /// The ticker's row height, and so the whole lyric area's height in the
    /// player: one `lineLimit(1)` line at `tickerFontSize`, the same 15pt each
    /// line of the old three-line ticker had. The full page cannot use a
    /// fixed row — its lines wrap — so it measures instead; see `LyricsLayout`.
    static let tickerLineHeight: CGFloat = 15
    /// The ticker's type. A step below the artist line's 13pt, and its accent
    /// dimmed, so the song title stays the loudest thing in the player; at
    /// full-strength accent the lyric was the brightest coloured text in the
    /// panel and competed with it. Applied to the colour, not as `.opacity`,
    /// so it never multiplies into the cross-fade's own opacity transition.
    static let tickerFontSize: CGFloat = 12
    static let tickerAccentOpacity: Double = 0.6
    /// The ticker's cross-fade when the active line changes: the outgoing
    /// line fades out while the incoming one fades in, in place. Short enough
    /// to read as a swap rather than a linger.
    static let tickerCrossfadeDuration: Double = 0.18

    /// Full page type size. Shared by the rendered `Text` and by the
    /// measurement that positions it — they must agree or every offset is
    /// computed for a line of a different height than the one drawn.
    static let fullPageFontSize: CGFloat = 20
    /// Blank space between the bottom of one full-page line and the top of the
    /// next, on top of each line's own measured height.
    static let fullPageLineGap: CGFloat = 12
    /// Clear space at each side of the full page, after the active line's
    /// scale is accounted for.
    static let fullPageSidePadding: CGFloat = 22
    /// Stands in when a line's height cannot be measured — an index off the
    /// end of the array, including the phantom "before the first timestamp"
    /// active line at -1.
    static let fullPageFallbackLineHeight: CGFloat = 24
    /// The full page's line area. Was 160; 180 shows about one more line of
    /// context either side of the active one.
    static let fullPageHeight: CGFloat = 180

    /// The home <-> full-lyrics screen swap.
    static let zoomTransitionDuration: Double = 0.38
}

/// The player screen's spacing and control sizes, in one place so they can be
/// retuned without hunting through the views. Built on `NotchStyle`; the
/// tokens here are the media page's own, the ones the shared set has no
/// slot for.
private enum PlayerLayout {
    /// The player and the full-lyrics takeover share one width, so swapping
    /// between them changes only the panel's height. Was 368 (player) and
    /// 400 (lyrics).
    static let width: CGFloat = 400

    /// Gap between the header, the scrub bar and Up Next. Wider than `ScrubGeometry.hitOverhang`, so the scrub
    /// bar's grab zone never reaches the header above it.
    /// 10, not 12: the page read as too tall (user, 2026-10-29). Still above
    /// the 8pt overhang.
    static let sectionSpacing: CGFloat = 10

    /// The artwork. The header row is exactly this tall whether or not the
    /// artist is present, so a track missing one never resizes the panel.
    /// 56, down from 72 (user, 2026-10-29: too much space): title and
    /// artist need no more.
    static let artworkSide: CGFloat = 56
    static let artworkCorner: CGFloat = 10

    /// The title's type: a step above the shared 13pt title, because on
    /// this page it is the headline.
    static let titleFont = Font.system(size: 16, weight: .semibold)
    static let titleArtistSpacing: CGFloat = 2

    /// The time labels sit at the ends of the transport row, which leaves
    /// the wave the full width. Their minimum width (fits "0:00" to "59:59"
    /// without jitter) and their type.
    static let timeLabelMinWidth: CGFloat = 30
    static let timeFont = Font.system(size: 10, weight: .medium)

    /// Transport, centred on its own row under the wave (user, 2026-10-29:
    /// play belongs in the middle). Was stacked over the secondary controls
    /// in the header's trailing corner. Spaced wider than it was there: on
    /// a row of its own it reads as the page's main control.
    static let transportGlyphSize: CGFloat = 16
    static let playGlyphSize: CGFloat = 22
    static let transportButtonSide: CGFloat = 30
    static let playButtonSide: CGFloat = 34
    static let transportSpacing: CGFloat = 12
    /// Wave to transport. At least `ScrubGeometry.hitOverhang`, so the scrub
    /// bar's grab zone never reaches the transport buttons below it.
    static let waveTransportSpacing: CGFloat = ScrubGeometry.hitOverhang

    /// The secondary controls (shuffle, heart, volume, repeat) live behind
    /// the header's "more" button, standing in for the track's text while
    /// open, spread evenly across the space. The button's glyph.
    static let moreGlyphSize: CGFloat = 13
    /// Their spring out of the "more" button: relaxed, a touch of settle and
    /// no real bounce (user, 2026-10-29: "not too intense"). The scale each
    /// starts at, and the delay between one and the next.
    static let secondarySpring = Animation.spring(response: 0.5, dampingFraction: 0.82)
    static let secondarySpringScale: CGFloat = 0.3
    static let secondarySpringStagger: Double = 0.04
    static let secondaryGlyphSize: CGFloat = 11
    /// The heart draws a point larger: at the same size it read lighter
    /// than the mode glyphs beside it.
    static let heartGlyphSize: CGFloat = 12
    static let secondaryControlSide: CGFloat = 22

    /// The header's swaps between the track's text, the secondary controls
    /// and the volume slider, a cross-fade. Instant under Reduce Motion (hard rule 8).
    /// 0.22, up from 0.16: at that speed the fade read as a cut.
    static let headerSwapDuration: Double = 0.22
    /// How long the pointer may be off the player before the header falls
    /// back to the track's text. A hand crossing the panel drifts out and
    /// straight back; closing on the instant made the controls unusable
    /// (user, 2026-10-29).
    static let headerLeaveGrace: Duration = .milliseconds(500)
    /// The volume slider's track thickness, and the speaker glyphs at its
    /// two ends.
    static let volumeTrackHeight: CGFloat = 5
    static let volumeGlyphSize: CGFloat = 12
    static let volumeGlyphSpacing: CGFloat = 10
    /// VoiceOver's increment and decrement, in volume points.
    static let volumeAccessibilityStep = 5

}

/// Unused while the cross-screen morph is impossible (see
/// `MediaExpandedView.lyricsNamespace`). Kept beside the namespace it pairs
/// with so the two are re-adopted together, if ever.
///
/// A note for whoever revives this: it must NOT be applied to every line with
/// `isSource: distance == 0`. A non-source view's geometry is *set from* the
/// source's, so sharing one id across every line would collapse them onto the
/// active line's frame. Matching line-to-line across screens wants a per-line
/// id, each its own source.
private let activeLyricLineID = "activeLyricLine"

/// Shown beside other modules in the collapsed/standby row.
struct MediaCompactView: View {
    let module: MediaModule

    var body: some View {
        if let playing = module.nowPlaying, playing.hasContent {
            HStack(spacing: 5) {
                ArtworkThumb(image: module.artworkImage, side: 14, corner: 3)
                Text(playing.title ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: 90)
            }
        }
    }
}

/// The open-notch player: artwork on the left, titles with the scrub bar
/// directly beneath them beside it, transport controls below.
struct MediaExpandedView: View {
    let module: MediaModule

    /// **Currently inert — threaded through, used by nothing.** Kept only as
    /// scaffolding for a cross-screen morph that this architecture cannot
    /// support today.
    ///
    /// Investigated 2026-08-31: a `matchedGeometryEffect` needs both screens
    /// alive in one view tree within one transaction, and they never are.
    /// `toggleFullLyrics` reaches `NotchCoordinator.renderContent`, which
    /// calls `NotchPanel.setContent` and reassigns `hostingView.rootView`
    /// wholesale, rebuilding this view from a fresh
    /// `AnyView(MediaExpandedView(...))` each time. So this `@Namespace` is
    /// itself recreated on every swap — being declared in the parent rather
    /// than inside either screen buys nothing while the parent is rebuilt
    /// too. (Commit `ca3de5c` is independent evidence of that teardown: it
    /// had to add the `reveal:` guard because content swaps re-fired
    /// `RevealFromNotch`'s `onAppear`, which a preserved tree would not do.)
    ///
    /// Making the morph real means letting the panel's SwiftUI content own
    /// the swap instead of receiving pre-erased `AnyView`s from outside —
    /// the coordinator/panel seam, deliberately untouched.
    @Namespace private var lyricsNamespace

    var body: some View {
        // Group, not a bare switch, so `.animation(value:)` below applies to
        // whichever branch is showing rather than needing to be attached
        // separately to each one. The branch comes from the module's
        // `expandedScreen`, the same value the coordinator reads to decide
        // whether the panel opens chrome-only — the condition is not repeated
        // here.
        //
        // The `.transition`/`.animation` pair below cannot currently fire:
        // the swap arrives as a wholesale `rootView` reassignment from the
        // coordinator (see `lyricsNamespace` above), so this subtree is born
        // already showing the new branch rather than observing a change. Left
        // in place because it is correct in itself and is what the seam fix
        // would activate; it is not what makes the screens change today.
        Group {
            switch module.expandedScreen {
            case .fullLyrics:
                MediaFullLyricsView(module: module, namespace: lyricsNamespace)
                    .transition(.opacity)
            case .player(let playing):
                MediaPlayerScreen(module: module, playing: playing, namespace: lyricsNamespace)
                    .transition(.opacity)
            case .permissionDenied:
                // The tested denied path: one line, no re-prompt loop.
                HStack(spacing: NotchStyle.Spacing.s) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchStyle.Ink.tertiary)
                        .accessibilityHidden(true)
                    Text("Allow Astraea in System Settings → Privacy → Automation")
                        .font(NotchStyle.Font.caption)
                        .foregroundStyle(NotchStyle.Ink.secondary)
                }
            case nil:
                // Nothing to show. The coordinator reads the same nil and
                // opens the panel chrome-only, so this is never seen below
                // the neck band.
                EmptyView()
            }
        }
        // Scoped to this one value: a track changing, artwork loading, or
        // anything else read inside this subtree must not also animate under
        // this spring. Both directions — opening and closing — go through
        // this same modifier watching the same boolean, so neither can drift
        // out of sync with the other the way two separately-wrapped
        // `withAnimation` call sites could. Nil under Reduce Motion (hard
        // rule 8): the swap is instant.
        .animation(NotchStyle.motion(.easeInOut(duration: LyricsMotion.zoomTransitionDuration)),
                  value: module.showFullLyrics)
    }
}

/// The player screen, top to bottom: the header (artwork, the track's text
/// and lyric line, the "more" button), the scrub wave, the transport row
/// centred under it with elapsed and remaining time at its ends, then Up
/// Next. Its own view so `MediaExpandedView` stays a plain switch.
///
/// Compact (user, 2026-10-29: "expands too much"): the secondary controls
/// and the lyric line sit inside the artwork-tall header rather than on rows
/// of their own, and the time labels share the transport's row, so the
/// wave runs the full width. The lyric line arriving or leaving therefore
/// never changes the panel's height.
///
/// Up Next sits *below* everything on purpose. Its presence changes the
/// panel's height (`MediaModule.setUpNext` reflows), and the panel is
/// top-anchored: a row vanishing above the controls would pull them up and
/// out from under a cursor that just pressed Next. Below them, its leaving
/// moves only the bottom edge, past nothing the pointer is on.
private struct MediaPlayerScreen: View {
    let module: MediaModule
    let playing: NowPlaying
    let namespace: Namespace.ID

    /// Whether the pointer is over the player, with `headerLeaveGrace` of
    /// slack on the way out. Tracked here, over the whole screen, rather
    /// than on the header alone: the header's 56pt strip was too narrow to
    /// stay inside while reaching for its controls.
    @State private var pointerInside = false
    @State private var leaveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: PlayerLayout.sectionSpacing) {
            MediaPlayerHeader(module: module, playing: playing, namespace: namespace,
                              pointerInside: pointerInside)
            MediaProgressBar(module: module, isPlaying: playing.isPlaying)
            // Absent, not empty, when there is nothing to show — so its
            // arrival changes the panel's height, which is why
            // `MediaModule.setUpNext` reflows on presence. Only Music
            // ever answers; see `UpNextTrack`.
            if let next = module.upNext {
                MediaUpNextRow(next: next, accent: module.artworkAccent)
            }
        }
        .frame(width: PlayerLayout.width)
        .foregroundStyle(NotchStyle.Ink.primary)
        // The gaps between rows count as inside too.
        .contentShape(Rectangle())
        // The same hover tracking the header used, the one proven to fire
        // in this panel, which is never key.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                leaveTask?.cancel()
                leaveTask = nil
                pointerInside = true
            case .ended:
                leaveTask?.cancel()
                leaveTask = Task { @MainActor in
                    try? await Task.sleep(for: PlayerLayout.headerLeaveGrace)
                    guard !Task.isCancelled else { return }
                    pointerInside = false
                }
            }
        }
        .onDisappear { leaveTask?.cancel() }
    }
}

/// What the header shows beside the artwork.
private enum MediaHeaderMode {
    /// Title, artist and the lyric line.
    case track
    /// Shuffle, heart, volume and repeat, opened by the "more" button.
    case controls
    /// The volume slider, opened from `controls`.
    case volume
}

/// Artwork, then the track's text, then the "more" button, all at the
/// artwork's height. "More" swaps the text for the secondary controls, and
/// their volume button swaps those for a volume slider; either goes back to
/// the text when the pointer leaves the player (`MediaPlayerScreen`), or on
/// a second press of "more". Everything fits inside the header, so none of
/// it ever changes the panel's size.
private struct MediaPlayerHeader: View {
    let module: MediaModule
    let playing: NowPlaying
    let namespace: Namespace.ID
    /// Owned by `MediaPlayerScreen`, which tracks the whole player.
    let pointerInside: Bool

    @State private var mode: MediaHeaderMode = .track
    @State private var dragging = false

    private var hasSecondary: Bool {
        module.showsPlaybackModes || module.likedCurrent != nil || module.showsVolumeControl
    }

    /// `mode`, checked against what the source offers now: if the notch
    /// passes to the system source with the slider or controls open, they go.
    private var shownMode: MediaHeaderMode {
        switch mode {
        case .volume where !module.showsVolumeControl, .controls where !hasSecondary:
            return .track
        default:
            return mode
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchStyle.Spacing.m) {
            MediaPlayerArtwork(module: module, isPlaying: playing.isPlaying,
                               trackKey: MediaArtworkFlip.key(for: playing))
            HStack(spacing: NotchStyle.Spacing.s) {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hasSecondary {
                    MediaMoreButton(isOpen: shownMode != .track) {
                        setMode(shownMode == .track ? .controls : .track)
                    }
                }
            }
        }
        .frame(height: PlayerLayout.artworkSide)
        .onChange(of: pointerInside) { _, inside in
            // A drag that strays off keeps the slider until the release;
            // see below.
            if !inside && !dragging { setMode(.track) }
        }
    }

    /// Stacked, not laid out in a row: during a cross-fade the outgoing and
    /// incoming views both exist, and in a row they split the width and
    /// shove each other sideways instead of fading in place.
    private var content: some View {
        ZStack(alignment: .leading) {
            modeView
        }
    }

    @ViewBuilder
    private var modeView: some View {
        switch shownMode {
        case .track:
            MediaTrackText(module: module, playing: playing, namespace: namespace)
                .transition(.opacity)
        case .controls:
            MediaSecondaryControls(
                module: module,
                // The header's gap, then half the "more" button.
                originBeyondTrailing: NotchStyle.Spacing.s + PlayerLayout.secondaryControlSide / 2
            ) {
                if module.prepareVolumeSlider() { setMode(.volume) }
            }
            // In: no fade, the controls spring out themselves. Out: the
            // header's ordinary fade.
            .transition(.asymmetric(insertion: .identity, removal: .opacity))
        case .volume:
            MediaVolumeSlider(module: module) { isDragging in
                dragging = isDragging
                // Released after the pointer already left: the leave was
                // deferred for the drag, so honour it now.
                if !isDragging && !pointerInside { setMode(.track) }
            }
            .transition(.opacity)
        }
    }

    /// Instant under Reduce Motion (hard rule 8), a short cross-fade otherwise.
    private func setMode(_ next: MediaHeaderMode) {
        guard mode != next else { return }
        withAnimation(NotchStyle.motion(.easeInOut(duration: PlayerLayout.headerSwapDuration))) {
            mode = next
        }
    }
}

/// The header's "more" button, which opens and closes the secondary
/// controls. Brightened while open, so it reads as the way back.
private struct MediaMoreButton: View {
    let isOpen: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOpen ? "xmark" : "ellipsis")
                .font(.system(size: PlayerLayout.moreGlyphSize, weight: .semibold))
                .frame(width: PlayerLayout.secondaryControlSide,
                       height: PlayerLayout.secondaryControlSide)
        }
        .buttonStyle(NotchIconButtonStyle(size: PlayerLayout.secondaryControlSide))
        .help(isOpen ? "Hide controls" : "More controls")
        .accessibilityLabel(isOpen ? "Hide controls" : "More controls")
    }
}

/// Title, artist and the lyric line, stacked and centred on the artwork so
/// the header is the artwork's height whichever lines are present.
private struct MediaTrackText: View {
    let module: MediaModule
    let playing: NowPlaying
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: PlayerLayout.titleArtistSpacing) {
            VStack(alignment: .leading, spacing: PlayerLayout.titleArtistSpacing) {
                Text(playing.title ?? "—")
                    .font(PlayerLayout.titleFont)
                    .foregroundStyle(NotchStyle.Ink.primary)
                    .lineLimit(1)
                // No album line: many sources (browsers, system media) report
                // the artist as the album too, so it read as the artist twice
                // (user-reported 2026-10-29). The album stays on the lyrics
                // page, de-duplicated there.
                if let artist = playing.artist, !artist.isEmpty {
                    Text(artist)
                        .font(NotchStyle.Font.body)
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            MediaLyricsView(module: module, namespace: namespace)
        }
        // Bounded: the panel sizes itself to measured content; an
        // unbounded one-line title would balloon it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The visualiser's denied path on the player: enabled but not capturing,
/// which is almost always the System Audio Recording grant. Without it a
/// refused grant would look exactly like the feature being off.
///
/// Drawn over the top of the scrub wave, the thing it explains, which lies
/// flat without capture. Drawing only, so a scrub starting on the words
/// still lands on the bar beneath.
private struct MediaCaptureHint: View {
    let service: AudioVisualizerService

    var body: some View {
        if service.isEnabled, service.lastError != nil {
            Text("Allow System Audio Recording in Privacy & Security")
                .font(NotchStyle.Font.footnote)
                .foregroundStyle(NotchStyle.Ink.tertiary)
                .lineLimit(1)
                .allowsHitTesting(false)
        }
    }
}

/// The player screen's artwork. Tapping it brings the playing app forward
/// (`MediaModule.openPlayingApp`); with no known app it is not a button.
private struct MediaPlayerArtwork: View {
    let module: MediaModule
    let isPlaying: Bool
    /// The track's identity; a change flips the artwork over.
    let trackKey: String

    /// The artwork actually drawn, which lags the module's through the first
    /// half of a flip so the old cover turns away before the new one shows.
    /// Set on appear; nil only before that, when the module's own is drawn,
    /// so the first frame never shows an empty placeholder.
    @State private var shown: MediaArtworkFlip.Face?
    /// The track `shown` belongs to.
    @State private var shownKey: String?
    @State private var angle: Double = 0
    @State private var flipping = false
    /// Bumped by every flip, so a superseded flip's completions stand down
    /// when the user skips again mid-turn.
    @State private var generation = 0

    private var live: MediaArtworkFlip.Face {
        MediaArtworkFlip.Face(image: module.artworkImage, palette: module.artworkPalette)
    }

    var body: some View {
        let face = shown ?? live
        MediaArtworkTapTarget(module: module) {
            if let image = face.image {
                // Ken Burns drift, palette glow, and parallax tilt.
                ArtworkVisualizerView(
                    image: image,
                    palette: face.palette,
                    isPlaying: isPlaying,
                    cornerRadius: PlayerLayout.artworkCorner
                )
                .frame(width: PlayerLayout.artworkSide,
                       height: PlayerLayout.artworkSide)
            } else {
                ArtworkThumb(image: nil, side: PlayerLayout.artworkSide,
                             corner: PlayerLayout.artworkCorner)
            }
        }
        // About the vertical centre line, like a card turned over.
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0),
                          perspective: MediaArtworkFlip.perspective)
        .onAppear {
            shown = live
            shownKey = trackKey
        }
        .onChange(of: trackKey) { _, _ in flip() }
        .onChange(of: module.artworkImage) { _, _ in
            // Artwork that lands after the flip (a fetched cover) or with
            // no track change goes straight in. Mid-turn it waits: the
            // flip's midpoint takes whatever is newest. A key that has moved
            // on means this track's flip is about to start, so wait for it.
            guard !flipping, shownKey == trackKey else { return }
            shown = live
        }
    }

    /// Turn the old cover edge-on, swap, and turn the new one in.
    /// Instant under Reduce Motion (hard rule 8).
    private func flip() {
        let previous = shown ?? live
        shownKey = trackKey
        guard let half = NotchStyle.motion(.easeIn(duration: MediaArtworkFlip.halfDuration)) else {
            shown = live
            return
        }
        // Freeze what was on screen, not the module's: the new artwork may
        // arrive in the same update as the new title. `shown` only follows
        // the module's artwork while the track is unchanged (see above).
        shown = previous
        flipping = true
        generation &+= 1
        let current = generation
        withAnimation(half) {
            angle = 90
        } completion: {
            guard generation == current else { return }
            shown = live
            angle = -90
            withAnimation(.easeOut(duration: MediaArtworkFlip.halfDuration * 1.3)) {
                angle = 0
            } completion: {
                guard generation == current else { return }
                flipping = false
            }
        }
    }
}

/// The artwork's turn-over on a track change.
enum MediaArtworkFlip {
    /// What the artwork shows: the image and the glow drawn from it, swapped
    /// together so the glow never changes colour under the old cover.
    struct Face {
        let image: NSImage?
        let palette: ArtworkPalette?
    }

    /// Each half of the turn: away to edge-on, then (a little slower, so it
    /// lands softly) back in.
    static let halfDuration: Double = 0.17
    /// Enough depth that it reads as turning, not squashing.
    static let perspective: CGFloat = 0.5

    /// A track's identity. Title, artist and album together: a single
    /// field repeats across tracks too often (live albums, "Intro").
    static func key(for playing: NowPlaying) -> String {
        [playing.title, playing.artist, playing.album]
            .map { $0 ?? "" }
            .joined(separator: "\u{1F}")
    }
}

/// Wraps artwork in a button that opens the playing app, or leaves it inert
/// when no app is known — a control that cannot act must not look like one.
private struct MediaArtworkTapTarget<Label: View>: View {
    let module: MediaModule
    @ViewBuilder let label: () -> Label

    var body: some View {
        if module.artworkTapBundleID != nil {
            Button { module.openPlayingApp() } label: { label() }
                .buttonStyle(.plain)
                .help("Show the playing app")
                .accessibilityLabel("Show the playing app")
        } else {
            label()
        }
    }
}

/// Shuffle, the heart, volume and repeat: what the header's "more" button
/// opens in place of the track's text. Whichever the source offers, in a
/// fixed order, each centred in an equal share of the width so they spread
/// evenly across it (user, 2026-10-29) rather than bunching at one end.
///
/// They spring out sideways from the "more" button on appear, nearest
/// first, rather than fading in (user, 2026-10-29): each starts small at
/// the button's centre and settles into its slot on a relaxed spring.
/// Instant under Reduce Motion (hard rule 8).
private struct MediaSecondaryControls: View {
    let module: MediaModule
    /// How far past this view's trailing edge the "more" button's centre
    /// sits: where the controls spring out from.
    let originBeyondTrailing: CGFloat
    let openVolume: () -> Void

    @State private var sprung = false

    private enum Item: Hashable {
        case shuffle, heart, volume, repeatMode
    }

    private var items: [Item] {
        var items: [Item] = []
        if module.showsPlaybackModes { items.append(.shuffle) }
        // An absent heart must not still claim a share of the width.
        if module.likedCurrent != nil { items.append(.heart) }
        if module.showsVolumeControl { items.append(.volume) }
        if module.showsPlaybackModes { items.append(.repeatMode) }
        return items
    }

    var body: some View {
        let items = items
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(max(items.count, 1))
            HStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element) { index, item in
                    // From this slot's centre to the "more" button's.
                    let travel = geo.size.width - slot * (CGFloat(index) + 0.5)
                        + originBeyondTrailing
                    control(item)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(sprung ? 1 : PlayerLayout.secondarySpringScale)
                        .offset(x: sprung ? 0 : travel)
                        .animation(NotchStyle.motion(PlayerLayout.secondarySpring
                            .delay(Double(items.count - 1 - index) * PlayerLayout.secondarySpringStagger)),
                                   value: sprung)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { sprung = true }
    }

    @ViewBuilder
    private func control(_ item: Item) -> some View {
        switch item {
        case .shuffle:
            ModeControl(symbol: "shuffle", name: "Shuffle",
                        isOn: module.isShuffling,
                        accent: module.artworkAccent) { module.toggleShuffle() }
        case .heart:
            MediaFavoriteControl(module: module)
        case .volume:
            MediaVolumeButton(volume: module.volume, open: openVolume)
        case .repeatMode:
            ModeControl(symbol: "repeat", name: "Repeat",
                        isOn: module.isRepeating,
                        accent: module.artworkAccent) { module.toggleRepeat() }
        }
    }
}

/// Previous / play / next, centred under the wave.
private struct MediaTransportControls: View {
    let module: MediaModule
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: PlayerLayout.transportSpacing) {
            transportButton("backward.fill", label: "Previous track",
                            size: PlayerLayout.transportGlyphSize,
                            side: PlayerLayout.transportButtonSide) {
                module.send(.previousTrack)
            }
            transportButton(isPlaying ? "pause.fill" : "play.fill",
                            label: isPlaying ? "Pause" : "Play",
                            size: PlayerLayout.playGlyphSize,
                            side: PlayerLayout.playButtonSide) {
                module.send(.togglePlayPause)
            }
            transportButton("forward.fill", label: "Next track",
                            size: PlayerLayout.transportGlyphSize,
                            side: PlayerLayout.transportButtonSide) {
                module.send(.nextTrack)
            }
        }
        .fixedSize()
    }

    private func transportButton(_ symbol: String, label: String, size: CGFloat,
                                 side: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                // Set inside the label, so it wins over the style's quieter
                // resting tint: transport is the primary action.
                .foregroundStyle(NotchStyle.Ink.primary)
                .frame(width: side, height: side)
        }
        .buttonStyle(NotchIconButtonStyle(size: side))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The favourite heart, in one of two modes decided by the *source*, not by
/// this view.
///
/// Apple Music's `favorited` is read-write, so it is a real toggle. A source
/// that can report a favourite but not change it renders the heart as state
/// rather than as a control, taking no clicks at all. Spotify reports none
/// (`starred` is unimplemented), so it shows no heart.
///
/// Hidden entirely when there is no value to show, which is what a denied
/// Automation prompt looks like. A greyed-out heart of unknown truth is
/// worse than no heart.
private struct MediaFavoriteControl: View {
    let module: MediaModule

    private var isOn: Bool { module.likedCurrent == true }

    var body: some View {
        if module.likedCurrent != nil {
            if module.canToggleFavorite {
                Button { module.toggleLike() } label: { heart }
                    .buttonStyle(NotchIconButtonStyle(size: PlayerLayout.secondaryControlSide))
                    .help(isOn ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel("Favorite")
                    .accessibilityValue(isOn ? "On" : "Off")
            } else {
                // Display-only: no Button, and hit testing off so the click
                // falls through to the panel instead of landing on a dead
                // control. Dimmed so it does not read as pressable.
                heart
                    .foregroundStyle(NotchStyle.Ink.secondary)
                    .opacity(0.55)
                    .allowsHitTesting(false)
                    .accessibilityLabel(isOn ? "Starred" : "Not starred")
            }
        }
    }

    /// Tinted only when on; off, it takes the icon style's resting and hover
    /// tints like the other secondary controls.
    @ViewBuilder
    private var heart: some View {
        let glyph = Image(systemName: isOn ? "heart.fill" : "heart")
            .font(.system(size: PlayerLayout.heartGlyphSize, weight: .semibold))
            .frame(width: PlayerLayout.secondaryControlSide, height: PlayerLayout.secondaryControlSide)
            .contentShape(Rectangle())
        if isOn {
            glyph.foregroundStyle(module.artworkAccent ?? .mediaAccent)
        } else {
            glyph
        }
    }
}

/// The next track in the player's queue: one line, label then title then
/// artist, under the scrub wave. A plain line rather than a card: the card's
/// padding was height the page could not spare (user, 2026-10-29).
///
/// Information, not a control — nothing here is clickable. No transition or
/// animation of its own: appearing or leaving reflows the panel through the
/// coordinator, which already applies the Reduce Motion rule (hard rule 8).
private struct MediaUpNextRow: View {
    let next: UpNextTrack
    let accent: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NotchStyle.Spacing.s) {
            Text("Up Next")
                .font(NotchStyle.Font.section)
                .foregroundStyle(accent ?? .mediaAccent)
            Text(next.title)
                .font(NotchStyle.Font.captionEmphasis)
                .foregroundStyle(NotchStyle.Ink.primary)
                .lineLimit(1)
                // The artist truncates first; the title is the answer.
                .layoutPriority(1)
            // Music may leave the artist blank; the title alone still stands.
            if !next.artist.isEmpty {
                Text(next.artist)
                    .font(NotchStyle.Font.caption)
                    .foregroundStyle(NotchStyle.Ink.secondary)
                    .lineLimit(1)
            }
        }
        // Bounded, like the titles above: a long name truncates rather than
        // widening the panel.
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(next.artist.isEmpty
                            ? "Up next: \(next.title)"
                            : "Up next: \(next.title) by \(next.artist)")
    }
}

/// Shuffle or repeat, as a two-state toggle.
///
/// Two states only. Spotify's `repeating` is a Boolean in its scripting
/// dictionary — there is no off/all/one to read — so rendering a third state
/// would be showing something no source can answer.
///
/// The same `secondaryControlSide` frame as `MediaFavoriteControl`, inside
/// the header's fixed height, so neither can change the panel's size.
/// On wears the accent; off takes the icon style's quiet resting tint.
private struct ModeControl: View {
    let symbol: String
    let name: String
    let isOn: Bool
    let accent: Color?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            glyph
        }
        .buttonStyle(NotchIconButtonStyle(size: PlayerLayout.secondaryControlSide))
        .help("\(name) \(isOn ? "On" : "Off")")
        .accessibilityLabel("\(symbol) \(isOn ? "on" : "off")")
    }

    @ViewBuilder
    private var glyph: some View {
        let image = Image(systemName: symbol)
            .font(.system(size: PlayerLayout.secondaryGlyphSize, weight: .semibold))
            .frame(width: PlayerLayout.secondaryControlSide, height: PlayerLayout.secondaryControlSide)
        if isOn {
            image.foregroundStyle(accent ?? .mediaAccent)
        } else {
            image
        }
    }
}

/// The volume button, in the header's secondary row. Sized and tinted like
/// the shuffle and repeat buttons at rest (`secondaryGlyphSize` in the
/// shared `secondaryControlSide` frame, the icon style's resting tint).
///
/// A speaker, slashed at zero. It was `slider.horizontal.3` for a day, until
/// the mixer door took that glyph and the two read as one control twice
/// over (2026-09-18): the door is every app's volume, this is one player's.
/// The level itself lives in the slider it opens and the VoiceOver value.
private struct MediaVolumeButton: View {
    let volume: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.3")
                .font(.system(size: PlayerLayout.secondaryGlyphSize, weight: .semibold))
                .frame(width: PlayerLayout.secondaryControlSide, height: PlayerLayout.secondaryControlSide)
        }
        .buttonStyle(NotchIconButtonStyle(size: PlayerLayout.secondaryControlSide))
        .help("Volume")
        .accessibilityLabel("Volume")
        .accessibilityValue(volume.map { "\($0) percent" } ?? "")
    }
}

/// The volume slider that stands in for the header's text and controls.
///
/// Drawn like the rest of the player rather than as a system `Slider`: a
/// thin track filled with the artwork accent, between a quiet and a loud
/// speaker glyph. The row's full height is the hit area and a click anywhere
/// on the track jumps there, the scrub bar's model and its geometry. No
/// knob, for the same reason the scrub bar has no playhead dot (tried,
/// user-rejected).
private struct MediaVolumeSlider: View {
    let module: MediaModule
    let onDraggingChanged: (Bool) -> Void

    @State private var dragging = false

    private var accent: Color { module.artworkAccent ?? .mediaAccent }
    private var fraction: CGFloat { CGFloat(module.volume ?? 0) / 100 }

    var body: some View {
        HStack(spacing: PlayerLayout.volumeGlyphSpacing) {
            endGlyph("speaker.fill")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(NotchStyle.Fill.selected)
                    Capsule().fill(accent).frame(width: geo.size.width * fraction)
                }
                .frame(height: PlayerLayout.volumeTrackHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(width: geo.size.width))
            }
            endGlyph("speaker.wave.3.fill")
        }
        .padding(.horizontal, NotchStyle.Spacing.xs)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(module.volume ?? 0) percent")
        .accessibilityAdjustableAction { direction in
            let step: Int
            switch direction {
            case .increment: step = PlayerLayout.volumeAccessibilityStep
            case .decrement: step = -PlayerLayout.volumeAccessibilityStep
            @unknown default: return
            }
            module.beginVolumeEdit()
            module.setVolume((module.volume ?? 0) + step)
            module.endVolumeEdit()
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    module.beginVolumeEdit()
                    onDraggingChanged(true)
                }
                module.setVolume(PlayerVolume.value(atFraction:
                    ScrubGeometry.fraction(atX: value.location.x, width: width)))
            }
            .onEnded { value in
                module.setVolume(PlayerVolume.value(atFraction:
                    ScrubGeometry.fraction(atX: value.location.x, width: width)))
                module.endVolumeEdit()
                dragging = false
                onDraggingChanged(false)
            }
    }

    private func endGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: PlayerLayout.volumeGlyphSize, weight: .semibold))
            .foregroundStyle(NotchStyle.Ink.tertiary)
    }
}

/// The scrub bar and the transport: the spectrum wave across the full
/// width, and beneath it previous / play / next, centred, with elapsed and
/// remaining time at the row's two ends. It advances once a second while
/// the panel is open; dragging scrubs and releases into a seek, and the
/// elapsed label follows the finger while it does. The 1s tick exists only
/// while this view does, i.e. only while the notch is expanded.
///
/// A track with no duration (a live stream) has no wave and no times, but
/// keeps the transport.
private struct MediaProgressBar: View {
    let module: MediaModule
    let isPlaying: Bool

    /// Artwork-derived (never black by construction), peach fallback.
    private var accent: Color { module.artworkAccent ?? .mediaAccent }

    /// Non-nil while the user is dragging: their finger owns the bar and
    /// live updates keep off it until release.
    @State private var scrubFraction: Double?

    var body: some View {
        let snapshot = module.nowPlaying
        let duration = snapshot?.duration ?? 0
        // The test `MediaModule.drawsSpectrum` makes, so capture runs only
        // while the wave exists.
        if snapshot?.hasDuration == true {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = scrubFraction.map { $0 * duration }
                    ?? min(snapshot?.elapsedNow(at: context.date) ?? 0, duration)
                let scrubbing = scrubFraction != nil
                VStack(spacing: PlayerLayout.waveTransportSpacing) {
                    track(fraction: duration > 0 ? elapsed / duration : 0,
                          elapsed: elapsed, duration: duration)
                    ZStack {
                        HStack(spacing: 0) {
                            MediaTimeLabel(text: PlaybackTime.string(elapsed),
                                           alignment: .leading, isScrubbing: scrubbing)
                            Spacer(minLength: 0)
                            MediaTimeLabel(text: "−" + PlaybackTime.string(
                                                max(0, duration.rounded(.down) - elapsed.rounded(.down))),
                                           alignment: .trailing, isScrubbing: scrubbing)
                        }
                        MediaTransportControls(module: module, isPlaying: isPlaying)
                    }
                }
            }
        } else {
            MediaTransportControls(module: module, isPlaying: isPlaying)
        }
    }

    /// The bar is the spectrum wave: full width at all times, accent left of
    /// the playhead and grey right of it. With no spectrum it lies flat, a
    /// plain progress bar. See `AudioVisualizerSpectrumView`.
    private func track(fraction: Double, elapsed: TimeInterval,
                       duration: TimeInterval) -> some View {
        GeometryReader { geo in
            AudioVisualizerSpectrumView(service: module.visualizer,
                                        accent: accent,
                                        progress: fraction)
                // Drawing only. The taper thins the wave toward both
                // ends, so its shape must never decide where a click
                // lands.
                .allowsHitTesting(false)
                .frame(width: geo.size.width, height: geo.size.height)
                .accessibilityValue("\(PlaybackTime.string(elapsed)) of \(PlaybackTime.string(duration))")
                // The hit area: edge to edge, and taller than the row at both
                // edges, whatever the wave looks like — see
                // `ScrubGeometry.hitOverhang`. An overlay rather than a
                // sibling in a stack: an overlay is sized by the row, so the
                // overhang cannot feed back into the row's own height. No
                // playhead dot (tried, user-rejected); the whole row drags, so
                // a handle was decoration.
                .overlay {
                    Color.clear
                        .frame(height: ScrubGeometry.hitHeight(rowHeight: geo.size.height))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    scrubFraction = ScrubGeometry.fraction(atX: value.location.x,
                                                                           width: geo.size.width)
                                }
                                .onEnded { value in
                                    let f = ScrubGeometry.fraction(atX: value.location.x,
                                                                   width: geo.size.width)
                                    module.seek(to: f * duration)
                                    // The adapter publishes the jump optimistically,
                                    // so the bar holds position on release.
                                    scrubFraction = nil
                                }
                        )
                }
                .overlay(alignment: .top) {
                    if let visualizer = module.visualizer {
                        MediaCaptureHint(service: visualizer)
                    }
                }
        }
        // Tall enough for the wave to read as a wave. The row's height is
        // fixed whatever the wave does, so the panel never breathes with it.
        .frame(height: SpectrumEnvelope.maxHeight)
    }
}

/// Elapsed and remaining, at the two ends of the transport row. Monospaced
/// digits and a minimum width so the labels never jitter as they count.
/// Drawing only: a label must never take a click meant for the scrub bar
/// above it.
private struct MediaTimeLabel: View {
    let text: String
    let alignment: Alignment
    let isScrubbing: Bool

    var body: some View {
        Text(text)
            .font(PlayerLayout.timeFont)
            .monospacedDigit()
            .fixedSize()
            .frame(minWidth: PlayerLayout.timeLabelMinWidth, alignment: alignment)
            // Brightens while the finger owns the bar, so the label reads as
            // the scrub's readout.
            .foregroundStyle(isScrubbing ? NotchStyle.Ink.primary : NotchStyle.Ink.tertiary)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// `m:ss`, or `h:mm:ss` from an hour up, like every Apple player.
private enum PlaybackTime {
    static func string(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// Where a click on the scrub bar lands, as a fraction of the track.
///
/// Linear across the row's full width, edge to edge: the wave's taper is
/// drawing only, so nothing at either end is set aside and a drag one point
/// from the edge moves exactly as far as one in the middle. Pure, so that is
/// a test rather than a reading of the gesture.
enum ScrubGeometry {

    /// How far the grab zone reaches past the row, above and below.
    ///
    /// The drawn bar is as little as `SpectrumEnvelope.minHeight` of the row's
    /// `SpectrumEnvelope.maxHeight`, and the row itself was the whole hit
    /// target, so a miss by a few points landed on nothing. Eight points each
    /// way stays inside the `PlayerLayout.sectionSpacing` gap above the row,
    /// short of the header, and inside the `PlayerLayout.waveTransportSpacing`
    /// gap below it, short of the transport buttons. Both
    /// states get it: a tall wave is no easier to hit at its thin ends than
    /// the flat bar is anywhere.
    nonisolated static let hitOverhang: CGFloat = 8

    /// The grab zone's height for a row of `rowHeight`.
    nonisolated static func hitHeight(rowHeight: CGFloat) -> CGFloat {
        rowHeight + 2 * hitOverhang
    }

    nonisolated static func fraction(atX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width)))
    }
}

/// The line being sung, under the scrub bar's time labels in a dimmed
/// accent, a step quieter than the title and artist. Absent entirely (no
/// reserved space) when the track has no synced lyrics. The half-second tick exists only while this view does.
///
/// One line at a time. When the active line changes, the outgoing line fades
/// out and the incoming one fades in, in place, fast enough to read as a swap.
/// Instant under Reduce Motion (hard rule 8). Before the first timestamp a ♪
/// stands in, and hands over to the opening line the same way.
///
/// Was a three-line ticker that rolled every line up one step on a spring,
/// positioned by its distance from the active line. That roll depended on
/// each line keeping one identity for its whole life on screen, because a
/// replaced view cross-dissolves instead of moving. The cross-fade is now the
/// point, so the line's identity is deliberately its index.
private struct MediaLyricsView: View {
    let module: MediaModule
    let namespace: Namespace.ID

    /// The area's full height, used both by the ticker and by the placeholder
    /// that holds the space while a lookup runs. One constant so the two can
    /// never disagree — a mismatch here would resize the panel by the
    /// difference and reintroduce the collapse this reservation prevents.
    static let reservedHeight: CGFloat = LyricsMotion.tickerLineHeight

    /// nil under Reduce Motion makes the swap instant (hard rule 8).
    private var crossfade: Animation? {
        NotchStyle.motion(.easeInOut(duration: LyricsMotion.tickerCrossfadeDuration))
    }

    var body: some View {
        if module.lyrics?.isEmpty == false {
            ticker
        } else if module.lyricsReserved {
            // Holding the line, not showing anything: the outgoing track
            // had lyrics and the incoming track's lookup is still running.
            // Without this the header's text jumps down and back up.
            Color.clear.frame(height: Self.reservedHeight)
        }
    }

    @ViewBuilder
    private var ticker: some View {
        if let lines = module.lyrics, !lines.isEmpty {
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                let elapsed = module.nowPlaying?.elapsedNow(at: context.date) ?? 0
                // -1 before the first timestamp, while the ♪ run-in shows.
                let active = LyricsParser.currentIndex(at: elapsed, in: lines) ?? -1
                // Tapping the line opens the full-lyrics takeover.
                Button { module.toggleFullLyrics() } label: {
                    currentLine(lines: lines, active: active)
                }
                .buttonStyle(.plain)
                .help("Show full lyrics")
                .accessibilityHint("Shows the full lyrics")
                .animation(crossfade, value: active)
            }
            .frame(height: Self.reservedHeight)
        }
    }

    /// The active line, identified by its index. A new index is a new view,
    /// so SwiftUI removes the old line and inserts the new one, and the
    /// opacity transition turns that into the cross-fade. Both sit in the
    /// one `ZStack`, so for the length of the fade they overlap in place
    /// rather than stacking.
    private func currentLine(lines: [LyricsLine], active: Int) -> some View {
        ZStack {
            Text(lines.indices.contains(active) ? lines[active].text : "♪")
                .font(.system(size: LyricsMotion.tickerFontSize, weight: .medium))
                .foregroundStyle(accent.opacity(LyricsMotion.tickerAccentOpacity))
                .lineLimit(1)
                .id(active)
                .transition(.opacity)
        }
        // Leading, under the artist: the line is part of the track's text.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var accent: Color { module.artworkAccent ?? Color.mediaAccent }
}

/// The full-lyrics takeover: a slim song badge on top, the rolling lines
/// beneath it. The same width as the player, so opening it only changes the
/// panel's height.
struct MediaFullLyricsView: View {
    let module: MediaModule
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.m) {
            MediaLyricsBadge(module: module)

            if let lines = module.lyrics, !lines.isEmpty {
                MediaFullLyricsLines(lines: lines, module: module, namespace: namespace)
                    .frame(height: LyricsMotion.fullPageHeight)
                    .mask(
                        // Fade the edges so lines melt in and out.
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0),
                                    .init(color: .black, location: 0.16),
                                    .init(color: .black, location: 0.84),
                                    .init(color: .clear, location: 1)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
        }
        .frame(width: PlayerLayout.width)
        .foregroundStyle(NotchStyle.Ink.primary)
    }
}

/// The takeover's song badge: back button, small artwork, then the title
/// over "artist · album". Every line truncates rather than widening the panel.
private struct MediaLyricsBadge: View {
    let module: MediaModule

    /// Artist and album on one quieter line; either may be missing. An album
    /// that only repeats the artist, as browser and system sources often
    /// report it, is dropped rather than shown as "Artist · Artist".
    private var subtitle: String {
        let artist = module.nowPlaying?.artist ?? ""
        let album = module.nowPlaying?.album ?? ""
        let repeats = album.compare(artist, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        return [artist, repeats ? "" : album]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotchStyle.Spacing.s) {
            Button { module.toggleFullLyrics() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(NotchStyle.Ink.primary)
            }
            .buttonStyle(NotchIconButtonStyle(size: 26))
            // A resting fill under the style's hover fill, so the way back
            // reads as a button before the pointer finds it.
            .background(Circle().fill(NotchStyle.Fill.card))
            .help("Back to player")
            .accessibilityLabel("Back to player")
            MediaArtworkTapTarget(module: module) {
                ArtworkThumb(image: module.artworkImage, side: 36, corner: NotchStyle.Radius.control)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(module.nowPlaying?.title ?? "")
                    .font(NotchStyle.Font.bodyEmphasis)
                    .foregroundStyle(NotchStyle.Ink.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NotchStyle.Font.caption)
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
    }
}

/// The full-lyrics page's line stack.
///
/// Was a `ScrollViewReader` + `proxy.scrollTo(_:anchor:)` inside
/// `withAnimation`: `scrollTo` snaps to an anchor rather than travelling
/// continuously, which is why line changes read as a series of small jumps
/// rather than one roll. Replaced with a roll by offset (the player's ticker
/// used the same technique while it showed three lines): every line has a
/// stable identity (`.id(index)` — the array itself does not
/// reorder or get rebuilt mid-track, so index is a valid identity for the
/// duration of a track), and each line's vertical position is an `.offset`
/// computed purely from its distance to the active line, moved by one shared
/// spring. A spring interpolates every displayed frame regardless of how
/// often the driving state changes, so the motion is continuous even though
/// `active` itself only updates on the underlying `TimelineView`'s 0.5s tick.
///
/// Renders every line, unwindowed. The full page is a few dozen lines shown
/// occasionally, so there is no cost to keeping all of them present and
/// letting offset and opacity carry the ones far from centre out of view.
/// Nothing ever joins or leaves the `ForEach`, so no line can pop in at the
/// edge of a window, and the fade can be a genuinely continuous function of
/// distance.
/// The full lyrics page's vertical geometry, pulled out of the view so it can
/// be tested — it is exactly the "given sizes, does the position land where it
/// should" question CLAUDE.md says to test rather than eyeball.
///
/// The page cannot use a flat step per line: its lines wrap, so a two-line
/// lyric needs two lines of room. Positions here are therefore
/// cumulative sums of real measured heights.
enum LyricsLayout {

    /// Height the text will occupy once wrapped at `width`, unscaled.
    ///
    /// Measured through AppKit rather than a SwiftUI `GeometryReader` +
    /// `PreferenceKey`: this is synchronous, so the very first frame is
    /// already positioned correctly. The preference route only learns each
    /// height a layout pass *after* it is needed, which would stack every
    /// line at centre on open and spring them apart once the measurements
    /// landed.
    static func renderedHeight(of text: String,
                               wrappingAt width: CGFloat,
                               fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        // An empty lyric line (instrumental break) still occupies a row.
        let measured = text.isEmpty ? " " : text
        let bounds = NSAttributedString(string: measured, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// Centre-to-centre distance from the active line to `index`, positive
    /// downward.
    ///
    /// Half of each end line plus everything whole in between, so the active
    /// line's scale genuinely **pushes neighbours apart**: it enters the sum
    /// as `height * activeScale`, which `scaleEffect` alone could never do
    /// because it does not participate in layout at all.
    static func offset(for index: Int,
                       active: Int,
                       heights: [CGFloat],
                       activeScale: CGFloat,
                       gap: CGFloat,
                       fallback: CGFloat) -> CGFloat {
        guard index != active else { return 0 }
        let lower = min(index, active)
        let upper = max(index, active)

        func displayed(_ i: Int) -> CGFloat {
            // `active` is -1 before the first timestamp; that phantom row is
            // off the end of the array and takes the fallback, which keeps
            // line 0 sitting one slot below centre exactly as before.
            guard heights.indices.contains(i) else { return fallback }
            return heights[i] * (i == active ? activeScale : 1)
        }

        var distance = displayed(lower) / 2
            + displayed(upper) / 2
            + gap * CGFloat(upper - lower)
        if upper - lower > 1 {
            for j in (lower + 1)..<upper { distance += displayed(j) }
        }
        return index > active ? distance : -distance
    }
}

private struct MediaFullLyricsLines: View {
    let lines: [LyricsLine]
    let module: MediaModule
    let namespace: Namespace.ID

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var lineSpring: Animation? {
        reduceMotion ? nil : LyricsMotion.lineSpring
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let elapsed = module.nowPlaying?.elapsedNow(at: context.date) ?? 0
            // Same lookup the ticker uses (LyricsParser.currentIndex), not a
            // second hand-rolled `lastIndex` search — the two screens must
            // agree on which line is active down to the same index, or the
            // matchedGeometryEffect they share tries to morph between two
            // different lines the instant the takeover opens.
            let active = LyricsParser.currentIndex(at: elapsed, in: lines) ?? -1
            GeometryReader { geo in
                // Divided by the active scale, so the ONE line that gets
                // scaled still lands inside the panel: it wraps at this
                // width, then `scaleEffect` multiplies it back up to exactly
                // `geo.width - 2 * padding`. Every line wraps at the same
                // width, active or not — a width that changed with active
                // state would reflow the text mid-transition and change its
                // height under the spring.
                let wrapWidth = max(40, (geo.size.width - LyricsMotion.fullPageSidePadding * 2)
                                    / LyricsMotion.fullPageActiveScale)
                let heights = lines.map {
                    LyricsLayout.renderedHeight(of: $0.text,
                                                wrappingAt: wrapWidth,
                                                fontSize: LyricsMotion.fullPageFontSize)
                }
                ZStack {
                    ForEach(lines.indices, id: \.self) { index in
                        line(lines[index].text,
                             distance: index - active,
                             wrapWidth: wrapWidth,
                             offsetY: LyricsLayout.offset(
                                for: index,
                                active: active,
                                heights: heights,
                                activeScale: LyricsMotion.fullPageActiveScale,
                                gap: LyricsMotion.fullPageLineGap,
                                fallback: LyricsMotion.fullPageFallbackLineHeight))
                    }
                }
                // Fills the reader so the stack stays centred; GeometryReader
                // is top-leading by default.
                .frame(width: geo.size.width, height: geo.size.height)
                .animation(lineSpring, value: active)
            }
        }
    }

    /// **One unconditional chain, deliberately.** A `@ViewBuilder` `if/else`
    /// here compiles to `_ConditionalContent`, whose branches are distinct
    /// view types. A line crossing into or out of `distance == 0` would switch
    /// branches, so SwiftUI would destroy it and insert a different view —
    /// a fade — instead of animating the one it had. Every line keeps one
    /// identity for its whole life on screen, and its appearance comes only
    /// from modifiers whose values change.
    private func line(_ text: String, distance: Int,
                      wrapWidth: CGFloat, offsetY: CGFloat) -> some View {
        let magnitude = abs(distance)
        // One base size scaled, never two sizes swapped: a font-size change
        // does not interpolate between values, a scaleEffect does. The old
        // code's direct `size: index == currentIndex ? 25 : 20` jumped.
        //
        // `.frame(width:)`, not `maxWidth: .infinity`: the scale below is
        // applied AFTER layout, so a line laid out at full panel width was
        // then multiplied past the panel's edges and clipped on both sides.
        // Wrapping at the pre-scaled width is what keeps it inside.
        return Text(text)
            .font(.system(size: LyricsMotion.fullPageFontSize, weight: .bold))
            .foregroundStyle(magnitude == 0
                ? (module.artworkAccent ?? .mediaAccent)
                : NotchStyle.Ink.tertiary)
            .multilineTextAlignment(.center)
            .frame(width: wrapWidth)
            .scaleEffect(magnitude == 0 ? LyricsMotion.fullPageActiveScale : 1)
            .opacity(fadeOpacity(magnitude: magnitude))
            // Same animated offset under the same spring as before; only the
            // value it is given changed, from a flat step to measured.
            .offset(y: offsetY)
    }

    /// Continuous — safe because nothing is windowed; see this type's own doc
    /// comment.
    private func fadeOpacity(magnitude: Int) -> Double {
        magnitude == 0 ? 1 : max(0, 1 - Double(magnitude) * LyricsMotion.fadePerLine)
    }
}

/// Left wing: album art beside the housing.
struct MediaWingArtwork: View {
    let module: MediaModule

    var body: some View {
        // Intrinsic size only: the wing slot's alignment decides placement.
        // User-tuned: a minuscule up-and-right from center.
        ArtworkThumb(image: module.artworkImage, side: 22, corner: 5)
            .offset(x: 2, y: -1)
    }
}

/// Right wing: a small animated waveform while playing, still while paused —
/// and still under Reduce Motion, which is honoured by never building the
/// animated bars at all rather than by animating them to rest.
///
/// Decorative for now — bars move on time, not on real amplitude; the honest
/// upgrade is the audio-capture feature behind its permission.
///
/// Not a `TimelineView`: this panel can never become key (hard rule 3), and
/// SwiftUI throttles TimelineView callbacks in non-key windows — two rounds
/// of user-visible stutter proved it.
///
/// **The animated bars exist only while playing.** `repeatForever` here is a
/// SwiftUI animation, evaluated on the main thread every display refresh, not
/// a Core Animation repeat in the render server — and it never terminates. A
/// later `withAnimation` cannot retract it; it is combined with the running
/// repeat instead. So pausing must remove the views that own the animation.
/// Keeping them and animating them to rest left the notch re-rendering every
/// frame indefinitely, with four more repeats stacked on every play. See
/// PROJECT-CONTEXT.md, *Performance findings*.
struct MediaWingWaveform: View {
    let module: MediaModule

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Animated bars only when they may actually move. Under Reduce Motion
    /// the resting bars stand in, so no `WaveBar` is ever created and no
    /// `repeatForever` starts (hard rule 8) — the same reason pausing swaps
    /// the views out rather than animating them to rest.
    private var animatesBars: Bool {
        module.nowPlaying?.isPlaying == true && !reduceMotion
    }

    var body: some View {
        let accent = module.artworkAccent ?? .mediaAccent
        HStack(spacing: 2.5) {
            if animatesBars {
                ForEach(0..<4, id: \.self) { index in
                    WaveBar(index: index, color: accent)
                }
            } else {
                ForEach(0..<4, id: \.self) { _ in
                    RestingWaveBar(color: accent)
                }
            }
        }
        // Fixed height so bars grow around their center instead of pushing
        // the row's layout; intrinsic width so alignment places it.
        .frame(height: 14)
        .shadow(color: accent.opacity(0.5), radius: 3)
    }
}

/// One animated bar. Only ever alive while playing — see `MediaWingWaveform`.
private struct WaveBar: View {
    let index: Int
    let color: Color

    @State private var lifted = false

    var body: some View {
        Capsule()
            .fill(color.opacity(0.95))
            .frame(width: 2.5, height: lifted ? 12 : 5)
            .onAppear {
                // Speed matches the user-approved tempo. Distinct duration
                // and start delay per bar keep them from ever syncing up.
                withAnimation(
                    .easeInOut(duration: 0.45 + Double(index) * 0.08)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.13)
                ) {
                    lifted = true
                }
            }
    }
}

/// The paused bar: the same capsule at rest, with no state to animate.
private struct RestingWaveBar: View {
    let color: Color

    var body: some View {
        Capsule()
            .fill(color.opacity(0.95))
            .frame(width: 2.5, height: 4)
    }
}

/// Album art, or a placeholder note while it loads.
///
/// Takes the module's already-decoded `artworkImage`, never raw bytes: a
/// decode in `body` ran on every render of every place the thumb appears.
private struct ArtworkThumb: View {
    let image: NSImage?
    let side: CGFloat
    let corner: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.45))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
