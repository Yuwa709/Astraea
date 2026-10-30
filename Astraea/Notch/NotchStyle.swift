import AppKit
import SwiftUI

/// The notch's shared visual language: one set of tokens and a handful of
/// building blocks every expanded page draws with, so the clipboard, shelf,
/// mixer, stats and media pages read as one family.
///
/// The panel is always solid black, so these are dark-only by design. Text
/// opacities are floored for contrast against both the black panel and a
/// card fill: 0.5 white on black is 5.3:1 and on a 0.07 card still 4.6:1,
/// above the 4.5:1 small-text minimum. Nothing that carries meaning goes
/// below `Ink.tertiary`.
///
/// Type never drops under 10pt, the macOS minimum. Section labels are
/// sentence-case 11pt rather than 8pt capitals: the old eyebrow style was
/// below the minimum and harder to read than the content it labelled.
enum NotchStyle {

    /// Foreground opacities over the black panel.
    enum Ink {
        static let primary = Color.white.opacity(0.95)
        static let secondary = Color.white.opacity(0.65)
        static let tertiary = Color.white.opacity(0.5)
        /// Glyphs and strokes only, never text.
        static let quaternary = Color.white.opacity(0.3)
    }

    /// Background fills, lightest last.
    enum Fill {
        /// A card or grouped row sitting on the panel.
        static let card = Color.white.opacity(0.07)
        /// The same surface under the pointer.
        static let hover = Color.white.opacity(0.11)
        /// Selected segment, pressed state, or a control's track.
        static let selected = Color.white.opacity(0.16)
        /// Hairlines between rows inside one card.
        static let separator = Color.white.opacity(0.08)
    }

    /// Continuous-corner radii. Nested shapes step down by the padding
    /// between them, so a 10pt-padded row inside a card uses `row`.
    enum Radius {
        static let card: CGFloat = 14
        static let row: CGFloat = 10
        static let control: CGFloat = 8
        static let thumb: CGFloat = 6
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    enum Font {
        /// A page's title in its header.
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
        /// A group's label above its card.
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let bodyEmphasis = SwiftUI.Font.system(size: 13, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11)
        static let captionEmphasis = SwiftUI.Font.system(size: 11, weight: .medium)
        /// The floor. Units, footnotes, provenance.
        static let footnote = SwiftUI.Font.system(size: 10)
        /// A headline figure: a charge percentage, a time.
        static let metricLarge = SwiftUI.Font.system(size: 28, weight: .semibold, design: .rounded)
        /// A figure in a card.
        static let metric = SwiftUI.Font.system(size: 17, weight: .semibold, design: .rounded)
    }

    /// An animation that is nil under Reduce Motion (hard rule 8), for
    /// `withAnimation` and `.animation(_:value:)` alike. Read at call time,
    /// so flipping the setting applies without a relaunch.
    static func motion(_ animation: Animation = .snappy(duration: 0.22)) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }
}

// MARK: - Building blocks

/// A page's header: the feature's glyph, its title, an optional one-line
/// status, and trailing controls.
///
/// The glyph is plain white with no tile behind it (user, 2026-10-29: "why
/// does everything have to be in a box"). `tint` is kept in the signature so
/// call sites stay unchanged, but is not drawn.
struct NotchPageHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    let tint: Color
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: NotchStyle.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(NotchStyle.Ink.primary)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(NotchStyle.Font.title)
                    .foregroundStyle(NotchStyle.Ink.primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NotchStyle.Font.footnote)
                        .foregroundStyle(NotchStyle.Ink.tertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: NotchStyle.Spacing.s)
            trailing()
        }
        .accessibilityElement(children: .contain)
    }
}

extension NotchPageHeader where Trailing == EmptyView {
    init(symbol: String, title: String, tint: Color, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, tint: tint, subtitle: subtitle) { EmptyView() }
    }
}

/// A group's label, sitting just above its card.
struct NotchSectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(NotchStyle.Font.section)
            .foregroundStyle(NotchStyle.Ink.tertiary)
            .padding(.leading, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a page shows when it has nothing yet: a quiet glyph and one line
/// that says what will appear here.
struct NotchEmptyState: View {
    let symbol: String
    let message: String

    var body: some View {
        VStack(spacing: NotchStyle.Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(NotchStyle.Ink.quaternary)
            Text(message)
                .font(NotchStyle.Font.caption)
                .foregroundStyle(NotchStyle.Ink.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A capsule segmented control for switching a page between views of the
/// same content. Selection reads by fill and brightness, never size, so
/// switching never reflows the header.
struct NotchSegmentedControl<Value: Hashable>: View {
    struct Segment {
        let value: Value
        let label: String
        var symbol: String?
    }

    @Binding var selection: Value
    let segments: [Segment]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(NotchStyle.motion()) { selection = segment.value }
                } label: {
                    HStack(spacing: 4) {
                        if let symbol = segment.symbol {
                            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
                        }
                        Text(segment.label).font(NotchStyle.Font.captionEmphasis)
                    }
                    .foregroundStyle(isSelected ? NotchStyle.Ink.primary : NotchStyle.Ink.tertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(isSelected ? NotchStyle.Fill.selected : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(NotchStyle.Fill.card))
    }
}

/// A plain button whose label sits on a card fill that brightens under the
/// pointer and on press. For tappable rows and tiles.
struct NotchRowButtonStyle: ButtonStyle {
    var radius: CGFloat = NotchStyle.Radius.row
    var resting: Color = NotchStyle.Fill.card

    func makeBody(configuration: Configuration) -> some View {
        NotchRowButtonBody(configuration: configuration, radius: radius, resting: resting)
    }
}

private struct NotchRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let radius: CGFloat
    let resting: Color
    @State private var hovering = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(configuration.isPressed ? NotchStyle.Fill.selected
                          : hovering ? NotchStyle.Fill.hover : resting))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
            .animation(NotchStyle.motion(.easeOut(duration: 0.12)), value: hovering)
    }
}

/// A small circular icon button: clear at rest, a fill under the pointer.
/// For secondary actions inside a page (remove, more, clear).
struct NotchIconButtonStyle: ButtonStyle {
    var size: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        NotchIconButtonBody(configuration: configuration, size: size)
    }
}

private struct NotchIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let size: CGFloat
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(hovering ? NotchStyle.Ink.primary : NotchStyle.Ink.secondary)
            .frame(width: size, height: size)
            .background(Circle().fill(configuration.isPressed ? NotchStyle.Fill.selected
                                      : hovering ? NotchStyle.Fill.hover : .clear))
            .contentShape(Circle())
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Places the view on a card: the shared fill and corner radius, with
    /// optional padding inside.
    func notchCard(padding: CGFloat = NotchStyle.Spacing.m,
                   radius: CGFloat = NotchStyle.Radius.card) -> some View {
        self
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(NotchStyle.Fill.card))
    }
}
