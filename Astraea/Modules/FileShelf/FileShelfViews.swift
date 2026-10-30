import SwiftUI
import UniformTypeIdentifiers

/// The shelf screen, in two modes keyed off the live drag state.
///
/// **Mid-drag** it is a chooser: two large zones side by side, *Add to Shelf*
/// and *AirDrop*, so a file dragged at the notch picks its fate in one
/// gesture. **At rest** it is the shelf itself: a page header above one wide
/// dashed region holding the parked files as tiles, with a full-width
/// AirDrop bar beneath.
///
/// Sizes date from user-supplied full-screen captures (2026-08-30): 230×125
/// chooser zones in a snug 540pt panel, the resting shelf in a 690pt one.
/// Both widths are pinned by ChromeBandFitTests.
///
/// The two modes are deliberately different sizes — Joshua asked for the
/// chooser panel to hug its zones — and that is safe because a mode swap can
/// no longer happen under a mid-drag cursor: a drag that starts on the shelf
/// itself never shows the chooser (the homepage and its AirDrop bar stay
/// up), so chooser transitions only occur when a drag arrives at or leaves
/// the whole panel.
struct FileShelfExpandedView: View {
    @Bindable var service: FileShelfService

    var body: some View {
        Group {
            if service.dragHovering {
                DragChooserView(service: service)
            } else {
                ShelfHomeView(service: service)
            }
        }
        .foregroundStyle(NotchStyle.Ink.primary)
    }
}

/// Private tokens for this page. Neutral grey throughout, no brown and no
/// AirDrop blue (user, 2026-10-29); a drop target brightens to white while
/// a drag is over it rather than taking the accent colour.
private enum ShelfStyle {
    static let tint = Color.gray
    static let airDropTint = Color.gray
    static let target = Color.white
    /// Dashed outline for "this is a place things live".
    static let dash: [CGFloat] = [6, 5]
    /// Outline of an untargeted zone: a stroke, never text.
    static let restingStroke = Color.white.opacity(0.18)
}

// MARK: - Mid-drag chooser

/// Two drop zones, shown only while a file drag is over the panel.
private struct DragChooserView: View {
    @Bindable var service: FileShelfService

    @State private var shelfTargeted = false
    @State private var airdropTargeted = false

    var body: some View {
        HStack(spacing: NotchStyle.Spacing.l) {
            DropZone(symbol: "tray.and.arrow.down.fill", label: "Add to Shelf",
                     detail: "Keep it here for later", tint: ShelfStyle.tint,
                     dashed: true, targeted: shelfTargeted)
                .onDrop(of: [.fileURL], isTargeted: $shelfTargeted) { providers in
                    load(providers) { service.add($0) }
                    return true
                }
            // No public "airdrop" SF Symbol exists (checked 2026-08-30), so
            // the radio-waves glyph stands in for the concentric-arcs logo.
            DropZone(symbol: "dot.radiowaves.left.and.right", label: "AirDrop",
                     detail: "Send to a nearby device", tint: ShelfStyle.airDropTint,
                     dashed: false, targeted: airdropTargeted)
                .onDrop(of: [.fileURL], isTargeted: $airdropTargeted) { providers in
                    shareDropped(providers, via: service)
                    return true
                }
        }
        // Hugs the zones: no dead black around the chooser (user-requested).
        .frame(width: 476, height: 125)
    }
}

