import SwiftUI

/// How the notch's pages are laid out. One choice today, the media player's;
/// a page of its own so other pages' layouts have a home when they become
/// customisable too.
struct LayoutSettingsTab: View {

    @Bindable var settings: SettingsStore
    /// Applies the media player layout to the live media module; see
    /// `SettingsView`. Nil in tests.
    var onMediaPlayerLayoutChange: ((MediaPlayerLayout) -> Void)?

    var body: some View {
        Form {
            Section("Media") {
                Picker(selection: playerLayoutBinding) {
                    ForEach(MediaPlayerLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                } label: {
                    SettingsLabel("Player layout",
                                  detail: "Simple centres play under the wave and keeps the other controls behind a “more” button. Classic is the 1.5 player, with every control always showing.")
                }
                .pickerStyle(.segmented)
            }
        }
        .settingsPage()
    }

    /// Persists the choice and applies it to the live media module.
    private var playerLayoutBinding: Binding<MediaPlayerLayout> {
        Binding(
            get: { settings.settings.mediaPlayerLayout },
            set: { layout in
                settings.update { $0.mediaPlayerLayout = layout }
                onMediaPlayerLayoutChange?(layout)
            }
        )
    }
}
