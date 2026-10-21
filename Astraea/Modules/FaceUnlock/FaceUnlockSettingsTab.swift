import SwiftUI

/// Settings → Face Unlock: the session, enrolled faces, the stored Mac
/// password, and unlocking the Mac with them at the lock screen.
///
/// Opening the page never prompts. The owner check (Touch ID or the Mac
/// password) runs only from a control that needs it; with the session
/// already unlocked, the faces load without one. Anything that weakens
/// Face Unlock asks again even then (`FaceOwnerGate`).
struct FaceUnlockSettingsTab: View {
    let store: FaceEnrollmentStore
    let passwordStore: FacePasswordStore
    let settings: SettingsStore
    let coordinator: FaceUnlockCoordinator?

    /// Non-nil while the enrolment sheet is up. `replacing` is nil for a new
    /// face. Holds a decrypted identity, so it is cleared on lock.
    @State private var enrolling: FaceEnrolmentTarget?
    @State private var pendingDelete: FaceIdentity?
    @State private var confirmDeleteAll = false
    @State private var actionError: String?

    private var session: FaceUnlockSession { store.session }
    private var gate: FaceOwnerGate { FaceOwnerGate(store: store) }

    var body: some View {
        Form {
            FaceSessionSection(session: session, settings: settings, gate: gate,
                               hasEncryptedData: hasEncryptedData,
                               onUnlock: { Task { await store.unlock() } })
            FaceEnrolledFacesSection(store: store, actionError: actionError,
                                     onAdd: { enrol(replacing: nil) },
                                     onToggle: toggle,
                                     onRecapture: { if session.isUnlocked { enrol(replacing: $0) } },
                                     onDelete: { pendingDelete = $0 },
                                     onDeleteAll: { confirmDeleteAll = true })
            FacePasswordSection(passwordStore: passwordStore, session: session,
                                requireKey: { await gate.requireKeyAndFreshOwner(reason: "change the Mac password Face Unlock types") })
            FaceLockScreenSection(settings: settings, coordinator: coordinator, gate: gate)
            FaceUnlockWarningSection()
        }
        .formStyle(.grouped)
        .padding()
        // Never prompts: loads the faces only when the owner is already
        // verified (unlocked earlier, or just now by a button).
        .task(id: session.state) {
            passwordStore.refresh()
            if session.isOwnerVerified { await store.unlock() }
        }
        // Locked, or the key went missing: drop every decrypted identity
        // this view still holds, which also closes the enrolment sheet.
        .onChange(of: session.state) { _, state in
            guard state != .unlocked else { return }
            enrolling = nil
            pendingDelete = nil
        }
        .sheet(item: $enrolling) { target in
            FaceEnrollmentSheet(store: store, replacing: target.replacing) { enrolling = nil }
        }
        .modifier(FaceDeleteConfirmations(store: store, pendingDelete: $pendingDelete,
                                          confirmDeleteAll: $confirmDeleteAll,
                                          onDelete: { identity in perform { try store.delete(identity.id) } }))
    }

    /// File checks, which nothing observes; reading the stores' state here
    /// re-evaluates them whenever a save or a delete changes what is on disk.
    private var hasEncryptedData: Bool {
        _ = (store.state, store.identities.count, passwordStore.hasStoredPassword)
        return session.hasEncryptedData
    }

    /// A new face, or a recapture, is a face that will unlock the Mac: it
    /// needs the key and a fresh owner check.
    private func enrol(replacing identity: FaceIdentity?) {
        Task {
            let reason = identity == nil ? "add a face to Face Unlock" : "recapture a face for Face Unlock"
            guard await gate.requireKeyAndFreshOwner(reason: reason), store.state == .ready else { return }
            enrolling = FaceEnrolmentTarget(replacing: identity)
        }
    }

    /// Enabling a face lets it unlock the Mac, so it asks first; disabling
    /// does not.
    private func toggle(_ identity: FaceIdentity, _ isOn: Bool) {
        gate.apply(weakens: isOn, reason: "let this face unlock your Mac") {
            perform { try store.setEnabled(isOn, for: identity.id) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }
}
