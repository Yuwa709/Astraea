import SwiftUI

/// Enter, check and store the Mac password. The text lives only in this
/// sheet's own state: it is cleared on every Save attempt, on Cancel and
/// when the sheet goes away, and it is never logged.
struct FacePasswordSheet: View {
    let passwordStore: FacePasswordStore
    let isChange: Bool
    let onClose: () -> Void

    @State private var password = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "key.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)
            Text(isChange ? "Change Mac Password" : "Set Mac Password")
                .font(.title3.weight(.semibold))
            Text("Enter the password you use to log in to this Mac. PopNotch checks it with macOS before storing it, encrypted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Mac password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .focused($fieldFocused)
                .disabled(saving)
                .onSubmit(save)
            Text("Checked with macOS before saving. A wrong entry counts as a failed login attempt.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Group {
                if saving {
                    ProgressView("Checking with macOS…").controlSize(.small)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minHeight: 20)
            HStack {
                // Disabled while checking, so a password already handed to
                // the store cannot land after the user thinks it was dropped.
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { fieldFocused = true }
        .onDisappear { password = "" }
    }

    private func save() {
        guard !saving, !password.isEmpty else { return }
        let candidate = password
        password = ""
        error = nil
        saving = true
        Task {
            do {
                try await passwordStore.save(candidate)
                saving = false
                onClose()
            } catch {
                self.error = error.localizedDescription
                saving = false
                fieldFocused = true
            }
        }
    }

    private func close() {
        password = ""
        onClose()
    }
}