/// One chooser target. The shelf side is dashed ("this is a place things
/// live"), the AirDrop side solid ("this is an action"). The whole 230×125
/// card is the target; it brightens to white while targeted.
private struct DropZone: View {
    let symbol: String
    let label: String
    let detail: String
    let tint: Color
    let dashed: Bool
    let targeted: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NotchStyle.Radius.card, style: .continuous)
    }

    var body: some View {
        VStack(spacing: NotchStyle.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tint.gradient))
                .scaleEffect(targeted ? 1.08 : 1)
            VStack(spacing: 2) {
                Text(label)
                    .font(NotchStyle.Font.bodyEmphasis)
                    .foregroundStyle(NotchStyle.Ink.primary)
                Text(detail)
                    .font(NotchStyle.Font.caption)
                    .foregroundStyle(targeted ? NotchStyle.Ink.secondary : NotchStyle.Ink.tertiary)
            }
        }
        .frame(width: 230, height: 125)
        .background(shape.fill(targeted ? ShelfStyle.target.opacity(0.22) : NotchStyle.Fill.card))
        .overlay(
            shape.strokeBorder(style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                  dash: dashed && !targeted ? ShelfStyle.dash : []))
                .foregroundStyle(targeted ? ShelfStyle.target : ShelfStyle.restingStroke)
        )
        .contentShape(shape)
        .animation(NotchStyle.motion(), value: targeted)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Resting shelf

/// The shelf at rest: header, one wide dashed region of file tiles, and the
/// AirDrop bar.
private struct ShelfHomeView: View {
    @Bindable var service: FileShelfService

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.m) {
            header
            ShelfTilesZone(service: service)
            AirDropBar(service: service)
        }
        .frame(width: 626, alignment: .leading)
    }

    /// No clear-all control on purpose — one misclick emptying the whole
    /// shelf is the wrong failure mode; each tile removes itself instead.
    private var header: some View {
        NotchPageHeader(symbol: "tray.full.fill", title: "File Shelf",
                        tint: ShelfStyle.tint, subtitle: subtitle)
    }

    private var subtitle: String? {
        let count = service.entries.count
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "file" : "files") · drag out to use anywhere"
    }
}

/// The parked files, inside the shelf's own drop region.
private struct ShelfTilesZone: View {
    @Bindable var service: FileShelfService

    @State private var zoneTargeted = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NotchStyle.Radius.card, style: .continuous)
    }

    var body: some View {
        ZStack {
            shape.fill(zoneTargeted ? ShelfStyle.target.opacity(0.16) : NotchStyle.Fill.card)
            shape.strokeBorder(style: StrokeStyle(lineWidth: zoneTargeted ? 2 : 1,
                                                  dash: zoneTargeted ? [] : ShelfStyle.dash))
                .foregroundStyle(zoneTargeted ? ShelfStyle.target : ShelfStyle.restingStroke)
            if service.entries.isEmpty {
                NotchEmptyState(symbol: "tray.and.arrow.down", message: "Drop files here")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: NotchStyle.Spacing.s)],
                              spacing: NotchStyle.Spacing.s) {
                        ForEach(service.entries) { entry in
                            ShelfItem(service: service, entry: entry)
                        }
                    }
                    .padding(NotchStyle.Spacing.s)
                }
            }
        }
        .frame(height: 128)
        .frame(maxWidth: .infinity)
        .animation(NotchStyle.motion(), value: zoneTargeted)
        // Belt and braces: drags normally swap this view for the chooser, but
        // if that signal ever failed this keeps the shelf accepting drops.
        .onDrop(of: [.fileURL], isTargeted: $zoneTargeted) { providers in
            load(providers) { service.add($0) }
            return true
        }
    }
}

/// The way off the shelf: drag any tile onto this bar to AirDrop it. A
/// full-width target, because a tile drag keeps this screen up (see the
/// type comment) and the drop has to have somewhere obvious to land —
/// the per-tile hover button this replaces was too small to notice.
private struct AirDropBar: View {
    @Bindable var service: FileShelfService

