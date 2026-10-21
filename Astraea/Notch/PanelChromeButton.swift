import SwiftUI

/// One panel-chrome button in the neck band: the clipboard door, the back
/// arrow, and whatever future screens need. Matches CaffeinateControl's
/// metrics so the band's chrome reads as one family.
struct PanelChromeButton: View {
    let symbol: String
    let help: String
    /// False when the button's destination is already on screen.
    ///
    /// Dimmed and unclickable rather than removed: the trailing group is not
    /// replaced by the back chevron the way the leading group is, so its
    /// buttons stay put for the whole visit. A control that vanished from
    /// under the cursor mid-visit would shift the two beside it.
    var isActive = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(isActive ? 0.75 : 0.25))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isActive)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? [] : .isSelected)
    }
}
