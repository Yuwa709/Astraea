import SwiftUI

/// The history in the expanded notch, split by kind: a Text view listing
/// copied strings and an Images view showing copied images as a thumbnail
/// grid. The header carries the feature's glyph, a count, the Text/Images
/// switch and Clear. Click any entry to put it back on the pasteboard.
struct ClipboardExpandedView: View {
    @Bindable var service: ClipboardService

    /// Which kind is showing. Not persisted: a tab is a place you went, not
    /// a preference — the same rule the navigation destination follows.
    @State private var filter: ClipboardFilter = .text

    /// 420pt is pinned by ChromeBandFitTests; the band clearance sweep
    /// depends on it.
    private static let width: CGFloat = 420
    private static let listHeight: CGFloat = 240

    private var filtered: [ClipboardEntry] {
        service.entries.filter { filter.matches($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NotchStyle.Spacing.m) {
            header
            content
                .frame(height: Self.listHeight)
                .frame(maxWidth: .infinity)
        }
        .frame(width: Self.width, alignment: .leading)
        .foregroundStyle(NotchStyle.Ink.primary)
    }

    private var header: some View {
        NotchPageHeader(symbol: "doc.on.clipboard.fill", title: "Clipboard",
                        tint: .gray, subtitle: subtitle) {
            HStack(spacing: NotchStyle.Spacing.s) {
                NotchSegmentedControl(selection: $filter, segments: [
                    .init(value: .text, label: "Text", symbol: "text.alignleft"),
                    .init(value: .images, label: "Images", symbol: "photo"),
                ])
                .help("Show only text or only images")
                if !service.entries.isEmpty {
                    Button { service.clear() } label: { Image(systemName: "trash") }
                        .buttonStyle(NotchIconButtonStyle())
                        .help("Clear the clipboard history")
                        .accessibilityLabel("Clear")
                }
            }
        }
    }

    /// The count, split by kind, so the other tab's contents are visible
    /// without switching to it.
    private var subtitle: String {
        let entries = service.entries
        guard !entries.isEmpty else { return "Nothing copied yet" }
        let texts = entries.filter { ClipboardFilter.text.matches($0) }.count
        let images = entries.count - texts
        return "\(texts) text · \(images) \(images == 1 ? "image" : "images") · click to copy"
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            NotchEmptyState(symbol: filter == .text ? "text.alignleft" : "photo",
                            message: filter == .text ? "No text copied yet" : "No images copied yet")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                switch filter {
                case .text:
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { entry in
                            ClipboardTextRow(entry: entry) { service.copyBack(entry) }
                        }
                    }
                case .images:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NotchStyle.Spacing.s),
                                             count: 3),
                              spacing: NotchStyle.Spacing.s) {
                        ForEach(filtered) { entry in
                            ClipboardImageCell(entry: entry) { service.copyBack(entry) }
                        }
                    }
                }
            }
        }
    }
}

/// The kinds the history splits into. Mirrors `ClipboardEntry.Content`
/// without carrying payloads, so the header can hold one as plain state.
private enum ClipboardFilter: Hashable {
    case text, images

    func matches(_ entry: ClipboardEntry) -> Bool {
        switch entry.content {
        case .text: return self == .text
        case .image: return self == .images
        }
    }
}

/// One copied string: up to two lines of preview, with the time it was
/// copied trailing. Under the pointer the time gives way to a copy glyph,
/// so the row says what a click will do.
private struct ClipboardTextRow: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onCopy) {
            HStack(alignment: .firstTextBaseline, spacing: NotchStyle.Spacing.m) {
                preview
                    .font(NotchStyle.Font.body)
                    .foregroundStyle(NotchStyle.Ink.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: .trailing) {
                    Text(entry.capturedAt, format: .dateTime.hour().minute())
                        .font(NotchStyle.Font.footnote)
                        .monospacedDigit()
                        .foregroundStyle(NotchStyle.Ink.tertiary)
                        .opacity(hovering ? 0 : 1)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(NotchStyle.Ink.secondary)
                        .opacity(hovering ? 1 : 0)
                }
                .fixedSize()
            }
            .padding(.vertical, 9)
            .padding(.horizontal, NotchStyle.Spacing.m)
        }
        .buttonStyle(NotchRowButtonStyle())
        .onHover { hovering = $0 }
        .animation(NotchStyle.motion(.easeOut(duration: 0.12)), value: hovering)
        .help("Copy back to the clipboard")
    }

    /// Longer than the service's one-line default: the row has room for
    /// two lines at this width.
    @ViewBuilder
    private var preview: some View {
        if case .text(let string) = entry.content {
            Text(ClipboardService.preview(of: string, limit: 110))
        }
    }
}

/// One copied image, a third of the page wide. Under the pointer it gains a
/// hairline ring and a copy badge.
private struct ClipboardImageCell: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void
    @State private var hovering = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NotchStyle.Radius.row, style: .continuous)
    }

    var body: some View {
        Button(action: onCopy) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 84)
                .overlay(thumbnail)
                .clipShape(shape)
                .overlay(shape.strokeBorder(hovering ? NotchStyle.Ink.quaternary : NotchStyle.Fill.separator,
                                            lineWidth: 1))
                .overlay(alignment: .bottomTrailing) { badge }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NotchStyle.motion(.easeOut(duration: 0.12)), value: hovering)
        .help("Copy back to the clipboard")
        .accessibilityLabel("Copied image")
    }

    private var badge: some View {
        Image(systemName: "doc.on.doc")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(NotchStyle.Ink.primary)
            .frame(width: 22, height: 22)
            .background(.black.opacity(0.6), in: Circle())
            .padding(6)
            .opacity(hovering ? 1 : 0)
    }

    /// Draws the image decoded once at capture; nothing is decoded here, so
    /// re-rendering the grid costs no image work.
    @ViewBuilder
    private var thumbnail: some View {
        if let image = entry.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            NotchStyle.Fill.card
                .overlay(Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(NotchStyle.Ink.quaternary))
        }
    }
}
