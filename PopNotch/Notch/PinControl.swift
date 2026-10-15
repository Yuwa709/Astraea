import SwiftUI

/// Holds the panel open until pressed again. Matches CaffeinateControl's
/// metrics so the band's chrome reads as one family.
///
/// State has to be unmistakable at a glance: a pinned notch that looks
/// unpinned reads as the collapse logic being broken. So it carries two
/// signals at once — a filled glyph against an outline one, and full white
/// against dimmed — the same pairing the keep-awake toggle beside it uses.
struct PinControl: View {
    let isPinned: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isPinned ? .white : .white.opacity(0.3))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? "Unpin — let the notch close on its own" : "Pin the notch open")
        .accessibilityLabel("Pin notch")
        .accessibilityValue(isPinned ? "On" : "Off")
    }
}
