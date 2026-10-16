import SwiftUI
import ServiceManagement
import Sparkle
import Combine
import os

/// One sidebar row. An enum rather than free-floating views so the order,
/// the labels and the detail switch cannot drift apart.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, modules, music, faceUnlock, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .modules: "Modules"
        case .music: "Music"
        case .faceUnlock: "Face Unlock"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .modules: "square.stack"
        case .music: "music.note"
        case .faceUnlock: "faceid"
        case .permissions: "lock.shield"
        case .about: "info.circle"
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
                Label(section.title, systemImage: section.symbol)
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
        case .modules:
            ModulesSettingsTab(coordinator: coordinator, settings: settings,
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
        case .permissions:
            PermissionsSettingsTab()
        case .about:
            AboutSettingsTab(updater: updater, updates: updates, onQuit: onQuit)
        }
    }
}

/// Everything about what is playing, in one place.
///
/// Was a Spotify-only tab, with the audio visualiser stranded over in
/// Modules despite being purely a now-playing concern. Both are here now;
/// Modules keeps only the on/off switches that every feature has.
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
            // Hidden while no source reads the preference — see
            // `SystemMediaAdapter.isRegistered`. A control that changes
            // nothing is worse than a missing one: it invites the user to
            // fix a problem it cannot affect. The stored value and its
            // schema field are untouched, so the choice already made comes
            // back with the section when the source ships.
            if SystemMediaAdapter.isRegistered {
                Section {
                    Toggle("Prefer music over video", isOn: musicOverVideoBinding)
                } header: {
                    Text("Other Players")
                } footer: {
                    Text("For players without their own integration — a browser, say — the notch ignores an update that drops the album of the track it is already showing, so a song does not flicker into looking like a video. Starting something genuinely different always takes over. Spotify and Apple Music are unaffected; they always take priority. On by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Show a live spectrum", isOn: visualizerBinding)
                // Another mixer re-rendering audio is the one thing that
                // makes this drawing wrong in a way the user cannot see is
                // wrong, so it is stated here, beside the switch that turns
                // it on (Phase 6).
                if let warning = AppVolumeService.mixerConflictWarning(
                    names: appVolume?.conflictingMixers ?? []) {
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
            } header: {
                Text("Audio Visualizer")
            } footer: {
                Text("Draws what's playing in the notch. Needs the System Audio Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording). Off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
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

    /// Moved here from Modules unchanged: persists the choice and applies it
    /// live in one place.
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

/// One row per registered module. The player is listed like anything else —
/// it simply defaults to on.
struct ModulesSettingsTab: View {

    let coordinator: NotchCoordinator
    /// Observed so the rows re-render when a preference is written.
    @Bindable var settings: SettingsStore
    /// Nil in tests; the taps section then does not render.
    var appVolume: AppVolumeService?

    var body: some View {
        Form {
            Section {
                ForEach(coordinator.moduleSummaries, id: \.id) { module in
                    Toggle(module.displayName, isOn: binding(for: module.id, current: module.isEnabled))
                }
            } footer: {
                Text("Disabled features stop sampling entirely — they use no CPU and no battery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let appVolume {
                Section {
                    Toggle("Adjust other apps' volume", isOn: tapsBinding(appVolume))
                } footer: {
                    Text("Lets App Volume turn down apps like browsers and Discord. Turning it on asks for the System Audio Recording permission. Spotify and Music use their own volume and need no permission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func binding(for id: ModuleID, current: Bool) -> Binding<Bool> {
        Binding(
            get: { settings.isEnabled(id, default: current) },
            set: { coordinator.setEnabled($0, for: id) }
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

struct GeneralSettingsTab: View {

    let coordinator: NotchCoordinator
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            LaunchAtLoginRow()

            Section {
                Toggle("Show menu bar icon", isOn: menuBarIconBinding)
            } footer: {
                Text("With it hidden, Settings is still reachable from the gear in the notch, and Quit lives in the About tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Hover delay") {
                HStack(spacing: 10) {
                    Slider(value: hoverDelayBinding, in: 0...1, step: 0.05)
                    Text("\(Int((settings.settings.hoverEnterDelay * 1000).rounded())) ms")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    /// Writes straight through to the store; `MenuBarExtra(isInserted:)`
    /// observes the same value, so the icon appears and disappears live.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.showMenuBarIcon },
            set: { on in settings.update { $0.showMenuBarIcon = on } }
        )
    }

    /// How long the cursor must dwell before the notch opens. Applies live.
    private var hoverDelayBinding: Binding<TimeInterval> {
        Binding(
            get: { settings.settings.hoverEnterDelay },
            set: { coordinator.setHoverDelay($0) }
        )
    }
}

/// The launch-at-login switch, through `SMAppService.mainApp`.
///
/// Four statuses, not two. `.requiresApproval` means the registration took
/// but the user has to allow it under Login Items before it does anything —
/// it reads as on, with a line saying so and a way there. Status is re-read
/// whenever the tab appears and whenever the app comes back to the front,
/// which is how the user returns from approving it in System Settings.
private struct LaunchAtLoginRow: View {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Settings")

    @State private var status = SMAppService.mainApp.status
    @State private var launchAtLogin = Self.isRegistered(SMAppService.mainApp.status)
    @State private var registrationError: String?

    /// Registered, whether or not the user has approved it yet.
    private static func isRegistered(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    /// For the log; the imported enum describes itself only by raw value.
    private static func name(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval"
        case .notFound: "not found"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    var body: some View {
        Toggle("Launch PopNotch at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enable in
                apply(enable)
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if status == .requiresApproval {
            HStack {
                Text("Needs your approval in System Settings → General → Login Items before it takes effect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
        if let registrationError {
            Text(registrationError)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Adopts the real status. Setting the toggle re-fires `onChange`, and
    /// `apply`'s guard makes that a no-op because the two now agree.
    private func refresh() {
        let current = SMAppService.mainApp.status
        if current != status {
            Self.logger.notice("Launch at login status: \(Self.name(current), privacy: .public)")
        }
        status = current
        launchAtLogin = Self.isRegistered(current)
    }

    private func apply(_ enable: Bool) {
        // A failed attempt reverts the toggle, which re-fires onChange;
        // matching against the real status makes that re-fire a no-op.
        guard Self.isRegistered(SMAppService.mainApp.status) != enable else { return }

        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            registrationError = nil
            status = SMAppService.mainApp.status
            Self.logger.notice("Launch at login \(enable ? "registered" : "unregistered", privacy: .public); status \(Self.name(status), privacy: .public)")
        } catch {
            registrationError = "Could not \(enable ? "enable" : "disable") launch at login: \(error.localizedDescription)"
            Self.logger.error("Launch at login \(enable ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            status = SMAppService.mainApp.status
            launchAtLogin = !enable
        }
    }
}


/// Identity, licence, and the app's only guaranteed way out.
///
/// Quit lives here because the menu bar icon is optional: with it hidden
/// there is no Dock icon, no app menu, and no other menu to reach. It is a
/// tab rather than a category of its own — a sidebar entry holding one
/// destructive button would be worse than a footer under the information it
/// belongs with.
///
/// **Check for Updates belongs beside it** when Sparkle lands (Phase 5), for
/// exactly the same reason: an updater reachable only from a menu that may
/// not exist is not reachable. The spacer below is the room for it.
struct AboutSettingsTab: View {

    let updater: SPUUpdater?
    var updates: UpdateService?
    let onQuit: () -> Void

    /// Optional rather than force-unwrapped; the link just does not render
    /// if it ever fails to parse.
    private static let repositoryURL = URL(string: "https://github.com/Yuwa709/PopNotch")

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (build \(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PopNotch")
                    .font(.system(size: 20, weight: .semibold))
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("MIT licensed. Free and open source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                // Must stay the same account the appcast is served from
                // (SUFeedURL in Info.plist), or the About tab points somewhere
                // other than where updates come from.
                if let repository = Self.repositoryURL {
                    Link("github.com/Yuwa709/PopNotch", destination: repository)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let updater {
                Spacer(minLength: 16)
                UpdateCheckRow(updater: updater, updates: updates)
            }

            // Keeps Quit pinned to the bottom.
            Spacer(minLength: 16)

            Divider()
            HStack {
                Spacer()
                Button("Quit PopNotch", role: .destructive, action: onQuit)
            }
            .padding(.top, 12)
        }
        .padding()
    }
}


/// Update check, in About because the menu bar icon is optional — an
/// updater reachable only from a menu that may not exist is not reachable.
///
/// Mirrors the notch: when a scheduled check has found something the row
/// says which version and the button installs it, the same hand-off to
/// Sparkle the notch card makes. Otherwise it is the manual check.
///
/// Its own view so the `@StateObject` below only exists when there is an
/// updater to observe.
private struct UpdateCheckRow: View {

    private static let logger = Logger(subsystem: "com.techie.PopNotch", category: "Settings")

    let updater: SPUUpdater
    var updates: UpdateService?
    @StateObject private var model: UpdateCheckModel

    init(updater: SPUUpdater, updates: UpdateService?) {
        self.updater = updater
        self.updates = updates
        _model = StateObject(wrappedValue: UpdateCheckModel(updater: updater))
    }

    private var available: String? { updates?.availableVersion }

    private var detail: String {
        if let available {
            return "PopNotch \(available) is available."
        }
        if updates?.automaticChecksEnabled == true {
            return "Checks once a day and shows new versions in the notch."
        }
        return "Checks only when you ask. Turn on Update Notices in Modules to be told in the notch."
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Updates")
                    .font(.callout)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Sparkle activates the app itself to show its windows for a
            // background agent: the same narrow click-driven carve-out to
            // hard rule 4 the settings gear documents. No hover path
            // reaches this.
            Button(available == nil ? "Check for Updates…" : "Install Update…") {
                Self.logger.notice("Update check requested from Settings")
                updater.checkForUpdates()
            }
            .disabled(!model.canCheckForUpdates && available == nil)
        }
    }
}

/// Bridges Sparkle's `canCheckForUpdates` into SwiftUI.
///
/// The property is KVO-compliant but `SPUUpdater` is not an
/// `ObservableObject`, so a button bound straight to it would never re-render
/// — it would sit enabled through a running check and disabled forever after
/// one. This is the bridge Sparkle's own SwiftUI guidance describes.
@MainActor
private final class UpdateCheckModel: ObservableObject {

    @Published var canCheckForUpdates: Bool
    private var cancellable: AnyCancellable?

    init(updater: SPUUpdater) {
        canCheckForUpdates = updater.canCheckForUpdates
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] value in self?.canCheckForUpdates = value }
    }
}
