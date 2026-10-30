import SwiftUI

/// Settings → Face Unlock → Enrolled Faces. Display only: the enrolment
/// sheet and the delete confirmations belong to the tab, so each hangs off
/// one view rather than off this section's rows.
struct FaceEnrolledFacesSection: View {
    let store: FaceEnrollmentStore
    /// From the last toggle or delete; nil when it succeeded.
    let actionError: String?
    let onAdd: () -> Void
    let onToggle: (FaceIdentity, Bool) -> Void
    let onRecapture: (FaceIdentity) -> Void
    let onDelete: (FaceIdentity) -> Void
    let onDeleteAll: () -> Void

    var body: some View {
        Section {
            content
        } header: {
            Text("Enrolled Faces")
        } footer: {
            SettingsFooter("Each face is stored as numbers, never as a picture, encrypted with a key in your login keychain. After an Astraea update, macOS may ask once whether the new version can use that key.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .locked:
            locked
        case .unlocking:
            ProgressView().controlSize(.small)
        case .unreadable(let reason):
            SettingsNote(text: reason)
            if let error = store.lastError { errorText(error) }
            deleteAllButton
        case .ready:
            ForEach(store.identities) { identity in
                FaceIdentityRow(identity: identity,
                                onToggle: { onToggle(identity, $0) },
                                onRecapture: { onRecapture(identity) },
                                onDelete: { onDelete(identity) })
            }
            if store.identities.isEmpty {
                Text("No faces enrolled.").foregroundStyle(.secondary)
            }
            if let actionError { errorText(actionError) }
            addButton
        }
    }

    /// Owner verified but the faces failed to load: retry, no prompt, or
    /// delete them. Faces on disk: the Session section above unlocks them,
    /// unless their key could not be read, when deleting is offered too.
    /// Nothing on disk: the empty state, where Add runs the owner check first.
    @ViewBuilder
    private var locked: some View {
        if store.session.isOwnerVerified {
            if let error = store.lastError {
                errorText(error)
                Button("Try Again") { Task { await store.unlock() } }
                if store.fileExists { deleteAllButton }
            } else {
                ProgressView().controlSize(.small)
            }
        } else if store.fileExists, store.session.keyReadFailed {
            Text("Your face data can't be decrypted: the keychain did not hand over its key. Unlock again, or delete the face data to start fresh.")
                .foregroundStyle(.secondary)
            deleteAllButton
        } else if store.fileExists {
            Text("Unlock Face Unlock to see your enrolled faces.")
                .foregroundStyle(.secondary)
        } else {
            Text("No faces enrolled.").foregroundStyle(.secondary)
            addButton
        }
    }

    /// Off while a prompt is up, and while the key is missing: a new face
    /// would need a new key, which is never minted over existing data.
    private var addButton: some View {
        HStack {
            Spacer()
            Button("Add a Face…", action: onAdd)
                .disabled(store.session.state == .unlocking || store.session.state == .keyMissing)
        }
    }

    /// Needs the owner check, not the key; the tab confirms first.
    private var deleteAllButton: some View {
        Button("Delete Face Data…", role: .destructive, action: onDeleteAll)
    }

    private func errorText(_ text: String) -> some View {
        SettingsNote(text: text, symbol: "xmark.octagon.fill", tint: .red)
    }
}
