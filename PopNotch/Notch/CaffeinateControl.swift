import SwiftUI

/// Keep-awake toggle, drawn as panel chrome rather than as a transport
/// control.
///
/// It lives in the band beside the notch housing, which is empty whenever the
/// panel is expanded — the wings that occupy it only render in the compact
/// state, so the two never collide. That band is also well clear of the
/// module content below, including the media widget's Up Next block.
///
/// Stays on until pressed again: no timer, no auto-off. The icon and its
/// tooltip are the only indication, so both have to be unambiguous.
struct CaffeinateControl: View {
    @Bindable var service: CaffeinateService

    var body: some View {
        Button { service.toggle() } label: {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(service.isActive ? .white : .white.opacity(0.3))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The state has to be checkable without a terminal.
        .help(service.isActive ? "Keeping Mac awake" : "Allow sleep")
        .accessibilityLabel("Keep awake")
        .accessibilityValue(service.isActive ? "On" : "Off")
    }
}
