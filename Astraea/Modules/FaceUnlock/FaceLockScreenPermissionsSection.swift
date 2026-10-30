import SwiftUI
import AppKit

/// Lock Screen → Permissions: what typing the password needs. Only a Grant
/// button prompts; Open System Settings… only opens System Settings.
struct FaceLockScreenPermissionsSection: View {
    let coordinator: FaceUnlockCoordinator

    var body: some View {
        Section {
            FacePermissionRow(title: "Accessibility", isGranted: coordinator.isAccessibilityTrusted,
                              note: "Needed to type your password at the lock screen. If Astraea is already listed and switched on, remove it and add it again.") {
                Button("Grant Access…") { coordinator.requestAccessibility() }
            }
            FacePermissionRow(title: "Camera", isGranted: coordinator.cameraPermission == .granted,
                              note: cameraNote) {
                switch coordinator.cameraPermission.grantAction {
                case .request:
                    Button("Grant Access…") {
                        Task {
                            await coordinator.requestCameraAccess()
                            CameraPermission.reopenSettingsAfterPrompt(from: "Grant Access")
                        }
                    }
                case .openSystemSettings:
                    Button("Open System Settings…") { Task { await coordinator.requestCameraAccess() } }
                case nil:
                    EmptyView()
                }
            }
        } header: {
            Text("Permissions")
        }
    }

    private var cameraNote: String {
        switch coordinator.cameraPermission {
        case .granted: ""
        case .notDetermined: "Needed to see your face at the lock screen. Astraea also asks the first time you add a face."
        case .denied: "Needed to see your face at the lock screen."
        case .restricted: "Camera access is restricted on this Mac."
        }
    }
}

/// One permission: Granted, or Not granted with a remedy and a note.
private struct FacePermissionRow<Remedy: View>: View {
    let title: String
    let isGranted: Bool
    let note: String
    @ViewBuilder let remedy: () -> Remedy

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if !isGranted { remedy() }
                Label {
                    Text(isGranted ? "Granted" : "Not granted")
                } icon: {
                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(isGranted ? .green : .orange)
                }
                .foregroundStyle(.secondary)
            }
        } label: {
            SettingsLabel(title, detail: isGranted ? nil : note)
        }
    }
}

extension FaceUnlockStatus {
    /// Something the user must fix before a wake at the lock screen unlocks
    /// anything. Off and the in-progress states are not.
    var needsAttention: Bool {
        switch self {
        case .disabled, .ready, .scanning, .typingPassword, .verifying: false
        case .sessionLocked, .noStoredPassword, .pausedAfterRejections, .faceDataNotReady,
             .noEnrolledFace, .enrolledFacesNeedRecapture, .accessibilityNeeded, .cameraNotYetRequested, .cameraNotAuthorized,
             .passwordRejected: true
        }
    }
}
