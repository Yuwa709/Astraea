import XCTest
@testable import Astraea

/// Custom layouts: the editing rules that keep every saved layout valid,
/// how a layout becomes a picker preset, and which presets the picker shows.
final class CustomLayoutTests: XCTestCase {

    private func zone(_ column: Int, _ row: Int, _ columnSpan: Int = 1, _ rowSpan: Int = 1) -> GridZone {
        GridZone(column: column, row: row, columnSpan: columnSpan, rowSpan: rowSpan)
    }

    // MARK: - Editing

    func testSpanningIsTheSameFromEitherCorner() {
        XCTAssertEqual(GridZone.spanning((2, 3), (0, 1)), zone(0, 1, 3, 3))
        XCTAssertEqual(GridZone.spanning((0, 1), (2, 3)), zone(0, 1, 3, 3))
        XCTAssertEqual(GridZone.spanning((1, 1), (1, 1)), zone(1, 1))
    }

    func testOverlappingZoneIsRefused() {
        var layout = CustomLayout(name: "L", columns: 3, rows: 2, zones: [zone(0, 0, 2, 1)])
        XCTAssertFalse(layout.add(zone(1, 0, 1, 2)), "shares cell (1, 0)")
        XCTAssertTrue(layout.add(zone(2, 0, 1, 2)), "touching is not overlapping")
        XCTAssertEqual(layout.zones.count, 2)
    }

    func testZoneOutsideTheGridIsRefused() {
        var layout = CustomLayout(name: "L", columns: 2, rows: 2)
        XCTAssertFalse(layout.add(zone(1, 1, 2, 1)))
        XCTAssertFalse(layout.add(zone(-1, 0)))
        XCTAssertTrue(layout.zones.isEmpty)
    }

    func testZonesKeepReadingOrder() {
        var layout = CustomLayout(name: "L", columns: 2, rows: 2)
        layout.add(zone(1, 1))
        layout.add(zone(0, 1))
        layout.add(zone(1, 0))
        XCTAssertEqual(layout.zones, [zone(1, 0), zone(0, 1), zone(1, 1)])
    }

    func testRemoveByAnyCellOfTheZone() {
        var layout = CustomLayout(name: "L", columns: 3, rows: 2, zones: [zone(0, 0, 2, 2), zone(2, 0)])
        layout.removeZone(column: 1, row: 1)
        XCTAssertEqual(layout.zones, [zone(2, 0)])
        layout.removeZone(column: 0, row: 0)
        XCTAssertEqual(layout.zones, [zone(2, 0)], "an empty cell removes nothing")
    }

    func testShrinkingTheGridDropsOnlyZonesThatNoLongerFit() {
        var layout = CustomLayout(name: "L", columns: 4, rows: 2,
                                  zones: [zone(0, 0, 2, 2), zone(2, 0, 2, 1), zone(3, 1)])
        layout.resize(columns: 3, rows: 2)
        XCTAssertEqual(layout.zones, [zone(0, 0, 2, 2)])
        XCTAssertEqual(layout.columns, 3)
    }

    func testGridIsClampedToItsRange() {
        var layout = CustomLayout(name: "L", columns: 99, rows: 0)
        XCTAssertEqual(layout.columns, CustomLayout.columnRange.upperBound)
        XCTAssertEqual(layout.rows, CustomLayout.rowRange.lowerBound)
        layout.resize(columns: 0, rows: 99)
        XCTAssertEqual(layout.columns, 1)
        XCTAssertEqual(layout.rows, CustomLayout.rowRange.upperBound)
    }

    // MARK: - Picker preset

