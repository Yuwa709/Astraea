import SwiftUI

/// Settings → Face Unlock → Lock Screen: the page's main switch, for typing
/// the stored password at the lock screen, and where it stands. How strict
/// matching and liveness are lives in `FaceMatchingSection`; what it needs
/// in `FaceLockScreenPermissionsSection`.
///
/// Opening it never prompts. The status row reads cached state only.
/// Without a coordinator (tests) only the switch shows.
struct FaceLockScreenSection: View {
    @Bindable var settings: SettingsStore
    let coordinator: FaceUnlockCoordinator?
    /// Turning lock-screen unlock on asks the owner first.
    let gate: FaceOwnerGate

    var body: some View {
        Section {
            // Allowed at any time: the status line says what is still missing.
            Toggle(isOn: enabled) {
                SettingsLabel("Unlock the Mac at the lock screen",
                              detail: coordinator == nil ? nil
                                  : "Wake your Mac and look at the camera. Astraea keeps looking for up to 2 minutes, until the password field is showing and it recognises you.")
            }
            if let coordinator {
                FaceLockScreenStatusRow(coordinator: coordinator)
            }
        } header: {
            Text("Lock Screen")
        }
    }

    /// Written through the settings store like every other tab; the
    /// coordinator observes the same value and arms or disarms on its own.
    /// Turning it on asks the owner first; turning it off does not.
    /// Unauthenticated: `faceUnlock*` settings are plain UserDefaults, which
    /// any process running as the user can rewrite (review finding L1).
    private var enabled: Binding<Bool> {
        Binding(
            get: { settings.settings.faceUnlockAtLockScreenEnabled },
            set: { value in
                gate.apply(weakens: value, reason: "let Face Unlock unlock your Mac at the lock screen") {
                    settings.update { $0.faceUnlockAtLockScreenEnabled = value }
                }
            }
        )
    }
}
