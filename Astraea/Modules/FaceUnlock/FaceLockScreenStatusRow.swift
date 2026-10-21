import SwiftUI
import AppKit

/// Where lock-screen Face Unlock stands and how the last attempt ended.
/// Never names an identity: only the outcome and, to help pick a
/// threshold, where the best similarity fell against it (a coarse band,
/// not the number).
struct FaceLockScreenStatusRow: View {
    let coordinator: FaceUnlockCoordinator

    /// What "2 minutes ago" is measured from. Set on appear and on coming
    /// back to the app rather than by a timer: AppDelegate keeps the
    /// Settings window alive after it closes, so a timer would never stop.
    @State private var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(coordinator.status.text)
                .foregroundStyle(coordinator.status.needsAttention ? .orange : .secondary)
            if let outcome = coordinator.lastOutcome, let at = coordinator.lastOutcomeAt {
                Text(outcome.text).font(.caption)
                Text(detail(at: at))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        // Accessibility and the camera are changed in System Settings and
        // neither notifies, so re-read them here.
        // Read-only: never prompts.
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func detail(at date: Date) -> String {
        let when = RelativeDateTimeFormatter().localizedString(for: min(date, now), relativeTo: now)
        // The band, never the raw score: see `SimilarityBand`.
        guard let band = coordinator.lastBestBand else { return when }
        return "\(when) · Best match \(band.title)"
    }

    private func refresh() {
        now = Date()
        coordinator.refreshPermissions()
    }
}
