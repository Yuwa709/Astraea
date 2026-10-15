import SwiftUI

/// The history in the expanded notch, split by kind: a Text tab listing
/// copied strings and an Images tab showing copied images as a thumbnail
/// grid. The tabs sit in the header beside Clear. Click any entry to put it
/// back on the pasteboard.
struct ClipboardExpandedView: View {
    @Bindable var service: ClipboardService

    /// Which kind is showing. Not persisted: a tab is a place you went, not
    /// a preference — the same rule the navigation destination follows.
    @State private var filter: ClipboardFilter = .text

    private var filtered: [ClipboardEntry] {
        service.entries.filter { filter.matches($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            content
                .frame(height: 240)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 420, alignment: .leading)
        .foregroundStyle(.white)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("CLIPBOARD")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            FilterChip(label: "Text", symbol: "text.alignleft",
                       isSelected: filter == .text) { filter = .text }
            FilterChip(label: "Images", symbol: "photo",
                       isSelected: filter == .images) { filter = .images }
            if !service.entries.isEmpty {
                Button("Clear") { service.clear() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            Text(filter == .text ? "No text copied yet" : "No images copied yet")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                switch filter {
                case .text:
                    LazyVStack(spacing: 6) {
                        ForEach(filtered) { entry in
                            TextRow(entry: entry) { service.copyBack(entry) }
                        }
                    }
                case .images:
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)],
                              spacing: 8) {
                        ForEach(filtered) { entry in
                            ImageCell(entry: entry) { service.copyBack(entry) }
                        }
                    }
                }
            }
        }
    }
}

/// The kinds the history splits into. Mirrors `ClipboardEntry.Content`
/// without carrying payloads, so the header can hold one as plain state.
private enum ClipboardFilter {
    case text, images

    func matches(_ entry: ClipboardEntry) -> Bool {
        switch entry.content {
        case .text: return self == .text
        case .image: return self == .images
        }
    }
}

/// One header tab. Reads as selected by fill and brightness, not size, so
/// switching tabs never reflows the header.
private struct FilterChip: View {
    let label: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.45))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(isSelected ? 0.16 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show only \(label.lowercased())")
    }
}

/// One copied string: up to two lines of preview, full row width.
private struct TextRow: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            text
                .font(.system(size: 13))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy back to the clipboard")
    }

    @ViewBuilder
    private var text: some View {
        if case .text(let string) = entry.content {
            Text(ClipboardService.preview(of: string))
        }
    }
}

/// One copied image, big enough to recognise.
private struct ImageCell: View {
    let entry: ClipboardEntry
    let onCopy: () -> Void

    var body: some View {
        Button(action: onCopy) {
            thumbnail
                .frame(width: 120, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Copy back to the clipboard")
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay(Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.4)))
        }
    }
}
