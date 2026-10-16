import SwiftUI

/// Settings → Face Unlock → Session: whether the key is in memory, the way
/// to unlock or lock it, and how long it may sit unused.
///
/// Nothing here prompts on its own. The owner check runs only from the
/// Unlock button (or from another button on the page that needs the key).
struct FaceSessionSection: View {
    let session: FaceUnlockSession
    @Bindable var settings: SettingsStore
    /// A longer auto-lock asks the owner first.
    let gate: FaceOwnerGate
    /// Faces or a password are on disk, so there is something to unlock.
    let hasEncryptedData: Bool
    let onUnlock: () -> Void

    var body: some View {
        Section {
            status
            if session.state == .keyMissing {
                Label {
                    Text(FaceUnlockSession.keyMissingMessage).font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else if session.state == .locked, let error = session.lastError {
                Text("Not unlocked: \(error)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Picker("Auto-lock after", selection: interval) {
                ForEach(AutoLockInterval.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Session")
        } footer: {
            Text("After this long without use, Face Unlock locks and needs Touch ID or your password again. With \u{201C}Unlock the Mac at the lock screen\u{201D} on and a password stored, it also stays unlocked across restarts until then, or until Lock Now.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session.state {
        case .locked where hasEncryptedData:
            LabeledContent {
                Button("Unlock…", action: onUnlock)
            } label: {
                Label("Face Unlock is locked", systemImage: "lock.fill")
            }
            Text("Touch ID or your Mac password is needed before PopNotch shows or changes your faces and stored password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .locked:
            LabeledContent {
                Text("Nothing stored yet")
            } label: {
                Label("Locked", systemImage: "lock.fill")
            }
        case .unlocking:
            LabeledContent {
                ProgressView().controlSize(.small)
            } label: {
                Label("Waiting for Touch ID or your password…", systemImage: "lock.fill")
            }
        case .unlocked:
            LabeledContent {
                Button("Lock Now") { session.lock() }
            } label: {
                Label("Unlocked", systemImage: "lock.open.fill")
            }
        case .keyMissing:
            LabeledContent {
                Button("Lock Now") { session.lock() }
            } label: {
                Label("Unlocked, key missing", systemImage: "lock.open.fill")
            }
        }
    }

    /// Written through the settings store like every other tab; the
    /// auto-locker reads the same value and reschedules on its own. A
    /// longer interval asks the owner first; a shorter one does not.
    /// Unauthenticated: `faceUnlock*` settings are plain UserDefaults, which
    /// any process running as the user can rewrite (review finding L1).
    private var interval: Binding<AutoLockInterval> {
        Binding(
            get: { settings.settings.faceUnlockAutoLockInterval },
            set: { value in
                let current = settings.settings.faceUnlockAutoLockInterval
                gate.apply(weakens: value.isLonger(than: current), reason: "keep Face Unlock unlocked for longer") {
                    settings.update { $0.faceUnlockAutoLockInterval = value }
                }
            }
        )
    }
}
