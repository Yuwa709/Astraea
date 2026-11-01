import SwiftUI
import AppKit

// The 1.5.0 media player ("Classic" in Settings → Layout → Player layout), restored
// from tag v1.5.0 (MediaViews.swift at 2ef8edd) so it can be chosen beside
// the 1.5.1 simple player. Kept as it shipped: artwork beside the titles and
// the scrub wave, then Up Next, the lyric line, and the controls row with the
// heart and the volume button at its edges.
//
// Everything here is private to this file except the screen itself, which
// `MediaExpandedView` picks by `MediaModule.playerLayout`. The full-lyrics
// page, the wings and `ScrubGeometry` are shared with the simple player and
// stay in MediaViews.swift. Two pieces 1.5.1 deleted live on here, private:
// the corner System Audio Recording hint and the artwork placeholder.

/// The lyric ticker's tunables from 1.5.0, the subset this player uses.
private enum ClassicLyricsMotion {
    /// One `lineLimit(1)` line at `tickerFontSize`; also the height reserved
    /// while a lookup runs.
    static let tickerLineHeight: CGFloat = 15
    /// A step below the artist line's 13pt, the accent dimmed, so the title
    /// stays the loudest thing in the player.
    static let tickerFontSize: CGFloat = 12
    static let tickerAccentOpacity: Double = 0.6
    /// The swap between one active line and the next.
    static let tickerCrossfadeDuration: Double = 0.18
}

/// The player screen's spacing and control sizes, in one place so they can be
/// retuned without hunting through `MediaExpandedView`.
private enum ClassicPlayerLayout {
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

/// The player screen: artwork on the left, titles with the scrub bar
/// directly beneath them beside it, then Up Next, the lyric line and the
/// controls. Its own view so `MediaExpandedView` stays a plain switch.
struct MediaClassicPlayerScreen: View {
    let module: MediaModule
    let playing: NowPlaying
    let namespace: Namespace.ID

    var body: some View {
        VStack(spacing: ClassicPlayerLayout.sectionSpacing) {
            HStack(alignment: .top, spacing: 12) {
                ClassicPlayerArtwork(module: module, isPlaying: playing.isPlaying)
                // Everything right of the artwork is one column: titles
                // (and the trailing hint) on top, the scrub bar directly
                // beneath them, spanning from the artwork's edge to the
                // panel's. The bar is no longer its own full-width row
                // below the header.
                VStack(alignment: .leading, spacing: ClassicPlayerLayout.artistWaveSpacing) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: ClassicPlayerLayout.titleArtistSpacing) {
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
                            ClassicCaptureHint(service: visualizer)
                        }
                    }
                    ClassicProgressBar(module: module)
                }
            }
            // Absent, not empty, when there is nothing to show — so its
            // arrival changes the panel's height, which is why
            // `MediaModule.setUpNext` reflows on presence. Only Music
            // ever answers; see `UpNextTrack`.
            if let next = module.upNext {
                ClassicUpNextRow(next: next, accent: module.artworkAccent)
            }
            ClassicLyricsView(module: module, namespace: namespace)
            ClassicControlsRow(module: module, isPlaying: playing.isPlaying)
        }
        .frame(width: 368)
        .foregroundStyle(.white)
    }
}

/// The player screen's artwork. Tapping it brings the playing app forward
/// (`MediaModule.openPlayingApp`); with no known app it is not a button.
private struct ClassicPlayerArtwork: View {
    let module: MediaModule
    let isPlaying: Bool

    var body: some View {
        ClassicArtworkTapTarget(module: module) {
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
                .frame(width: ClassicPlayerLayout.artworkSide,
                       height: ClassicPlayerLayout.artworkSide)
            } else {
                ClassicArtworkThumb(image: nil, side: ClassicPlayerLayout.artworkSide, corner: 10)
            }
        }
    }
}

