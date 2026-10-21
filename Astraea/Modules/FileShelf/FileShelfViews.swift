import SwiftUI
import UniformTypeIdentifiers

/// The shelf screen, in two modes keyed off the live drag state.
///
/// **Mid-drag** it is a chooser: two large zones side by side, *Add to Shelf*
/// and *AirDrop*, so a file dragged at the notch picks its fate in one
/// gesture. **At rest** it is the shelf itself: a "File Drops" header above
/// one wide dashed region holding the parked files as tiles.
///
/// Layout replicated from user-supplied full-screen captures (2026-08-30) at
/// this display's 0.735 px-to-point scale: 230×125 chooser zones in a snug
/// 540pt panel, the resting shelf in a 690pt one.
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
        .foregroundStyle(.white)
    }
}

// MARK: - Mid-drag chooser

/// Two drop zones, shown only while a file drag is over the panel.
private struct DragChooserView: View {
    @Bindable var service: FileShelfService

    @State private var shelfTargeted = false
    @State private var airdropTargeted = false

    var body: some View {
        HStack(spacing: 16) {
            DropZone(symbol: "tray.and.arrow.down", label: "Add to Shelf",
                     dashed: true, targeted: shelfTargeted)
                .onDrop(of: [.fileURL], isTargeted: $shelfTargeted) { providers in
                    load(providers) { service.add($0) }
                    return true
                }
            // No public "airdrop" SF Symbol exists (checked 2026-08-30), so
            // the radio-waves glyph stands in for the concentric-arcs logo.
            DropZone(symbol: "dot.radiowaves.left.and.right", label: "AirDrop",
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
/// live"), the AirDrop side solid ("this is an action").
private struct DropZone: View {
    let symbol: String
    let label: String
    let dashed: Bool
    let targeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
            Text(label)
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(targeted ? 0.95 : 0.65))
        .frame(width: 230, height: 125)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(
                    lineWidth: 1.5, dash: dashed ? [9, 7] : []))
                .foregroundStyle(.white.opacity(targeted ? 0.65 : 0.28))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Resting shelf

/// The shelf at rest: header plus one wide dashed region of file tiles.
private struct ShelfHomeView: View {
    @Bindable var service: FileShelfService

    @State private var zoneTargeted = false

    @State private var airdropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            zone
            airdropBar
        }
        .frame(width: 626, alignment: .leading)
    }

    /// No clear-all control on purpose — one misclick emptying the whole
    /// shelf is the wrong failure mode; each tile removes itself instead.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.7))
            Text("File Drops")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
        }
        .frame(height: 24)
    }

    private var zone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [9, 7]))
                .foregroundStyle(.white.opacity(zoneTargeted ? 0.6 : 0.25))
            if service.entries.isEmpty {
                Text("Drop files here")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10)],
                              spacing: 12) {
                        ForEach(service.entries) { entry in
                            ShelfItem(service: service, entry: entry)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(height: 128)
        .frame(maxWidth: .infinity)
        // Belt and braces: drags normally swap this view for the chooser, but
        // if that signal ever failed this keeps the shelf accepting drops.
        .onDrop(of: [.fileURL], isTargeted: $zoneTargeted) { providers in
            load(providers) { service.add($0) }
            return true
        }
    }

    /// The way off the shelf: drag any tile onto this bar to AirDrop it. A
    /// full-width target, because a tile drag keeps this screen up (see the
    /// type comment) and the drop has to have somewhere obvious to land —
    /// the per-tile hover button this replaces was too small to notice.
    private var airdropBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 14, weight: .medium))
            Text("Drop here to AirDrop")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(airdropTargeted ? 0.95 : 0.6))
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .foregroundStyle(.white.opacity(airdropTargeted ? 0.65 : 0.28))
        )
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
/// to Finder or any app that accepts files.
private struct ShelfItem: View {
    @Bindable var service: FileShelfService
    let entry: FileShelfEntry

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
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
                            .font(.system(size: 13))
                            .foregroundStyle(.white, .black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .help("Remove from shelf — the file itself is untouched")
                }
            }
            Text(entry.name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 84)
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = service.thumbnail(for: entry) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(width: 64, height: 64)
                .overlay(Image(systemName: "doc")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.5)))
        }
    }
}
