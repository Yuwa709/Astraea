import CoreGraphics
import Foundation

/// One zone of a custom layout, in whole grid cells. Cells rather than
/// fractions so zones the user drew can never overlap by a rounding error,
/// and so the editor can redraw exactly what was saved.
nonisolated struct GridZone: Codable, Equatable, Hashable, Sendable {
    var column: Int
    var row: Int
    var columnSpan: Int
    var rowSpan: Int

    /// The rectangle with `a` and `b` (column, row) as opposite corners, in
    /// either order: what a drag from one cell to another covers.
    static func spanning(_ a: (column: Int, row: Int), _ b: (column: Int, row: Int)) -> GridZone {
        GridZone(column: min(a.column, b.column), row: min(a.row, b.row),
                 columnSpan: abs(a.column - b.column) + 1, rowSpan: abs(a.row - b.row) + 1)
    }

    func contains(column c: Int, row r: Int) -> Bool {
        (column..<column + columnSpan).contains(c) && (row..<row + rowSpan).contains(r)
    }

    func overlaps(_ other: GridZone) -> Bool {
        column < other.column + other.columnSpan && other.column < column + columnSpan
            && row < other.row + other.rowSpan && other.row < row + rowSpan
    }

    func fits(columns: Int, rows: Int) -> Bool {
        column >= 0 && row >= 0 && columnSpan >= 1 && rowSpan >= 1
            && column + columnSpan <= columns && row + rowSpan <= rows
    }
}

/// A layout the user built in Settings: a grid with some of its cells
/// grouped into zones. Cells left out of every zone are simply not a
/// target. Persisted in `AppSettings.windowLayouts`.
///
/// Every instance is valid: the grid is in range, every zone fits it and
/// none overlap. The decoder enforces that on stored JSON and the editing
/// methods keep it, so the picker never has to.
nonisolated struct CustomLayout: Codable, Equatable, Identifiable, Sendable {

    static let columnRange = 1...6
    static let rowRange = 1...4
    /// How many custom layouts can be saved. With the four built-ins that
    /// is two rows of picker at most.
    static let maxCount = 6

    let id: UUID
    var name: String
    private(set) var columns: Int
    private(set) var rows: Int
    /// In reading order (row, then column), which is the picker's order.
    private(set) var zones: [GridZone]

    init(id: UUID = UUID(), name: String, columns: Int = 2, rows: Int = 2, zones: [GridZone] = []) {
        self.id = id
        self.name = name
        self.columns = Self.columnRange.clamped(columns)
        self.rows = Self.rowRange.clamped(rows)
        self.zones = []
        for zone in zones { add(zone) }
    }

    // MARK: - Editing

    /// The zone covering a cell, if any.
    func zoneIndex(column: Int, row: Int) -> Int? {
        zones.firstIndex { $0.contains(column: column, row: row) }
    }

    /// Whether `zone` fits the grid without overlapping an existing zone.
    func canAdd(_ zone: GridZone) -> Bool {
        zone.fits(columns: columns, rows: rows) && !zones.contains { $0.overlaps(zone) }
    }

    /// Adds `zone` if `canAdd` allows it. Returns whether it was added.
    @discardableResult
    mutating func add(_ zone: GridZone) -> Bool {
        guard canAdd(zone) else { return false }
        zones.append(zone)
        zones.sort { ($0.row, $0.column) < ($1.row, $1.column) }
        return true
    }

    mutating func removeZone(column: Int, row: Int) {
        guard let index = zoneIndex(column: column, row: row) else { return }
        zones.remove(at: index)
    }

    mutating func removeAllZones() { zones.removeAll() }

    /// Changes the grid. Zones that no longer fit are dropped; the rest keep
    /// their cells.
    mutating func resize(columns newColumns: Int, rows newRows: Int) {
        columns = Self.columnRange.clamped(newColumns)
        rows = Self.rowRange.clamped(newRows)
        zones.removeAll { !$0.fits(columns: columns, rows: rows) }
    }

    // MARK: - Picker

    /// Permanent prefix for this layout's preset and zone ids.
    var presetID: String { "custom.\(id.uuidString)" }

    /// The layout as the picker draws and places it.
    var preset: LayoutPreset {
        let names = Self.zoneNames(zones, columns: columns, rows: rows)
        let zones = zones.enumerated().map { index, zone in
            LayoutZone(id: "\(presetID).\(index)", name: names[index],
                       unitRect: CGRect(x: CGFloat(zone.column) / CGFloat(columns),
                                        y: CGFloat(zone.row) / CGFloat(rows),
                                        width: CGFloat(zone.columnSpan) / CGFloat(columns),
                                        height: CGFloat(zone.rowSpan) / CGFloat(rows)))
        }
        return LayoutPreset(id: presetID, name: name, zones: zones)
    }

    /// Names in the built-ins' vocabulary — Top Left, Centre, Full — taken
    /// from which screen edges a zone touches. Zones that would share a
    /// name are numbered in reading order: Centre 1, Centre 2.
    static func zoneNames(_ zones: [GridZone], columns: Int, rows: Int) -> [String] {
        let base = zones.map { zone -> String in
            let horizontal: String? = zone.columnSpan == columns ? nil
                : zone.column == 0 ? "Left"
                : zone.column + zone.columnSpan == columns ? "Right" : "Centre"
            let vertical: String? = zone.rowSpan == rows ? nil
                : zone.row == 0 ? "Top"
                : zone.row + zone.rowSpan == rows ? "Bottom" : "Middle"
            return [vertical, horizontal].compactMap { $0 }.joined(separator: " ")
        }.map { $0.isEmpty ? "Full" : $0 }
        var seen: [String: Int] = [:]
        return base.map { name in
            guard base.filter({ $0 == name }).count > 1 else { return name }
            seen[name, default: 0] += 1
            return "\(name) \(seen[name] ?? 1)"
        }
    }

    // MARK: - Decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, columns, rows, zones
    }

    /// Strict about the grid, lenient about zones: a layout without a usable
    /// id or grid throws (and the caller drops only that layout), while a
    /// zone that does not fit or overlaps an earlier one drops only itself.
    /// A layout left with no zones has nothing to pick, so it throws too.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode(Int.self, forKey: .columns)
        let rows = try container.decode(Int.self, forKey: .rows)
        guard Self.columnRange.contains(columns), Self.rowRange.contains(rows) else {
            throw DecodingError.dataCorruptedError(forKey: .columns, in: container,
                                                   debugDescription: "Grid out of range")
        }
        let name = (try? container.decode(String.self, forKey: .name))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let zones = (try? container.decode([LenientZone].self, forKey: .zones))?
            .compactMap(\.value) ?? []
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  name: name?.isEmpty == false ? name ?? "" : "Custom",
                  columns: columns, rows: rows, zones: zones)
        guard !self.zones.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .zones, in: container,
                                                   debugDescription: "No usable zones")
        }
    }

    /// One stored zone, or nil when it is not a zone at all.
    private struct LenientZone: Decodable {
        let value: GridZone?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(GridZone.self)
        }
    }
}

private extension ClosedRange where Bound == Int {
    nonisolated func clamped(_ value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}
