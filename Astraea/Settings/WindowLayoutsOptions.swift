import SwiftUI

/// Which layouts the window layout picker offers: the built-ins, each of
/// which can be hidden, and layouts the user draws themselves. Rows on the
/// Features page, indented under the Window Layouts switch and shown only
/// while it is on, the way App Volume's taps toggle is.
///
/// Edits apply on the next drag. The picker reads its presets as a drag
/// begins, so nothing here changes a picker that is open.
struct WindowLayoutsOptions: View {

    /// Observed so the rows re-render when a preference is written.
    @Bindable var settings: SettingsStore

    @State private var editing: CustomLayout?
    @State private var pendingDelete: CustomLayout?

    private var layouts: AppSettings.WindowLayouts { settings.settings.windowLayouts }
    private var custom: [CustomLayout] { layouts.custom ?? [] }
    private var hidden: Set<String> { Set(layouts.hiddenBuiltIns ?? []) }

    /// Several rows, not one: the form draws each as its own row with its
    /// switch at the trailing edge. The sheet and the dialog hang off the
    /// last row only, so each is attached once.
    var body: some View {
        Group {
            ForEach(LayoutPreset.builtIn) { preset in
                Toggle(isOn: shownBinding(preset.id)) { LayoutRowLabel(preset: preset) }
                    .disabled(isOnlyVisible(preset.id))
            }
            ForEach(custom) { layout in customRow(layout) }
            addRow
        }
        .padding(.leading, 30)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Add Layout…") { editing = CustomLayout(name: layouts.nextLayoutName) }
                .disabled(custom.count >= CustomLayout.maxCount)
            SettingsFooter("Switch a layout off to keep it out of the picker. Draw your own zones on a grid: up to \(CustomLayout.maxCount) layouts, shown after the built-ins.")
        }
        .sheet(item: $editing) { layout in
            LayoutEditorSheet(layout: layout, isNew: !custom.contains { $0.id == layout.id },
                              onSave: save)
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?",
                            isPresented: isConfirmingDelete, presenting: pendingDelete) { layout in
            Button("Delete Layout", role: .destructive) { delete(layout) }
        } message: { _ in
            Text("This can’t be undone.")
        }
    }

    private func customRow(_ layout: CustomLayout) -> some View {
        HStack {
            LayoutRowLabel(preset: layout.preset)
            Spacer()
            Button("Edit…") { editing = layout }
            Button(role: .destructive) { pendingDelete = layout } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete \(layout.name)")
            .disabled(isOnlyVisible(layout.presetID))
        }
    }

    private func shownBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !hidden.contains(id) },
                set: { shown in settings.update { $0.windowLayouts.setBuiltIn(id, shown: shown) } })
    }

    private func save(_ layout: CustomLayout) {
        settings.update { $0.windowLayouts.save(layout) }
    }

    private func delete(_ layout: CustomLayout) {
        settings.update { $0.windowLayouts.delete(layout.id) }
    }

    private func isOnlyVisible(_ presetID: String) -> Bool {
        layouts.isOnlyVisible(presetID)
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }
}

/// A preset's name beside a small drawing of its zones.
private struct LayoutRowLabel: View {
    let preset: LayoutPreset

    var body: some View {
        HStack(spacing: 10) {
            LayoutThumbnail(preset: preset)
            VStack(alignment: .leading, spacing: 1) {
                Text(preset.name)
                Text(preset.zones.count == 1 ? "1 zone" : "\(preset.zones.count) zones")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The picker's tile in miniature, for Settings rows.
struct LayoutThumbnail: View {
    let preset: LayoutPreset
    var size = CGSize(width: 40, height: 25)

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary)
            ForEach(preset.zones) { zone in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: max(0, zone.unitRect.width * (size.width - 4) - 2),
                           height: max(0, zone.unitRect.height * (size.height - 4) - 2))
                    .offset(x: 2 + 1 + zone.unitRect.minX * (size.width - 4),
                            y: 2 + 1 + zone.unitRect.minY * (size.height - 4))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}
