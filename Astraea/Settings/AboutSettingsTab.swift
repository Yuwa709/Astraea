import SwiftUI
import Sparkle
import Combine
import os

/// Identity, licence, and the app's only guaranteed way out.
///
/// Quit lives here because the menu bar icon is optional: with it hidden
/// there is no Dock icon, no app menu, and no other menu to reach. It is a
/// tab rather than a category of its own — a sidebar entry holding one
/// destructive button would be worse than a footer under the information it
/// belongs with.
///
/// **Check for Updates belongs beside it** for exactly the same reason: an
/// updater reachable only from a menu that may not exist is not reachable.
struct AboutSettingsTab: View {

    let updater: SPUUpdater?
    var updates: UpdateService?
    let onQuit: () -> Void

    /// Optional rather than force-unwrapped; the link just does not render
    /// if it ever fails to parse.
    private static let repositoryURL = URL(string: "https://github.com/Yuwa709/Astraea")

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "Version \(short) (build \(build))"
    }

    var body: some View {
        Form {
            Section {
                AboutIdentityRow(version: version, repositoryURL: Self.repositoryURL)
            }

            if let updater {
                Section("Software Update") {
                    UpdateCheckRow(updater: updater, updates: updates)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit Astraea", role: .destructive, action: onQuit)
                }
            }
        }
        .settingsPage()
    }
}

/// The app's icon, name, version, licence and source link, centred the way
/// a Mac app's About panel shows them.
private struct AboutIdentityRow: View {

    let version: String
    let repositoryURL: URL?

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
            Text("Astraea")
                .font(.title2.weight(.semibold))
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("MIT licensed. Free and open source.")
                .font(.callout)
                .foregroundStyle(.secondary)
            // Must stay the same account the appcast is served from
            // (SUFeedURL in Info.plist), or the About tab points somewhere
            // other than where updates come from.
            if let repositoryURL {
                Link("github.com/Yuwa709/Astraea", destination: repositoryURL)
                    .font(.callout)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Settings")

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
            return "Astraea \(available) is available."
        }
        if updates?.automaticChecksEnabled == true {
            return "Checks once a day and shows new versions in the notch."
        }
        return "Checks only when you ask. Turn on Update Notices in Features to be told in the notch."
    }

    var body: some View {
        LabeledContent {
            // Sparkle activates the app itself to show its windows for a
            // background agent: the same narrow click-driven carve-out to
            // hard rule 4 the settings gear documents. No hover path
            // reaches this.
            Button(available == nil ? "Check for Updates…" : "Install Update…") {
                Self.logger.notice("Update check requested from Settings")
                updater.checkForUpdates()
            }
            .disabled(!model.canCheckForUpdates && available == nil)
        } label: {
            SettingsLabel("Updates", detail: detail)
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
