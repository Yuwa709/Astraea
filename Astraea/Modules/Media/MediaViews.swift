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

    /// The home <-> full-lyrics screen swap.
    static let zoomTransitionDuration: Double = 0.38
}

/// The player screen's spacing and control sizes, in one place so they can be
/// retuned without hunting through `MediaExpandedView`.
private enum PlayerLayout {
    /// Gap between the header, the lyric line, and the controls row.
    static let sectionSpacing: CGFloat = 14

    /// Heights of the title (17pt semibold) and artist (13pt) rows, measured
    /// 2026-09-16. Not enforced by layout — they only size the artwork.
    static let titleLineHeight: CGFloat = 20
    static let artistLineHeight: CGFloat = 16
    static let titleArtistSpacing: CGFloat = 2
    /// Artist line to the wave. Was 6; now the same as `titleArtistSpacing`
    /// so the right-hand column reads as one block with one rhythm. Most of
    /// the gap still visible above the wave at quiet levels is the wave's
    /// own headroom: it grows up from the row's base, so this is not the
    /// lever for that — `SpectrumEnvelope.maxHeight` is.
    static let artistWaveSpacing: CGFloat = 2
    /// The artwork is exactly as tall as the column beside it, so its bottom
    /// edge and the wave's base line up. Derived, so retuning any term above
    /// cannot leave the two misaligned.
    static let artworkSide: CGFloat = titleLineHeight + titleArtistSpacing
        + artistLineHeight + artistWaveSpacing + SpectrumEnvelope.maxHeight

    /// Glyph sizes. Shuffle and repeat are modes, not actions, so they draw
    /// a clear step below the transport glyphs.
    static let transportGlyphSize: CGFloat = 20
    static let playGlyphSize: CGFloat = 26
    static let modeGlyphSize: CGFloat = 13
    /// Shuffle and repeat when off, and the volume button at rest: the same
    /// quiet tint, so the three secondary controls read as one family.
    static let modeRestingOpacity: Double = 0.55
    /// Transport hit targets. The row's height is this, not the glyphs'.
    static let transportButtonWidth: CGFloat = 40
    static let transportButtonHeight: CGFloat = 32
    /// Frame-to-frame gap inside previous / play / next: centre-to-centre
    /// 46pt (was 96).
    static let transportSpacing: CGFloat = 6
    /// Gap from shuffle to previous, and from next to repeat. Wider than
    /// `transportSpacing` so the modes read as flanking the transport rather
    /// than as two more of it. The whole cluster is 228pt, centred (was
    /// spread across the full 368pt).
    static let modeSpacing: CGFloat = 20

    /// The heart's glyph, at the controls row's leading edge.
    static let edgeGlyphSize: CGFloat = 15
    /// The frame of the controls at the row's two edges: the heart, and the
    /// volume button opposite it. The same 28pt as shuffle and repeat, so the
    /// row stays at `transportButtonHeight`.
    static let edgeControlSide: CGFloat = 28

    /// The swap between the transport cluster and the volume slider, a
    /// cross-fade. Instant under Reduce Motion (hard rule 8).
    static let volumeSwapDuration: Double = 0.16
    /// The volume slider's track thickness, and the speaker glyphs at its
    /// two ends. The slider lives inside `transportButtonHeight`, so none of
    /// these can change the panel's size.
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
                Text("Allow Astraea in System Settings → Privacy → Automation")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
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
        .animation(reduceMotion ? nil : .easeInOut(duration: LyricsMotion.zoomTransitionDuration),
                  value: module.showFullLyrics)
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The player screen: artwork on the left, titles with the scrub bar
/// directly beneath them beside it, then Up Next, the lyric line and the
/// controls. Its own view so `MediaExpandedView` stays a plain switch.
private struct MediaPlayerScreen: View {
    let module: MediaModule
    let playing: NowPlaying
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: PlayerLayout.sectionSpacing) {
            HStack(alignment: .top, spacing: 12) {
                MediaPlayerArtwork(module: module, isPlaying: playing.isPlaying)
                // Everything right of the artwork is one column: titles
                // (and the trailing hint) on top, the scrub bar directly
                // beneath them, spanning from the artwork's edge to the
                // panel's. The bar is no longer its own full-width row
                // below the header.
                VStack(alignment: .leading, spacing: PlayerLayout.artistWaveSpacing) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: PlayerLayout.titleArtistSpacing) {
                            Text(playing.title ?? "—")
                                .font(.system(size: 17, weight: .semibold))
                                .lineLimit(1)
                            Text(playing.artist ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        // Bounded: the panel sizes itself to measured
                        // content; an unbounded one-line title would
                        // balloon it.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // Trailing corner: the one place in the panel a
                        // refused System Audio Recording grant shows.
                        if let visualizer = module.visualizer {
                            AudioVisualizerPermissionHint(service: visualizer)
                        }
                    }
                    MediaProgressBar(module: module)
                }
            }
            // Absent, not empty, when there is nothing to show — so its
            // arrival changes the panel's height, which is why
            // `MediaModule.setUpNext` reflows on presence. Only Music
            // ever answers; see `UpNextTrack`.
            if let next = module.upNext {
                MediaUpNextRow(next: next, accent: module.artworkAccent)
            }
            MediaLyricsView(module: module, namespace: namespace)
            MediaControlsRow(module: module, isPlaying: playing.isPlaying)
        }
        .frame(width: 368)
        .foregroundStyle(.white)
    }
}

