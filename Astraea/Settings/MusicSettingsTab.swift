import SwiftUI

/// Everything about what is playing, in one place: the visualiser, which
/// players Astraea may control, and how other players are read.
///
/// There is no Spotify section. The optional account connection (OAuth, the
/// Web API) was removed: Spotify caps a development-mode app at 25 users, so
/// Connect failed for nearly everyone, and it was the app's only Keychain use.
struct MusicSettingsTab: View {

    @Bindable var settings: SettingsStore
    let visualizer: AudioVisualizerService
    /// Only for the other-mixer warning below; nil in tests, which then do
    /// not render it.
    var appVolume: AppVolumeService?
    /// Applies the preference to the live source; see `SettingsView`.
    var onPreferMusicOverVideoChange: ((Bool) -> Void)?

    var body: some View {
        Form {
            Section("Visualizer") {
                Toggle(isOn: visualizerBinding) {
                    SettingsLabel("Show a live spectrum",
                                  detail: "Needs System Audio Recording: System Settings → Privacy & Security → Screen & System Audio Recording.")
                }
                // Another mixer re-rendering audio is the one thing that
                // makes this drawing wrong in a way the user cannot see is
                // wrong, so it is stated here, beside the switch that turns
                // it on (Phase 6).
                if let warning = AppVolumeService.mixerConflictWarning(
                    names: appVolume?.conflictingMixers ?? []) {
                    MixerConflictWarning(warning: warning)
                }
            }

            PlayerAccessSection()

            // Hidden while no source reads the preference — see
            // `SystemMediaAdapter.isRegistered`. A control that changes
            // nothing is worse than a missing one: it invites the user to
            // fix a problem it cannot affect. The stored value and its
            // schema field are untouched, so the choice already made comes
            // back with the section when the source ships.
            if SystemMediaAdapter.isRegistered {
                Section("Other Players") {
                    Toggle(isOn: musicOverVideoBinding) {
                        SettingsLabel("Prefer music over video",
                                      detail: "For browsers and other players without their own integration: keeps a song from flickering into looking like a video. Spotify and Music always take priority.")
                    }
                }
            }
        }
        .settingsPage()
    }

    /// Persists the choice and applies it to the live source in one place,
    /// exactly as `visualizerBinding` does.
    private var musicOverVideoBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.preferMusicOverVideo },
            set: { on in
                settings.update { $0.preferMusicOverVideo = on }
                onPreferMusicOverVideoChange?(on)
            }
        )
    }

    /// Persists the choice and applies it live in one place.
    private var visualizerBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.visualizerEnabled },
            set: { on in
                settings.update { $0.visualizerEnabled = on }
                visualizer.setEnabled(on)
            }
        )
    }
}

/// Another audio mixer is running, so the spectrum may not match what is
/// heard.
private struct MixerConflictWarning: View {

    let warning: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(warning)
                Text(AppVolumeService.mixerConflictDetail)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}
