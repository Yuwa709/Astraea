import SwiftUI

/// What Face Unlock does and does not protect against, stated plainly.
struct FaceUnlockWarningSection: View {
    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 6) {
                    Text("When it recognises an enrolled face at the lock screen, PopNotch types your Mac password. This is not Face ID: a MacBook camera sees a flat image. The liveness check rejects a photo it catches on a phone or screen, but a printed photo or a video of you may still fool it. Anyone who can make it match gets your password typed. Face unlock is a convenience, not a security upgrade.")
                    Text("Your password and face data are encrypted with a key kept in your login keychain. The Touch ID or password check is enforced by PopNotch, not by the keychain, so any software running as you could read them.")
                    Text("On a Mac with several accounts, if you pick another account at the lock screen while looking at the camera, Face Unlock may type your password into that account's field.")
                }
                .font(.caption)
            } icon: {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
            }
        } header: {
            Text("Before You Rely on It")
        }
    }
}

struct FaceIdentityRow: View {
    let identity: FaceIdentity
    let onToggle: (Bool) -> Void
    let onRecapture: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(identity.name)
                Text(identity.isStale ? "Made with an older face model. Recapture to use it."
                                      : "\(identity.samples.count) samples")
                    .font(.caption)
                    .foregroundStyle(identity.isStale ? .orange : .secondary)
            }
            Spacer()
            Toggle("Use", isOn: Binding(get: { identity.isEnabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            Menu {
                Button("Recapture…", action: onRecapture)
                Button("Delete…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

/// The enrolment sheet's subject: `replacing` is nil for a new face.
struct FaceEnrolmentTarget: Identifiable {
    let id = UUID()
    let replacing: FaceIdentity?
}

/// The tab's two delete confirmations, hung off one view rather than off
/// the section's rows.
struct FaceDeleteConfirmations: ViewModifier {
    let store: FaceEnrollmentStore
    @Binding var pendingDelete: FaceIdentity?
    @Binding var confirmDeleteAll: Bool
    let onDelete: (FaceIdentity) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete \(pendingDelete?.name ?? "this face")?",
                                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
                Button("Delete", role: .destructive) {
                    if let identity = pendingDelete { onDelete(identity) }
                }
            }
            .confirmationDialog("Delete all face data?", isPresented: $confirmDeleteAll) {
                Button("Delete All", role: .destructive, action: deleteAll)
            } message: {
                Text("Every enrolled face is removed. This cannot be undone.")
            }
    }

    /// Needs the owner, not the key: it is the way out when the key is
    /// missing or cannot be read. A verified session does not prompt.
    private func deleteAll() {
        Task {
            guard await store.session.verifyOwner(reason: "delete your Face Unlock face data") else { return }
            store.deleteAll()
        }
    }
}

/// The owner checks the Face Unlock page asks for (finding H1 of the
/// 2026-10-15 review). Changes that make Face Unlock safer go through at
/// once, and deletes need only the plain owner check; changes that weaken
/// it need a fresh one, which an unlocked session never answers on the
/// owner's behalf (`FaceUnlockSession.reauthenticate(reason:)`).
@MainActor
struct FaceOwnerGate {
    let store: FaceEnrollmentStore
    private var session: FaceUnlockSession { store.session }

    /// Unlocks if needed (the owner check prompts), and the faces load with
    /// it. false when the key is missing too: nothing done in a sheet could
    /// be saved.
    func requireKey() async -> Bool {
        await store.unlock()
        return session.isUnlocked
    }

    /// The key, and an owner check made for this action: unlocking a locked
    /// session is that check; an unlocked one is asked again.
    func requireKeyAndFreshOwner(reason: String) async -> Bool {
        let wasVerified = session.isOwnerVerified
        guard await requireKey() else { return false }
        guard wasVerified else { return true }
        return await session.reauthenticate(reason: reason) && session.isUnlocked
    }

    /// Applies `change` at once unless it `weakens` Face Unlock, and then
    /// only after a fresh owner check. Refused or cancelled, nothing
    /// changes, so the control shows its previous value again.
    func apply(weakens: Bool, reason: String, _ change: @escaping () -> Void) {
        guard weakens else { return change() }
        Task {
            guard await session.reauthenticate(reason: reason) else { return }
            change()
        }
    }
}
