import SwiftUI

/// How each feature presents in Settings: icon, colour, one-line summary
/// and position. Keyed by permanent `ModuleID`, so it is presentation only
/// and nothing here is persisted.
struct FeatureStyle {
    let symbol: String
    let tint: Color
    let summary: String
    let order: Int

    /// A module this table does not know yet still gets a row, last.
    static let fallback = FeatureStyle(symbol: "puzzlepiece.extension.fill", tint: .gray,
                                       summary: "", order: .max)

    static func style(for id: ModuleID) -> FeatureStyle {
        switch id {
        case "media":
            FeatureStyle(symbol: "music.note", tint: .pink,
                         summary: "Track, artwork and playback controls.", order: 0)
        case "system-stats":
            FeatureStyle(symbol: "cpu.fill", tint: .orange,
                         summary: "CPU, memory and battery at a glance.", order: 1)
        case "clipboard":
            FeatureStyle(symbol: "doc.on.clipboard.fill", tint: .teal,
                         summary: "A history of what you copy.", order: 2)
        case "file-shelf":
            FeatureStyle(symbol: "tray.full.fill", tint: .brown,
                         summary: "Holds files you drag onto the notch.", order: 3)
        case "app-volume":
            FeatureStyle(symbol: "speaker.wave.2.fill", tint: .purple,
                         summary: "Each app's volume and output.", order: 4)
        case "window-layout":
            FeatureStyle(symbol: "rectangle.3.group.fill", tint: .blue,
                         summary: "Drag a window to the notch to snap it into a layout.", order: 5)
        case "updates":
            FeatureStyle(symbol: "arrow.down.circle.fill", tint: .indigo,
                         summary: "Shows new versions in the notch.", order: 6)
        default:
            fallback
        }
    }
}

/// One switch per registered feature, each with its icon and a line on what
/// it does. Feature-specific options live on that feature's own page (Music)
/// or directly under its switch here (App Volume's taps, Window Layouts'
/// layouts).
struct FeaturesSettingsTab: View {

    let coordinator: NotchCoordinator
    /// Observed so the rows re-render when a preference is written.
    @Bindable var settings: SettingsStore
    /// Nil in tests; the taps toggle then does not render.
    var appVolume: AppVolumeService?

    private var features: [(id: ModuleID, displayName: String, isEnabled: Bool)] {
        coordinator.moduleSummaries.sorted {
            FeatureStyle.style(for: $0.id).order < FeatureStyle.style(for: $1.id).order
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach(features, id: \.id) { feature in
                    let style = FeatureStyle.style(for: feature.id)
                    let isOn = binding(for: feature.id, current: feature.isEnabled)
                    Toggle(isOn: isOn) {
                        SettingsRowLabel(title: feature.displayName, symbol: style.symbol,
                                         tint: style.tint,
                                         detail: style.summary.isEmpty ? nil : style.summary)
                    }
                    if feature.id == "app-volume", isOn.wrappedValue, let appVolume {
                        tapsToggle(appVolume)
                    }
                    if feature.id == "window-layout", isOn.wrappedValue {
                        WindowLayoutsOptions(settings: settings)
                    }
                }
            } footer: {
                SettingsFooter("A feature that is off uses no CPU and no battery.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Indented under App Volume, and only while it is on: it does nothing
    /// without the feature it belongs to.
    private func tapsToggle(_ appVolume: AppVolumeService) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Adjust other apps' volume", isOn: tapsBinding(appVolume))
            SettingsFooter("For browsers, Discord and the like. Asks for System Audio Recording. Spotify and Music need no permission.")
        }
        .padding(.leading, 30)
    }

    private func binding(for id: ModuleID, current: Bool) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(id, default: current) },
            set: {
                coordinator.setEnabled($0, for: id)
                // Moving windows needs Accessibility; ask at the toggle, the
                // way the taps toggle asks for audio recording at its own.
                if id == "window-layout", $0 { WindowLayoutModule.requestAccessibilityIfNeeded() }
            }
        )
    }

    /// The prompt appears right here, at the toggle (v1 plan, decision 3),
    /// via the engine's probe start — on its queue, never this thread.
    private func tapsBinding(_ appVolume: AppVolumeService) -> Binding<Bool> {
        Binding(
            get: { settings.settings.appVolume.tapsEnabled ?? false },
            set: { appVolume.setTapsEnabled($0) }
        )
    }
}
