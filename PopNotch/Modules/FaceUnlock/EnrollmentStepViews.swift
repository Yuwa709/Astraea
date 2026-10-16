import SwiftUI

/// The mirrored camera in a circle, the progress ring, and one line of
/// guidance.
struct EnrollmentCaptureView: View {
    let session: FaceEnrollmentSession
    private let diameter: CGFloat = 220

    var body: some View {
        VStack(spacing: 16) {
            Text("Add a Face").font(.title3.weight(.semibold))
            ZStack {
                if let camera = session.camera {
                    CameraPreviewView(session: camera.session)
                        .frame(width: diameter, height: diameter)
                        .clipShape(Circle())
                }
                EnrollmentRingView(session: session, diameter: diameter)
            }
            Text(session.instruction)
                .font(.headline)
                .frame(height: 22)
            ProgressView(value: session.progress)
                .frame(width: 220)
            Text("Slowly move your head as asked. Frames stay on this Mac and are never saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Naming the captured face, then saving it in one write.
struct EnrollmentNameView: View {
    @Bindable var session: FaceEnrollmentSession
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Name this face").font(.title3.weight(.semibold))
            Text("Enrol yourself more than once to cover glasses or a different look.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            TextField("Name", text: $session.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit { Task { await session.save() } }
            if let error = session.nameError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Spacer()
            HStack {
                Button("Discard", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { Task { await session.save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.step == .saving)
            }
        }
    }
}
