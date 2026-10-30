import SwiftUI

/// Settings → Face Unlock → Recognition: how close a match must be, and how
/// much liveness checking it needs, before the password is typed. Each
/// picker carries its own one-line description. Applies from the next scan.
struct FaceMatchingSection: View {
    @Bindable var settings: SettingsStore
    /// A looser threshold or a weaker liveness level asks the owner first.
    let gate: FaceOwnerGate

    var body: some View {
        Section {
            Picker(selection: threshold) {
                ForEach(FaceMatchThreshold.allCases) { level in
                    Text("\(level.title) (\(level.value.formatted(.number.precision(.fractionLength(2)))))")
                        .tag(level)
                }
            } label: {
                SettingsLabel("Match threshold",
                              detail: "Higher is stricter: fewer false matches, more retries.")
            }
            FaceLivenessRow(settings: settings, gate: gate)
        } header: {
            Text("Recognition")
        }
    }

    /// A looser threshold asks the owner first; a stricter one does not.
    /// Unauthenticated: `faceUnlock*` settings are plain UserDefaults, which
    /// any process running as the user can rewrite (review finding L1).
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

/// How much liveness checking a match needs before the password is typed,
/// with one line on what that level buys.
struct FaceLivenessRow: View {
    @Bindable var settings: SettingsStore
    /// A weaker level asks the owner first.
    let gate: FaceOwnerGate

    var body: some View {
        Picker(selection: level) {
            ForEach(FaceLivenessLevel.allCases) { level in
                Text(level.title).tag(level)
            }
        } label: {
            SettingsLabel("Liveness check", detail: settings.settings.faceUnlockLiveness.summary)
        }
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
