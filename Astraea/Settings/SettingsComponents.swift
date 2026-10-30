import SwiftUI

/// A white SF Symbol on a tinted rounded square, as System Settings draws
/// its sidebar. Shared by the sidebar and the Features rows so the two read
/// as one family.
struct SettingsIcon: View {

    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient,
                        in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row's label with an icon in front, for settings rows that need one.
struct SettingsRowLabel: View {

    let title: String
    let symbol: String
    let tint: Color
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(symbol: symbol, tint: tint)
            SettingsLabel(title, detail: detail)
        }
    }
}

/// A control's title with its one-line description directly beneath it,
/// the way System Settings describes a switch in place rather than in a
/// paragraph under the whole group.
struct SettingsLabel: View {

    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The caption style every section footer uses.
struct SettingsFooter: View {

    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A short status line inside a section: an icon and a caption, tinted by
/// what it reports. Used for warnings and errors that sit beside the
/// control they concern.
struct SettingsNote: View {

    let text: String
    var symbol: String = "exclamationmark.triangle.fill"
    var tint: Color = .orange

    var body: some View {
        Label {
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}

extension View {
    /// The one look every settings page shares: System Settings' grouped
    /// form, scrolling under the window's own chrome.
    func settingsPage() -> some View {
        formStyle(.grouped)
    }
}