/// The player screen's artwork. Tapping it brings the playing app forward
/// (`MediaModule.openPlayingApp`); with no known app it is not a button.
private struct MediaPlayerArtwork: View {
    let module: MediaModule
    let isPlaying: Bool

    var body: some View {
        MediaArtworkTapTarget(module: module) {
            if let image = module.artworkImage {
                // Ken Burns drift, palette glow, and parallax tilt. Slightly
                // larger than the old flat thumb so the effects have room
                // to read.
                ArtworkVisualizerView(
                    image: image,
                    palette: module.artworkPalette,
                    isPlaying: isPlaying,
                    cornerRadius: 10
                )
                // As tall as the column beside it, so the artwork and the
                // scrub bar bottom-align; see `PlayerLayout.artworkSide`.
                .frame(width: PlayerLayout.artworkSide,
                       height: PlayerLayout.artworkSide)
            } else {
                ArtworkThumb(image: nil, side: PlayerLayout.artworkSide, corner: 10)
            }
        }
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
        } else {
            label()
        }
    }
}

/// The controls row: the transport cluster, with the heart at its leading
/// edge and the volume button at its trailing edge. Clicking the volume
/// button swaps all of it for a full-width volume slider until the pointer
/// leaves the row.
///
/// Its own view because the swap is view state. The row is pinned at the
/// transport's height, and the slider fits inside it, so opening the slider
/// never changes the panel's size.
private struct MediaControlsRow: View {
    let module: MediaModule
    let isPlaying: Bool

