import SwiftUI

/// The enrolment sheet over the Settings window. Owns the session, so the
/// camera and the model live exactly as long as the sheet.
struct FaceEnrollmentSheet: View {
    @State private var session: FaceEnrollmentSession
    let onClose: () -> Void

    init(store: FaceEnrollmentStore, replacing identity: FaceIdentity? = nil, onClose: @escaping () -> Void) {
        _session = State(initialValue: FaceEnrollmentSession(store: store, replacing: identity))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 18) {
            content
        }
        .padding(24)
        .frame(width: 420, height: 470)
        .task {
            // The first Add a Face shows the camera prompt, which buries
            // Settings and this sheet; bring them back once start() is past it.
            let prompts = CameraPermission.current == .notDetermined
            await session.start()
            if prompts { CameraPermission.reopenSettingsAfterPrompt(from: "Add a Face") }
        }
        // Covers every exit: Cancel, Done, Escape, the window closing. The
        // session stays cancelled, so a start() still loading the model or
        // starting the camera stops instead of running on.
        .onDisappear { session.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch session.step {
        case .starting:
            Spacer()
            ProgressView("Starting the camera…")
            Spacer()
            closeButton("Cancel")
        case .capturing:
            EnrollmentCaptureView(session: session)
            closeButton("Cancel")
        case .naming, .saving:
            EnrollmentNameView(session: session, onCancel: onClose)
        case .done:
            EnrollmentMessageView(symbol: "checkmark.circle.fill", tint: .green, title: "Face saved",
                                  detail: "To unlock your Mac with it, turn on \u{201C}Unlock the Mac at the lock screen\u{201D} in Face Unlock settings.")
            closeButton("Done")
        case .permissionNeeded:
            EnrollmentMessageView(symbol: "video.slash", tint: .orange, title: "Camera access needed",
                                  detail: "Allow PopNotch in System Settings → Privacy & Security → Camera, then try again.")
            HStack {
                Button("Open System Settings…") { CameraPermission.openSystemSettings() }
                closeButton("Close")
            }
        case .failed(let reason):
            EnrollmentMessageView(symbol: "exclamationmark.triangle.fill", tint: .orange,
                                  title: "Enrolment stopped", detail: reason)
            closeButton("Close")
        }
    }

    private func closeButton(_ title: String) -> some View {
        Button(title, action: onClose).keyboardShortcut(.cancelAction)
    }
}

/// A symbol, a title and one line of detail: the sheet's end states.
struct EnrollmentMessageView: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(tint)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
