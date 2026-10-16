import SwiftUI

/// Settings → Face Unlock → Lock Screen: how much liveness checking a match
/// needs before the password is typed, and one line on what that buys.
/// Applies from the next scan.
struct FaceLivenessRow: View {
    @Bindable var settings: SettingsStore
    /// A weaker level asks the owner first.
    let gate: FaceOwnerGate

    var body: some View {
        Picker("Liveness check", selection: level) {
            ForEach(FaceLivenessLevel.allCases) { level in
                Text(level.title).tag(level)
            }
        }
        Text(settings.settings.faceUnlockLiveness.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// A weaker level asks the owner first; a stronger one does not.
    /// Unauthenticated: `faceUnlock*` settings are plain UserDefaults, which
    /// any process running as the user can rewrite (review finding L1).
    private var level: Binding<FaceLivenessLevel> {
        Binding(
            get: { settings.settings.faceUnlockLiveness },
            set: { value in
                let current = settings.settings.faceUnlockLiveness
                gate.apply(weakens: value.isWeaker(than: current), reason: "weaken Face Unlock's liveness check") {
                    settings.update { $0.faceUnlockLiveness = value }
                }
            }
        )
    }
}