    @State private var showsSlider = false
    @State private var pointerInside = false
    @State private var dragging = false

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        ZStack {
            // `showsVolumeControl` re-checked here too: if the notch passes
            // to the system source with the slider open, the slider goes.
            if showsSlider && module.showsVolumeControl {
                MediaVolumeSlider(module: module) { isDragging in
                    dragging = isDragging
                    // Released after the pointer already left the row: the
                    // leave was deferred for the drag, so honour it now.
                    if !isDragging && !pointerInside { setSlider(false) }
                }
                .transition(.opacity)
            } else {
                transportCluster
                    .transition(.opacity)
                // The heart and the volume button sit at the two edges. Both
                // are outside the cluster because both are conditional;
                // inside, either appearing would shift the transport sideways.
                HStack {
                    MediaFavoriteControl(module: module)
                    Spacer()
                    if module.showsVolumeControl {
                        MediaVolumeButton(volume: module.volume) {
                            if module.prepareVolumeSlider() { setSlider(true) }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PlayerLayout.transportButtonHeight)
        // The same hover tracking the artwork's parallax tilt uses, the one
        // proven to fire in this panel, which is never key.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                pointerInside = true
            case .ended:
                pointerInside = false
                // A drag that strays off the row keeps the slider until the
                // release; see above.
                if !dragging { setSlider(false) }
            }
        }
    }

    /// Instant under Reduce Motion (hard rule 8), a short cross-fade otherwise.
    private func setSlider(_ on: Bool) {
        guard showsSlider != on else { return }
        if reduceMotion {
            showsSlider = on
        } else {
            withAnimation(.easeInOut(duration: PlayerLayout.volumeSwapDuration)) {
                showsSlider = on
            }
        }
    }

    private var transportCluster: some View {
        // One centred cluster: the transport tight in the middle, the
        // modes flanking it a step further out. Symmetric about
        // play/pause, so play stays dead centre whether or not the
        // source offers shuffle and repeat. Was edge-to-edge, a holdover
        // from the old full-width layout.
        HStack(spacing: PlayerLayout.modeSpacing) {
            if module.showsPlaybackModes {
                ModeControl(symbol: "shuffle",
                            isOn: module.isShuffling,
                            accent: module.artworkAccent) { module.toggleShuffle() }
            }
            HStack(spacing: PlayerLayout.transportSpacing) {
                transportButton("backward.fill", size: PlayerLayout.transportGlyphSize) {
                    module.send(.previousTrack)
                }
                transportButton(isPlaying ? "pause.fill" : "play.fill",
                                size: PlayerLayout.playGlyphSize) {
                    module.send(.togglePlayPause)
                }
                transportButton("forward.fill", size: PlayerLayout.transportGlyphSize) {
                    module.send(.nextTrack)
                }
            }
            if module.showsPlaybackModes {
                ModeControl(symbol: "repeat",
                            isOn: module.isRepeating,
                            accent: module.artworkAccent) { module.toggleRepeat() }
            }
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: PlayerLayout.transportButtonWidth,
                       height: PlayerLayout.transportButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The scrub bar, in the header column under the titles. It advances once a
/// second while the panel is open; dragging scrubs and releases into a seek.
/// The 1s tick exists only while this view does, i.e. only while the notch
/// is expanded. No time labels: the wave alone carries position.
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
/// The next track in the player's queue: one line, title then artist.
///
/// Information, not a control — nothing here is clickable. No transition or
/// animation of its own: appearing or leaving reflows the panel through the
/// coordinator, which already applies the Reduce Motion rule (hard rule 8).
private struct MediaUpNextRow: View {
    let next: UpNextTrack
    let accent: Color?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("UP NEXT")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle((accent ?? .mediaAccent).opacity(0.9))
            Text(next.title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                // The artist truncates first; the title is the answer.
                .layoutPriority(1)
            // Music may leave the artist blank; the title alone still stands.
            if !next.artist.isEmpty {
                Text(next.artist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        // Bounded, like the titles above: a long name truncates rather than
        // widening the panel.
        .frame(maxWidth: .infinity, alignment: .leading)
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
/// Sized to match `MediaFavoriteControl` exactly (28x28), which is what
/// keeps the controls row at the transport buttons' 32pt and the panel at
/// its existing height.
private struct ModeControl: View {
    let symbol: String
    let isOn: Bool
    let accent: Color?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .font(.system(size: PlayerLayout.modeGlyphSize, weight: .semibold))
                .foregroundStyle(isOn ? (accent ?? .mediaAccent) : .white.opacity(PlayerLayout.modeRestingOpacity))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(symbol) \(isOn ? "on" : "off")")
    }
}

private struct MediaFavoriteControl: View {
    let module: MediaModule

    private var isOn: Bool { module.likedCurrent == true }

    private var tint: Color {
        isOn ? (module.artworkAccent ?? .mediaAccent) : .white.opacity(0.7)
    }

    var body: some View {
        if module.likedCurrent != nil {
            if module.canToggleFavorite {
                Button { module.toggleLike() } label: { heart }
                    .buttonStyle(.plain)
            } else {
                // Display-only: no Button, and hit testing off so the click
                // falls through to the panel instead of landing on a dead
                // control. Dimmed so it does not read as pressable.
                heart
                    .opacity(0.55)
                    .allowsHitTesting(false)
                    .accessibilityLabel(isOn ? "Starred" : "Not starred")
            }
        }
    }

    private var heart: some View {
        Image(systemName: isOn ? "heart.fill" : "heart")
            .font(.system(size: PlayerLayout.edgeGlyphSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: PlayerLayout.edgeControlSide, height: PlayerLayout.edgeControlSide)
            .contentShape(Rectangle())
    }
}

/// The volume button at the controls row's trailing edge, opposite the
/// heart. Sized and tinted like the shuffle and repeat buttons at rest
/// (`modeGlyphSize` in the shared 28pt frame, `modeRestingOpacity`), not
/// like the heart, which read too big (user-tuned 2026-09-17).
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
                .font(.system(size: PlayerLayout.modeGlyphSize, weight: .semibold))
                .foregroundStyle(.white.opacity(PlayerLayout.modeRestingOpacity))
                .frame(width: PlayerLayout.edgeControlSide, height: PlayerLayout.edgeControlSide)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Volume")
        .accessibilityValue(volume.map { "\($0) percent" } ?? "")
    }
}

/// The full-width volume slider that stands in for the transport cluster.
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
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(accent).frame(width: geo.size.width * fraction)
                }
                .frame(height: PlayerLayout.volumeTrackHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(width: geo.size.width))
            }
            endGlyph("speaker.wave.3.fill")
        }
        .frame(height: PlayerLayout.transportButtonHeight)
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
            .foregroundStyle(.white.opacity(0.55))
    }
}

private struct MediaProgressBar: View {
    let module: MediaModule