    @State private var airdropTargeted = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NotchStyle.Radius.card, style: .continuous)
    }

    var body: some View {
        HStack(spacing: NotchStyle.Spacing.s) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(ShelfStyle.airDropTint.gradient))
            Text("Drop here to AirDrop")
                .font(NotchStyle.Font.bodyEmphasis)
                .foregroundStyle(airdropTargeted ? NotchStyle.Ink.primary : NotchStyle.Ink.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(shape.fill(airdropTargeted ? ShelfStyle.target.opacity(0.22) : NotchStyle.Fill.card))
        .overlay(shape.strokeBorder(lineWidth: airdropTargeted ? 2 : 1)
            .foregroundStyle(airdropTargeted ? ShelfStyle.target : ShelfStyle.restingStroke))
        .contentShape(shape)
        .animation(NotchStyle.motion(), value: airdropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $airdropTargeted) { providers in
            shareDropped(providers, via: service)
            return true
        }
    }
}

/// Shares every dropped file via AirDrop, straight away — shelving first
/// would be a side effect the gesture did not ask for. Used by the chooser's
/// AirDrop zone and the homepage's AirDrop bar alike.
///
/// Gathers every URL first and starts **one** share for all of them; see
/// `FileShelfService.share(_:)` for why one share per file was a bug.
private func shareDropped(_ providers: [NSItemProvider], via service: FileShelfService) {
    Task { @MainActor in
        var urls: [URL] = []
        for provider in providers {
            if let url = await loadURL(provider) { urls.append(url) }
        }
        service.share(urls)
    }
}

/// One file URL off one drag provider, or nil.
private func loadURL(_ provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            continuation.resume(returning: url)
        }
    }
}

/// Pulls file URLs off drag providers and hands each to `action`.
private func load(_ providers: [NSItemProvider], action: @escaping (URL) -> Void) {
    for provider in providers {
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in action(url) }
        }
    }
}

/// One parked file: thumbnail, name, and a remove affordance. Draggable out
/// to Finder or any app that accepts files. Highlights under the pointer the
/// way a Finder icon-view item does.
private struct ShelfItem: View {
    @Bindable var service: FileShelfService
    let entry: FileShelfEntry

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            // The remove badge must keep overlapping the thumbnail's top-right
            // corner: that 20pt corner is what DragSourceView.hitTest stops
            // claiming while `hovering` is true, so the badge stays clickable.
            ZStack(alignment: .topTrailing) {
                thumbnail
                    // AppKit drag source, not SwiftUI's .onDrag: see
                    // ShelfDragSource for the measurement that forced it.
                    // The URL is resolved when the drag starts, not here:
                    // the file may have moved since it was shelved, and
                    // resolving a bookmark in `body` would hit the disk on
                    // every redraw.
                    .overlay(ShelfDragSource(
                        resolveURL: { service.url(for: entry) },
                        thumbnail: service.thumbnail(for: entry),
                        excludesHoverControls: hovering,
                        onDragBegan: { service.dragOutBegan(entry) },
                        onDragEnded: { service.dragOutEnded() }
                    ))
                    // Dimmed when the file was not found at the last drag;
                    // the entry stays, since the file may come back.
                    .opacity(service.isMissing(entry) ? 0.35 : 1)
                if hovering {
                    Button { service.remove(entry) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white, Color(white: 0.3))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Remove from shelf — the file itself is untouched")
                    .accessibilityLabel("Remove \(entry.name) from shelf")
                }
            }
            Text(entry.name)
                .font(NotchStyle.Font.caption)
                .foregroundStyle(hovering ? NotchStyle.Ink.primary : NotchStyle.Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 80)
        }
        .padding(.vertical, 6)
        .frame(width: 88)
        .background(RoundedRectangle(cornerRadius: NotchStyle.Radius.row, style: .continuous)
            .fill(hovering ? NotchStyle.Fill.hover : .clear))
        .onHover { hovering = $0 }
        .animation(NotchStyle.motion(.easeOut(duration: 0.12)), value: hovering)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = service.thumbnail(for: entry) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else {
            RoundedRectangle(cornerRadius: NotchStyle.Radius.thumb, style: .continuous)
                .fill(NotchStyle.Fill.selected)
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(NotchStyle.Ink.tertiary))
        }
    }
}
