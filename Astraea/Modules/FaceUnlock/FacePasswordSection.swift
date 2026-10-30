import SwiftUI

/// Settings → Face Unlock → Mac Password. The status needs no key; Set and
/// Change need the key and a fresh owner check, even while unlocked; Remove
/// needs the owner check but not the key, which makes it the way out when
/// the key is missing or cannot be read.
struct FacePasswordSection: View {
    let passwordStore: FacePasswordStore
    let session: FaceUnlockSession
    /// Unlocks if needed, or else asks the owner again. true only with the
    /// key in hand and the owner just verified.
    let requireKey: () async -> Bool

    @State private var showingSheet = false
    /// Fixed when the sheet opens, so its title does not flip once a save lands.
    @State private var sheetIsChange = false
    @State private var confirmRemove = false
    @State private var removeError: String?

    private var isStored: Bool { passwordStore.hasStoredPassword }

    var body: some View {
        Section {
            LabeledContent {
                buttons
            } label: {
                Label {
                    SettingsLabel("Mac password", detail: isStored ? "Stored, encrypted" : "Not set")
                } icon: {
                    Image(systemName: isStored ? "lock.fill" : "minus.circle")
                }
            }
            if let removeError {
                SettingsNote(text: removeError, symbol: "xmark.octagon.fill", tint: .red)
            }
        } header: {
            Text("Mac Password")
        } footer: {
            SettingsFooter("With \u{201C}Unlock the Mac at the lock screen\u{201D} on, Face Unlock types this password for you when it recognises you there.")
        }
    }

    /// One view, so the sheet and the confirmation hang off a single anchor.
    private var buttons: some View {
        HStack(spacing: 8) {
            if isStored {
                Button("Remove Password…", role: .destructive) { confirmRemove = true }
                    .disabled(session.state == .unlocking)
            }
            Button(isStored ? "Change Password…" : "Set Password…") {
                Task {
                    guard await requireKey() else { return }
                    sheetIsChange = isStored
                    showingSheet = true
                }
            }
            // Needs the key: no new one is minted over data whose key is gone.
            .disabled(session.state == .unlocking || session.state == .keyMissing)
        }
        .sheet(isPresented: $showingSheet) {
            FacePasswordSheet(passwordStore: passwordStore, isChange: sheetIsChange) {
                showingSheet = false
            }
        }
        .confirmationDialog("Remove the stored password?", isPresented: $confirmRemove) {
            Button("Remove Password", role: .destructive, action: remove)
        } message: {
            Text("Astraea forgets your Mac password. Enrolled faces are kept.")
        }
    }

    /// A verified session does not prompt.
    private func remove() {
        Task {
            guard await session.verifyOwner(reason: "remove your stored Mac password") else { return }
            do {
                try passwordStore.delete()
                removeError = nil
            } catch {
                removeError = "Could not remove the password: \(error.localizedDescription)"
            }
        }
    }
}