    /// Artwork-derived (never black by construction), peach fallback.
    private var accent: Color { module.artworkAccent ?? .mediaAccent }

    /// Non-nil while the user is dragging: their finger owns the bar and
    /// live updates keep off it until release.
    @State private var scrubFraction: Double?

    var body: some View {
        let snapshot = module.nowPlaying
        let duration = snapshot?.duration ?? 0
        // The test `MediaModule.drawsSpectrum` makes, so capture runs only
        // while this row exists.
        if snapshot?.hasDuration == true {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = scrubFraction.map { $0 * duration }
                    ?? min(snapshot?.elapsedNow(at: context.date) ?? 0, duration)
                track(fraction: duration > 0 ? elapsed / duration : 0, duration: duration)
            }
        }
    }

    /// The bar is the spectrum wave: full width at all times, accent left of
    /// the playhead and grey right of it. With no spectrum it lies flat, a
    /// plain progress bar. See `AudioVisualizerSpectrumView`.
    private func track(fraction: Double, duration: TimeInterval) -> some View {
        GeometryReader { geo in
            AudioVisualizerSpectrumView(service: module.visualizer,
                                        accent: accent,
                                        progress: fraction)
                // Drawing only. The taper thins the wave toward both
                // ends, so its shape must never decide where a click
                // lands.
                .allowsHitTesting(false)
                .frame(width: geo.size.width, height: geo.size.height)
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
        }
        // Taller than the old 14pt row with its 6pt capsule, so the wave has
        // room to read as a wave. The panel grows by the difference.
        .frame(height: SpectrumEnvelope.maxHeight)
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
    /// way stays inside the `PlayerLayout.sectionSpacing` gap below the row,
    /// and above it reaches only the artist line, which takes no clicks. Both
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

/// The line being sung, under the progress bar in a dimmed accent, a step
/// quieter than the title and artist. Absent entirely (no reserved space) when the track has
/// no synced lyrics. The half-second tick exists only while this view does.
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

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// nil under Reduce Motion makes the swap instant (hard rule 8).
    private var crossfade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: LyricsMotion.tickerCrossfadeDuration)
    }

    var body: some View {
        if module.lyrics?.isEmpty == false {
            ticker
        } else if module.lyricsReserved {
            // Holding the height, not showing anything: the outgoing track
            // had lyrics and the incoming track's lookup is still running.
            // Without this the panel shrinks and the notch collapses.
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
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var accent: Color { module.artworkAccent ?? Color.mediaAccent }
}

struct MediaFullLyricsView: View {
    let module: MediaModule
    let namespace: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Song badge, top-left, matching the Sapphire reference: back
            // chevron, small artwork, then title / album / artist stacked.
            // Extra top clearance keeps it fully below the physical notch.
            HStack(alignment: .center, spacing: 9) {
                Button { module.toggleFullLyrics() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                MediaArtworkTapTarget(module: module) {
                    ArtworkThumb(image: module.artworkImage, side: 30, corner: 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.nowPlaying?.title ?? "")
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                    if let album = module.nowPlaying?.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Text(module.nowPlaying?.artist ?? "")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
            }

            if let lines = module.lyrics, !lines.isEmpty {
                MediaFullLyricsLines(lines: lines, module: module, namespace: namespace)
                    // Measured off the reference: its lyrics region is
                    // roughly 155pt, giving a ~280pt card rather than a
                    // 380pt slab.
                    .frame(height: 160)
                    .mask(
                        // Fade the edges so lines melt in and out, per the
                        // reference screenshot.
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
        .frame(width: 400)
        .foregroundStyle(.white)
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
                : .white.opacity(0.28))
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
