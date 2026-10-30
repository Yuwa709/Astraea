import SwiftUI
import Sparkle

/// One sidebar row. An enum rather than free-floating views so the order,
/// the labels and the detail switch cannot drift apart.
///
/// There is no Permissions page. All it ever held was Spotify's and Music's
/// Automation access, which is a music concern, so it lives in Music now.
/// Window Layouts has a page of its own: its list of layouts outgrew a row
/// tucked under a switch on Features.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, features, music, windowLayouts, faceUnlock, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .features: "Features"
        case .music: "Music"
        case .windowLayouts: "Window Layouts"
        case .faceUnlock: "Face Unlock"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .features: "square.grid.2x2.fill"
        case .music: "music.note"
        case .windowLayouts: "rectangle.3.group.fill"
        case .faceUnlock: "faceid"
        case .about: "info.circle.fill"
        }
    }

    /// The feature whose options this page holds, if it is one feature's
    /// page. The one map between features and pages: the Features rows'
    /// info buttons and these pages' tints both read it.
    var feature: ModuleID? {
        switch self {
        case .music: "media"
        case .windowLayouts: "window-layout"
        case .about: "updates"
        case .general, .features, .faceUnlock: nil
        }
    }

    /// A feature's page takes the feature's colour, so the sidebar and the
    /// Features row can never disagree.
    var tint: Color {
        if let feature { return FeatureStyle.style(for: feature).tint }
        switch self {
        case .features: return .blue
        case .faceUnlock: return .green
        default: return .gray
        }
    }

    /// The page holding a feature's own options, if it has one.
    static func page(for feature: ModuleID) -> SettingsSection? {
        allCases.first { $0.feature == feature }
    }

    /// The sidebar's groups, separated the way System Settings separates
    /// its own: the app as a whole, then each feature's page, then About.
    /// Every case appears exactly once, in `allCases` order.
    static let groups: [[SettingsSection]] = [
        [.general, .features],
        [.music, .windowLayouts, .faceUnlock],
        [.about],
    ]
}

/// The settings window.
///
/// A sidebar rather than a `TabView`: the tab bar collapsed into a toolbar
/// overflow menu whenever the window was narrow, which put every section
/// three clicks away. `minWidth` below is what guarantees the sidebar can
/// never collapse into that state again, so it is load-bearing rather than
/// cosmetic.
///
/// No `navigationTitle` on the detail: it would retitle the window, and the
/// window is found by its "Astraea Settings" title.
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
            List(selection: $selection) {
                ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                    Section {
                        ForEach(group) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                SettingsIcon(symbol: section.symbol, tint: section.tint)
                            }
                            .tag(section)
                        }
                    }
                }
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
                                appVolume: appVolume, onOpen: { selection = $0 })
        case .music:
            MusicSettingsTab(settings: settings, visualizer: visualizer,
                             appVolume: appVolume,
                             onPreferMusicOverVideoChange: onPreferMusicOverVideoChange)
        case .windowLayouts:
            WindowLayoutsSettingsTab(coordinator: coordinator, settings: settings)
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
