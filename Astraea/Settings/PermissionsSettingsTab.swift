import SwiftUI
import AppKit
import os

/// Whether Astraea may drive one scriptable player.
enum AutomationPermission: Equatable {
    case notInstalled
    case granted
    case denied
    /// Installed, but closed, so the check has not been made. Kept separate
    /// from `denied` deliberately: reporting "denied" for an app we never
    /// asked about would send the user to System Settings to fix nothing.
    case undetermined
}

/// Determines Automation permission by asking the system about the grant
/// for the same event the adapters send (`core`/`getd`, a property read),
/// never by assuming.
///
/// **Off the main actor.** This used to run an AppleScript on the main
/// actor every time the tab appeared, with no timeout — a hung player froze
/// the whole app for AppleScript's two-minute default. `NSAppleScript`
/// cannot leave the main thread (see `AppleScriptRunner`), so the probe now
/// uses `AEDeterminePermissionToAutomateTarget`, which can: it runs on a
/// detached task and the result is published back to the view.
///
/// It is still guarded by "is the player running", which is not cosmetic.
/// Measured on this machine 2026-08-28: `tell application "Music" to return
/// player state` **launched Music** from closed. The permission call does
/// not launch anything (a closed target answers `procNotFound`), but the
/// explicit check keeps the closed case a deliberate `.undetermined` rather
/// than an error code.
///
/// The cost is that a closed player reports `.undetermined` rather than a
/// definite answer. That is the honest result. The adapters settle it for
/// real on first playback.
@MainActor
enum AutomationProbe {

    private static let logger = Logger(subsystem: "com.techie.Astraea", category: "Permissions")

    static func check(appName: String, bundleID: String) async -> AutomationPermission {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            logger.notice("\(appName, privacy: .public): not installed")
            return .notInstalled
        }
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleID && !$0.isTerminated
        }
        guard running else {
            logger.notice("\(appName, privacy: .public): installed, not running — permission undetermined")
            return .undetermined
        }
        // Detached: the call can block — on tccd, and on the consent prompt
        // the first time — and the Settings window must never wait on it.
        let status = await Task.detached(priority: .userInitiated) {
            determinePermission(bundleID: bundleID)
        }.value
        let result = permission(forStatus: status)
        logger.notice(
            "\(appName, privacy: .public): Automation probe status \(status, privacy: .public) -> \(String(describing: result), privacy: .public)")
        return result
    }

    /// The blocking system call. Nonisolated so it runs on the detached
    /// task's thread, not the main actor. `askUserIfNeeded` keeps the old
    /// probe's behaviour: an unasked, running player raises the one-time
    /// prompt here, as the old Apple Event did.
    private nonisolated static func determinePermission(bundleID: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        // `aeDesc` points inside `target`, so `target` must outlive the call:
        // without this an optimised build may release it first.
        return withExtendedLifetime(target) {
            guard let address = target.aeDesc else { return OSStatus(paramErr) }
            return AEDeterminePermissionToAutomateTarget(
                address, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true)
        }
    }

    /// Maps the system's answer. Only an explicit -1743 is a denial; every
    /// other status — not yet asked (-1744), not running (-600), a timeout
    /// (-1712) — says nothing about the grant and stays `.undetermined`.
    /// Pure, for tests.
    nonisolated static func permission(forStatus status: OSStatus) -> AutomationPermission {
        switch Int(status) {
        case Int(noErr): return .granted
        case AppleScriptRunner.permissionDeniedCode: return .denied
        default: return .undetermined
        }
    }

    /// Privacy & Security → Automation.
    static func openSystemSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        logger.notice("Opening System Settings at Privacy & Security -> Automation")
        NSWorkspace.shared.open(url)
    }
}

/// One scriptable player Astraea can be granted access to.
struct AutomationTarget: Identifiable {
    let id: String
    let displayName: String
    let appName: String

    static let spotify = AutomationTarget(
        id: SpotifyAdapter.bundleID, displayName: "Spotify", appName: "Spotify")
    static let music = AutomationTarget(
        id: MusicAdapter.bundleID, displayName: "Music", appName: "Music")
}

/// Automation permission per player.
///
/// Both players are AppleScript only and need no account, so there is
/// deliberately no connection UI here.
struct PermissionsSettingsTab: View {

    private static let targets: [AutomationTarget] = [.spotify, .music]

    @State private var states: [String: AutomationPermission] = [:]
    /// One probe pass at a time, so "Check again" pressed during a slow
    /// probe cannot stack a second one behind it.
    @State private var probing = false

    var body: some View {
        Form {
            Section {
                ForEach(Self.targets) { target in
                    PermissionRow(target: target, state: states[target.id] ?? .undetermined)
                }
            } footer: {
                Text("Astraea reads and controls playback with AppleScript. Apple Music needs no account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Check again") { Task { await probeAll() } }
                .disabled(probing)
        }
        .formStyle(.grouped)
        .padding()
        // On appear and on demand only. Never on a timer: an Automation
        // grant changes when the user changes it, and hard rule 9 forbids
        // a poll with no suspend path. The probe itself runs off the main
        // actor; the rows update as each answer lands.
        .task { await probeAll() }
    }

    private func probeAll() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }
        for target in Self.targets {
            states[target.id] = await AutomationProbe.check(
                appName: target.appName, bundleID: target.id)
        }
    }
}

/// One player's row. Denied is the only state that offers a remedy.
private struct PermissionRow: View {

    let target: AutomationTarget
    let state: AutomationPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(target.displayName) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(tint)
                    Text(label)
                    if state == .denied {
                        Spacer()
                        Button("Open System Settings…") { AutomationProbe.openSystemSettings() }
                    }
                }
            }
            if state == .denied {
                Text("Astraea needs Automation access to read and control playback in \(target.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var symbol: String {
        switch state {
        case .notInstalled: "minus.circle"
        case .granted: "checkmark.circle.fill"
        case .denied: "exclamationmark.triangle.fill"
        case .undetermined: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .notInstalled: .secondary
        case .granted: .green
        case .denied: .orange
        case .undetermined: .secondary
        }
    }

    private var label: String {
        switch state {
        case .notInstalled: "Not installed"
        case .granted: "Allowed"
        case .denied: "Denied"
        case .undetermined: "Checked when \(target.displayName) is open"
        }
    }
}