    func testPresetZonesAreGridFractions() {
        let layout = CustomLayout(name: "Coding", columns: 3, rows: 2,
                                  zones: [zone(0, 0, 2, 2), zone(2, 0), zone(2, 1)])
        let preset = layout.preset
        XCTAssertEqual(preset.id, layout.presetID)
        XCTAssertEqual(preset.name, "Coding")
        XCTAssertEqual(preset.zones.map(\.id), (0..<3).map { "\(layout.presetID).\($0)" })
        XCTAssertEqual(preset.zones[0].unitRect.width, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(preset.zones[0].unitRect.height, 1, accuracy: 1e-9)
        XCTAssertEqual(preset.zones[2].unitRect.minX, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(preset.zones[2].unitRect.minY, 0.5, accuracy: 1e-9)
    }

    func testZoneNamesUseTheBuiltInVocabulary() {
        let names = CustomLayout.zoneNames([zone(0, 0, 2, 2), zone(2, 0), zone(2, 1)], columns: 3, rows: 2)
        XCTAssertEqual(names, ["Left", "Top Right", "Bottom Right"])
        XCTAssertEqual(CustomLayout.zoneNames([zone(0, 0, 2, 3)], columns: 2, rows: 3), ["Full"])
        XCTAssertEqual(CustomLayout.zoneNames([zone(1, 1)], columns: 3, rows: 3), ["Middle Centre"])
    }

    func testRepeatedZoneNamesAreNumbered() {
        let names = CustomLayout.zoneNames([zone(0, 0), zone(1, 0), zone(2, 0), zone(3, 0)],
                                           columns: 4, rows: 1)
        XCTAssertEqual(names, ["Left", "Centre 1", "Centre 2", "Right"])
    }

    // MARK: - Which presets show

    func testHiddenBuiltInsLeaveThePickerAndCustomFollow() {
        var layouts = AppSettings.WindowLayouts()
        let custom = CustomLayout(name: "Mine", columns: 2, rows: 1, zones: [zone(0, 0), zone(1, 0)])
        layouts.save(custom)
        layouts.setBuiltIn("thirds", shown: false)
        XCTAssertEqual(layouts.visiblePresets.map(\.id), ["halves", "quarters", "full", custom.presetID])
        layouts.setBuiltIn("thirds", shown: true)
        XCTAssertNil(layouts.hiddenBuiltIns, "nothing hidden is stored as absence")
    }

    func testThePickerIsNeverEmpty() {
        var layouts = AppSettings.WindowLayouts()
        for preset in LayoutPreset.builtIn { layouts.setBuiltIn(preset.id, shown: false) }
        XCTAssertEqual(layouts.visiblePresets, LayoutPreset.builtIn)
    }

    func testOnlyTheLastVisibleLayoutIsProtected() {
        var layouts = AppSettings.WindowLayouts()
        for id in ["halves", "quarters", "thirds"] { layouts.setBuiltIn(id, shown: false) }
        XCTAssertTrue(layouts.isOnlyVisible("full"))
        let custom = CustomLayout(name: "Mine", columns: 1, rows: 1, zones: [zone(0, 0)])
        layouts.save(custom)
        XCTAssertFalse(layouts.isOnlyVisible("full"))
        XCTAssertFalse(layouts.isOnlyVisible(custom.presetID))
    }

    func testSavingReplacesByIDAndDeletingClearsTheList() {
        var layouts = AppSettings.WindowLayouts()
        var custom = CustomLayout(name: "Mine", columns: 1, rows: 1, zones: [zone(0, 0)])
        layouts.save(custom)
        custom.name = "Renamed"
        layouts.save(custom)
        XCTAssertEqual(layouts.custom?.map(\.name), ["Renamed"])
        layouts.delete(custom.id)
        XCTAssertNil(layouts.custom)
    }

    func testNextNameSkipsNamesInUse() {
        var layouts = AppSettings.WindowLayouts()
        XCTAssertEqual(layouts.nextLayoutName, "Layout 1")
        layouts.save(CustomLayout(name: "Layout 1", columns: 1, rows: 1, zones: [zone(0, 0)]))
        XCTAssertEqual(layouts.nextLayoutName, "Layout 2")
    }

    // MARK: - Picker rows

    @MainActor
    func testPickerRowsStayEven() {
        func shape(_ count: Int) -> [Int] {
            let presets = (0..<count).map { LayoutPreset(id: "p\($0)", name: "", zones: []) }
            return WindowLayoutPickerView.rows(of: presets).map(\.count)
        }
        XCTAssertEqual(shape(4), [4])
        XCTAssertEqual(shape(5), [5])
        XCTAssertEqual(shape(6), [3, 3])
        XCTAssertEqual(shape(7), [4, 3])
        XCTAssertEqual(shape(10), [5, 5])
        XCTAssertEqual(shape(0), [])
    }
}
