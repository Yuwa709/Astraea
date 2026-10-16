import SwiftUI

/// Settings → Face Unlock → Lock Screen: the switch for typing the stored
/// password at the lock screen, how strict matching and liveness are, and
/// where it stands.
///
/// Opening it never prompts. The status and permission rows read cached
/// state only; Accessibility and the camera are asked for only from their
/// Grant buttons.
/// Without a coordinator (tests) only the switch and the threshold show.
struct FaceLockScreenSection: View {
    @Bindable var settings: SettingsStore
    let coordinator: FaceUnlockCoordinator?
    /// Turning lock-screen unlock on, or loosening the threshold or
    /// liveness, asks the owner first.
    let gate: FaceOwnerGate

    var body: some View {
        Section {
            // Allowed at any time: the status line says what is still missing.
            Toggle("Unlock the Mac at the lock screen", isOn: enabled)
            if let coordinator {
                FaceLockScreenStatusRow(coordinator: coordinator)
            }
            Picker("Match threshold", selection: threshold) {
                ForEach(FaceMatchThreshold.allCases) { level in
                    Text("\(level.title) (\(level.value.formatted(.number.precision(.fractionLength(2)))))")
                        .tag(level)
                }
            }
            Text("Higher is stricter: fewer false matches, more retries.")
                .font(.caption)
                .foregroundStyle(.secondary)
            FaceLivenessRow(settings: settings, gate: gate)
        } header: {
            Text("Lock Screen")
        } footer: {
            if coordinator != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Wake your Mac and look at the camera. PopNotch keeps looking for up to 2 minutes, until the password field is showing and it recognises you.")
                    Text("With this on and a password stored, Face Unlock stays unlocked across restarts until auto-lock or Lock Now. If it is locked when PopNotch starts, PopNotch asks once after you log in for Touch ID or your password.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        if let coordinator {
            FaceLockScreenPermissionsSection(coordinator: coordinator)
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

    /// A looser threshold asks the owner first; a stricter one does not.
    private var threshold: Binding<FaceMatchThreshold> {
        Binding(
            get: { settings.settings.faceUnlockMatchThreshold },
            set: { value in
                let current = settings.settings.faceUnlockMatchThreshold
                gate.apply(weakens: value.isWeaker(than: current), reason: "loosen Face Unlock's match threshold") {
                    settings.update { $0.faceUnlockMatchThreshold = value }
                }
            }
        )
    }
}
