import SwiftUI

/// Settings → Window Layouts: the feature's switch, then which layouts the
/// window layout picker offers — the built-ins, each of which can be
/// hidden, and layouts the user draws themselves.
///
/// Edits apply on the next drag. The picker reads its presets as a drag
/// begins, so nothing here changes a picker that is open.
struct WindowLayoutsSettingsTab: View {

    private static let id: ModuleID = "window-layout"

    let coordinator: NotchCoordinator
    /// Observed so the rows re-render when a preference is written.
    @Bindable var settings: SettingsStore

    private var isOn: Binding<Bool> {
        let current = coordinator.moduleSummaries.first { $0.id == Self.id }?.isEnabled ?? false
        return FeatureSwitch.binding(for: Self.id, current: current,
                                     coordinator: coordinator, settings: settings)
    }

    var body: some View {
        let style = FeatureStyle.style(for: Self.id)
        Form {
            Section {
                Toggle(isOn: isOn) {
                    SettingsRowLabel(title: "Window Layouts", symbol: style.symbol,
                                     tint: style.tint, detail: style.summary)
                }
            }
            BuiltInLayoutsSection(settings: settings)
            CustomLayoutsSection(settings: settings)
        }
        .settingsPage()
    }
}

/// The built-in layouts, each with a switch to keep it out of the picker.
/// The last one shown cannot be switched off.
private struct BuiltInLayoutsSection: View {

    @Bindable var settings: SettingsStore

    private var layouts: AppSettings.WindowLayouts { settings.settings.windowLayouts }
    private var hidden: Set<String> { Set(layouts.hiddenBuiltIns ?? []) }

    var body: some View {
        Section {
            ForEach(LayoutPreset.builtIn) { preset in
                Toggle(isOn: shownBinding(preset.id)) { LayoutRowLabel(preset: preset) }
                    .disabled(layouts.isOnlyVisible(preset.id))
            }
        } header: {
            Text("Built-in Layouts")
        } footer: {
            SettingsFooter("Switch a layout off to keep it out of the picker.")
        }
    }

    private func shownBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !hidden.contains(id) },
                set: { shown in settings.update { $0.windowLayouts.setBuiltIn(id, shown: shown) } })
    }
}

/// Layouts drawn on a grid, shown in the picker after the built-ins.
private struct CustomLayoutsSection: View {

    @Bindable var settings: SettingsStore

    @State private var editing: CustomLayout?
    @State private var pendingDelete: CustomLayout?

    private var layouts: AppSettings.WindowLayouts { settings.settings.windowLayouts }
    private var custom: [CustomLayout] { layouts.custom ?? [] }

    var body: some View {
        Section {
            ForEach(custom) { layout in customRow(layout) }
            addRow
        } header: {
            Text("Custom Layouts")
        } footer: {
            SettingsFooter("Draw your own zones on a grid: up to \(CustomLayout.maxCount) layouts, shown after the built-ins.")
        }
    }

    /// The sheet and the dialog hang off this row only, so each is
    /// attached once.
    private var addRow: some View {
        HStack {
            if custom.isEmpty {
                Text("No custom layouts.").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add Layout…") { editing = CustomLayout(name: layouts.nextLayoutName) }
                .disabled(custom.count >= CustomLayout.maxCount)
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
            .disabled(layouts.isOnlyVisible(layout.presetID))
        }
    }

    private func save(_ layout: CustomLayout) {
        settings.update { $0.windowLayouts.save(layout) }
    }

    private func delete(_ layout: CustomLayout) {
        settings.update { $0.windowLayouts.delete(layout.id) }
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
