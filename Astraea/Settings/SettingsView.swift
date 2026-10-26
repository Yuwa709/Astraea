import SwiftUI
import Sparkle

/// One sidebar row. An enum rather than free-floating views so the order,
/// the labels and the detail switch cannot drift apart.
///
/// There is no Permissions page. All it ever held was Spotify's and Music's
/// Automation access, which is a music concern, so it lives in Music now.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, features, music, faceUnlock, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .features: "Features"
        case .music: "Music"
        case .faceUnlock: "Face Unlock"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .features: "square.grid.2x2.fill"
        case .music: "music.note"
        case .faceUnlock: "faceid"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .features: .blue
        case .music: .pink
        case .faceUnlock: .green
        case .about: .indigo
        }
    }
}

/// The settings window.
///
/// A sidebar rather than a `TabView`: the tab bar collapsed into a toolbar
/// overflow menu whenever the window was narrow, which put every section
/// three clicks away. `minWidth` below is what guarantees the sidebar can
/// never collapse into that state again, so it is load-bearing rather than
/// cosmetic.
struct SettingsView: View {

    let coordinator: NotchCoordinator
    let settings: SettingsStore
    let visualizer: AudioVisualizerService
    /// The mixer service, for the taps toggle (Phase 5). Optional so tests
    /// build the view without one; the toggle then does not render.
    var appVolume: AppVolumeService?
    /// Enrolled faces. Optional so tests build the view without one; the
    /// Face Unlock page then shows nothing.
    var faceStore: FaceEnrollmentStore?
    /// The stored Mac password for Face Unlock. Optional for the same
    /// reason; the page needs both.
    var facePasswordStore: FacePasswordStore?
    /// Lock-screen Face Unlock's status and permissions. Optional for the
    /// same reason.
    var faceUnlockCoordinator: FaceUnlockCoordinator?
    /// Optional so the tab stays constructible without a live Sparkle
    /// updater — tests build it with nil, and the Check for Updates row
    /// simply does not render.
    let updater: SPUUpdater?
    /// What a scheduled check found. Optional for the same reason; the
    /// About row then only offers the manual check.
    var updates: UpdateService?
    /// Injected rather than calling `NSApp.terminate` inline, so the view
    /// stays free of app lifecycle and a test can build one.
    let onQuit: () -> Void
    /// Applies the music-over-video preference to the live system media
    /// source. Injected the way `visualizer` is: under
    /// `@NSApplicationDelegateAdaptor`, `NSApp.delegate` is SwiftUI's own
    /// adaptor object, so the old `NSApp.delegate as? AppDelegate` lookup
    /// was nil and the toggle did nothing until relaunch. Nil in tests.
    var onPreferMusicOverVideoChange: ((Bool) -> Void)?

    /// Optional because that is the shape `List` selection binds to; the
    /// detail falls back to General so the pane is never blank.
    @State private var selection: SettingsSection? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label {
                    Text(section.title)
                } icon: {
                    SettingsIcon(symbol: section.symbol, tint: section.tint)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 240)
        } detail: {
            detail(for: selection ?? .general)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // A fresh identity per section. The detail pane keeps one
                // scroll view across selection changes, so without this a tab
                // opened at whatever offset the previous one had been left at.
                .id(selection ?? .general)
        }
        // Roughly System Settings' own proportions. The minimum is the point:
        // below it the split view starts collapsing the sidebar.
        .frame(minWidth: 715, minHeight: 500)
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general:
            GeneralSettingsTab(coordinator: coordinator, settings: settings)
        case .features:
            FeaturesSettingsTab(coordinator: coordinator, settings: settings,
                                appVolume: appVolume)
        case .music:
            MusicSettingsTab(settings: settings, visualizer: visualizer,
                             appVolume: appVolume,
                             onPreferMusicOverVideoChange: onPreferMusicOverVideoChange)
        case .faceUnlock:
            if let faceStore, let facePasswordStore {
                FaceUnlockSettingsTab(store: faceStore, passwordStore: facePasswordStore,
                                      settings: settings, coordinator: faceUnlockCoordinator)
            }
        case .about:
            AboutSettingsTab(updater: updater, updates: updates, onQuit: onQuit)
        }
    }
}

/// A white SF Symbol on a tinted rounded square, as System Settings draws
/// its sidebar. Shared by the sidebar and the Features rows so the two read
/// as one family.
struct SettingsIcon: View {

    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient,
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row's label with an icon in front, for settings rows that need one.
struct SettingsRowLabel: View {

    let title: String
    let symbol: String
    let tint: Color
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The caption style every section footer uses.
struct SettingsFooter: View {

    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
