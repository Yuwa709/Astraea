import SwiftUI

/// Builds or edits one custom layout: a name, a grid, and zones drawn on
/// it. Works on a copy; nothing is saved until Save.
struct LayoutEditorSheet: View {

    @State var layout: CustomLayout
    let isNew: Bool
    let onSave: (CustomLayout) -> Void

    @Environment(\.dismiss) private var dismiss

    private var trimmedName: String {
        layout.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !layout.zones.isEmpty && !trimmedName.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Layout" : "Edit Layout")
                .font(.headline)
            TextField("Name", text: $layout.name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 20) {
                Stepper("Columns: \(layout.columns)", value: gridBinding(\.columns),
                        in: CustomLayout.columnRange)
                Stepper("Rows: \(layout.rows)", value: gridBinding(\.rows),
                        in: CustomLayout.rowRange)
                Spacer()
                Button("Clear") { layout.removeAllZones() }
                    .disabled(layout.zones.isEmpty)
            }
            LayoutGridCanvas(layout: $layout)
                .frame(width: 400, height: 250)
            Text("Drag across cells to make a zone. Click a zone to remove it. Cells outside every zone aren’t a target.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = layout
                    saved.name = trimmedName
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    /// Columns or rows. Shrinking the grid drops zones that no longer fit.
    private func gridBinding(_ keyPath: KeyPath<CustomLayout, Int>) -> Binding<Int> {
        Binding(
            get: { layout[keyPath: keyPath] },
            set: { value in
                if keyPath == \CustomLayout.columns {
                    layout.resize(columns: value, rows: layout.rows)
                } else {
                    layout.resize(columns: layout.columns, rows: value)
                }
            }
        )
    }
}

/// The grid a layout is drawn on. A drag from one cell to another proposes
/// the zone spanning them, tinted red where it would overlap a zone already
/// there; a click on an existing zone removes it.
struct LayoutGridCanvas: View {

    @Binding var layout: CustomLayout

    private struct Cell: Equatable { let column: Int; let row: Int }

    @State private var dragStart: Cell?
    @State private var dragCurrent: Cell?

    /// The zone the drag would add, or nil while it is a click on a zone.
    private var proposed: GridZone? {
        guard let dragStart, let dragCurrent else { return nil }
        if dragStart == dragCurrent,
           layout.zoneIndex(column: dragStart.column, row: dragStart.row) != nil { return nil }
        return .spanning((dragStart.column, dragStart.row), (dragCurrent.column, dragCurrent.row))
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let names = CustomLayout.zoneNames(layout.zones, columns: layout.columns, rows: layout.rows)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quinary)
                ForEach(0..<layout.columns * layout.rows, id: \.self) { index in
                    let zone = GridZone(column: index % layout.columns, row: index / layout.columns,
                                        columnSpan: 1, rowSpan: 1)
                    cellShape.fill(.quaternary).placed(rect(for: zone, in: size))
                }
                ForEach(Array(layout.zones.enumerated()), id: \.element) { index, zone in
                    cellShape.fill(Color.accentColor)
                        .overlay(Text(names[index]).font(.caption.weight(.semibold))
                            .foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.7).padding(4))
                        .placed(rect(for: zone, in: size))
                }
                if let proposed {
                    let tint: Color = layout.canAdd(proposed) ? .accentColor : .red
                    cellShape.fill(tint.opacity(0.3))
                        .overlay(cellShape.strokeBorder(tint, lineWidth: 2))
                        .placed(rect(for: proposed, in: size))
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(in: size))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Layout grid, \(layout.columns) by \(layout.rows)")
            .accessibilityValue(names.isEmpty ? "No zones" : names.joined(separator: ", "))
        }
    }

    private var cellShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = cell(at: value.startLocation, in: size) }
                dragCurrent = cell(at: value.location, in: size)
            }
            .onEnded { value in
                defer { dragStart = nil; dragCurrent = nil }
                let end = cell(at: value.location, in: size)
                guard let start = dragStart else { return }
                if start == end, layout.zoneIndex(column: start.column, row: start.row) != nil {
                    layout.removeZone(column: start.column, row: start.row)
                } else {
                    layout.add(.spanning((start.column, start.row), (end.column, end.row)))
                }
            }
    }

    private func cell(at point: CGPoint, in size: CGSize) -> Cell {
        let column = Int(point.x / (size.width / CGFloat(layout.columns)))
        let row = Int(point.y / (size.height / CGFloat(layout.rows)))
        return Cell(column: min(max(column, 0), layout.columns - 1),
                    row: min(max(row, 0), layout.rows - 1))
    }

    /// A zone's frame on the canvas, inset so neighbours show a gap.
    private func rect(for zone: GridZone, in size: CGSize) -> CGRect {
        let cellWidth = size.width / CGFloat(layout.columns)
        let cellHeight = size.height / CGFloat(layout.rows)
        return CGRect(x: CGFloat(zone.column) * cellWidth, y: CGFloat(zone.row) * cellHeight,
                      width: CGFloat(zone.columnSpan) * cellWidth,
                      height: CGFloat(zone.rowSpan) * cellHeight).insetBy(dx: 3, dy: 3)
    }
}

private extension View {
    /// Sizes and positions a view at `rect` inside a top-leading ZStack.
    func placed(_ rect: CGRect) -> some View {
        frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
    }
}
