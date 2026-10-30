import SwiftUI
import ServiceManagement
import os

/// How Astraea starts and how the notch responds to the pointer.
struct GeneralSettingsTab: View {

    let coordinator: NotchCoordinator
    @Bindable var settings: SettingsStore

    var body: some View {
        Form {
            Section("Startup") {
                LaunchAtLoginRow()
                Toggle(isOn: menuBarIconBinding) {
                    SettingsLabel("Show menu bar icon",
                                  detail: settings.settings.showMenuBarIcon ? nil
                                      : "Settings stays reachable from the gear in the notch, and Quit is in About.")
                }
            }

            Section("Notch") {
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: hoverDelayBinding, in: 0...1, step: 0.05)
                            .labelsHidden()
                            .accessibilityLabel("Hover delay")
                        Text("\(Int((settings.settings.hoverEnterDelay * 1000).rounded())) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 58, alignment: .trailing)
                    }
                    .frame(maxWidth: 260)
                } label: {
                    SettingsLabel("Hover delay",
                                  detail: "How long the pointer rests on the notch before it opens.")
                }
                Toggle(isOn: reopenLastPageBinding) {
                    SettingsLabel("Reopen last page",
                                  detail: "Opens where you left off, such as Clipboard, instead of the home screen.")
                }
                Toggle(isOn: hapticsBinding) {
                    SettingsLabel("Haptic feedback",
                                  detail: "Ticks the trackpad as the notch opens and as you drag a window across layout zones.")
                }
            }
        }
        .settingsPage()
    }

    /// Writes straight through to the store; `MenuBarExtra(isInserted:)`
    /// observes the same value, so the icon appears and disappears live.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.showMenuBarIcon },
            set: { on in settings.update { $0.showMenuBarIcon = on } }
        )
    }

    private var reopenLastPageBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.reopenLastPage },
            set: { coordinator.setReopenLastPage($0) }
        )
    }

    private var hapticsBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.hapticsEnabled },
            set: { coordinator.setHapticsEnabled($0) }
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

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Settings")

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
        Toggle("Launch Astraea at login", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, enable in
                apply(enable)
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        if status == .requiresApproval {
            LabeledContent {
                Button("Open Login Items…") {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } label: {
                SettingsNote(text: "Needs your approval in System Settings → General → Login Items before it takes effect.")
            }
        }
        if let registrationError {
            SettingsNote(text: registrationError, symbol: "xmark.octagon.fill", tint: .red)
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