/// Wraps artwork in a button that opens the playing app, or leaves it inert
/// when no app is known — a control that cannot act must not look like one.
private struct ClassicArtworkTapTarget<Label: View>: View {
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
private struct ClassicControlsRow: View {
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
                ClassicVolumeSlider(module: module) { isDragging in
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
                    ClassicFavoriteControl(module: module)
                    Spacer()
                    if module.showsVolumeControl {
                        ClassicVolumeButton(volume: module.volume) {
                            if module.prepareVolumeSlider() { setSlider(true) }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ClassicPlayerLayout.transportButtonHeight)
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
            withAnimation(.easeInOut(duration: ClassicPlayerLayout.volumeSwapDuration)) {
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
        HStack(spacing: ClassicPlayerLayout.modeSpacing) {
            if module.showsPlaybackModes {
                ClassicModeControl(symbol: "shuffle",
                            isOn: module.isShuffling,
                            accent: module.artworkAccent) { module.toggleShuffle() }
            }
            HStack(spacing: ClassicPlayerLayout.transportSpacing) {
                transportButton("backward.fill", size: ClassicPlayerLayout.transportGlyphSize) {
                    module.send(.previousTrack)
                }
                transportButton(isPlaying ? "pause.fill" : "play.fill",
                                size: ClassicPlayerLayout.playGlyphSize) {
                    module.send(.togglePlayPause)
                }
                transportButton("forward.fill", size: ClassicPlayerLayout.transportGlyphSize) {
                    module.send(.nextTrack)
                }
            }
            if module.showsPlaybackModes {
                ClassicModeControl(symbol: "repeat",
                            isOn: module.isRepeating,
                            accent: module.artworkAccent) { module.toggleRepeat() }
            }
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: ClassicPlayerLayout.transportButtonWidth,
                       height: ClassicPlayerLayout.transportButtonHeight)
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
private struct ClassicUpNextRow: View {
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
private struct ClassicModeControl: View {
    let symbol: String
    let isOn: Bool
    let accent: Color?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: symbol)
                .font(.system(size: ClassicPlayerLayout.modeGlyphSize, weight: .semibold))
                .foregroundStyle(isOn ? (accent ?? .mediaAccent) : .white.opacity(ClassicPlayerLayout.modeRestingOpacity))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(symbol) \(isOn ? "on" : "off")")
    }
}

private struct ClassicFavoriteControl: View {
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
            .font(.system(size: ClassicPlayerLayout.edgeGlyphSize, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: ClassicPlayerLayout.edgeControlSide, height: ClassicPlayerLayout.edgeControlSide)
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
private struct ClassicVolumeButton: View {
    let volume: Int?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Image(systemName: volume == 0 ? "speaker.slash" : "speaker.wave.3")
                .font(.system(size: ClassicPlayerLayout.modeGlyphSize, weight: .semibold))
                .foregroundStyle(.white.opacity(ClassicPlayerLayout.modeRestingOpacity))
                .frame(width: ClassicPlayerLayout.edgeControlSide, height: ClassicPlayerLayout.edgeControlSide)
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
private struct ClassicVolumeSlider: View {
    let module: MediaModule
    let onDraggingChanged: (Bool) -> Void

    @State private var dragging = false

    private var accent: Color { module.artworkAccent ?? .mediaAccent }
    private var fraction: CGFloat { CGFloat(module.volume ?? 0) / 100 }

    var body: some View {
        HStack(spacing: ClassicPlayerLayout.volumeGlyphSpacing) {
            endGlyph("speaker.fill")
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(accent).frame(width: geo.size.width * fraction)
                }
                .frame(height: ClassicPlayerLayout.volumeTrackHeight)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(drag(width: geo.size.width))
            }
            endGlyph("speaker.wave.3.fill")
        }
        .frame(height: ClassicPlayerLayout.transportButtonHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(module.volume ?? 0) percent")
        .accessibilityAdjustableAction { direction in
            let step: Int
            switch direction {
            case .increment: step = ClassicPlayerLayout.volumeAccessibilityStep
            case .decrement: step = -ClassicPlayerLayout.volumeAccessibilityStep
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
            .font(.system(size: ClassicPlayerLayout.volumeGlyphSize, weight: .semibold))
            .foregroundStyle(.white.opacity(0.55))
    }
}

private struct ClassicProgressBar: View {
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
private struct ClassicLyricsView: View {
    let module: MediaModule
    let namespace: Namespace.ID

    /// The area's full height, used both by the ticker and by the placeholder
    /// that holds the space while a lookup runs. One constant so the two can
    /// never disagree — a mismatch here would resize the panel by the
    /// difference and reintroduce the collapse this reservation prevents.
    static let reservedHeight: CGFloat = ClassicLyricsMotion.tickerLineHeight

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// nil under Reduce Motion makes the swap instant (hard rule 8).
    private var crossfade: Animation? {
        reduceMotion ? nil : .easeInOut(duration: ClassicLyricsMotion.tickerCrossfadeDuration)
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
                .font(.system(size: ClassicLyricsMotion.tickerFontSize, weight: .medium))
                .foregroundStyle(accent.opacity(ClassicLyricsMotion.tickerAccentOpacity))
                .lineLimit(1)
                .id(active)
                .transition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var accent: Color { module.artworkAccent ?? Color.mediaAccent }
}

/// The visualiser's denied path in this player: one line in the header
/// corner, shown only when capture was refused. Without it a refused System
/// Audio Recording grant looks exactly like the feature being off.
private struct ClassicCaptureHint: View {
    let service: AudioVisualizerService

    var body: some View {
        if service.isEnabled, service.lastError != nil {
            Text("Allow System Audio Recording")
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 80)
        }
    }
}

/// The artwork tile, or a quiet placeholder with a note when there is none.
/// Takes the module's already-decoded `artworkImage`, never raw bytes.
private struct ClassicArtworkThumb: View {
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
