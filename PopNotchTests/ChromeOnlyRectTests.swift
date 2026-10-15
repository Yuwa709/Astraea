import XCTest
import SwiftUI
import AppKit
@testable import PopNotch

/// The chrome-only state: a neck-height bar whose only row is the accessory
/// band. Sizing and placement are shared with every expanded state via
/// `NotchPanel.expandedRect`; what is specific to chrome-only — and pinned
/// here — is the height (exactly the neck) and the overlay fitting its
/// frame with nothing left over. Band-versus-housing clearance for ALL
/// expanded states lives in ExpandedBandClearanceTests.
///
/// Parameterised over the two housing geometries this display has actually
/// reported — 176×32 at the 1470×956 default scale and 206×38 at the
/// 1710×1112 more-space scale — asserting relationships, not pixels, so a
/// scale change cannot silently invalidate the suite the way hardcoding
/// 176×32 did on 2026-09-01.
@MainActor
final class ChromeOnlyRectTests: XCTestCase {

    private let housings = [
        NSRect(x: 647, y: 924, width: 176, height: 32),
        NSRect(x: 752, y: 1074, width: 206, height: 38),
    ]

    /// The real chrome, built the way the coordinator builds it, measured
    /// the way the coordinator measures it.
    private func leadingGroup() -> AnyView {
        AnyView(HStack(spacing: 2) {
            PanelChromeButton(symbol: "gearshape", help: "Settings") {}
            PanelChromeButton(symbol: "doc.on.clipboard", help: "Clipboard history") {}
            PanelChromeButton(symbol: "tray.full", help: "File shelf") {}
        })
    }

    private func trailingGroup() -> AnyView {
        AnyView(HStack(spacing: 2) {
            PanelChromeButton(symbol: "chart.bar.xaxis", help: "System stats") {}
            CaffeinateControl(service: CaffeinateService())
            PinControl(isPinned: false) {}
        })
    }

    private func measuredGroups() -> NotchPanel.ChromeGroupWidths {
        NotchPanel.ChromeGroupWidths(
            leading: NSHostingView(rootView: leadingGroup()).fittingSize.width,
            trailing: NSHostingView(rootView: trailingGroup()).fittingSize.width)
    }

    private func chromeOnlyRect(housing: NSRect) -> NSRect {
        NotchPanel.expandedRect(housing: housing, contentSize: .zero,
                                chromeOnly: true, chromeGroups: measuredGroups())
    }

    func testHeightIsExactlyTheNeck() {
        for housing in housings {
            let rect = chromeOnlyRect(housing: housing)
            XCTAssertEqual(rect.height, housing.height, "housing \(housing)")
            XCTAssertEqual(rect.minY, housing.minY, "no growth below the housing")
            XCTAssertEqual(rect.maxY, housing.maxY, "top stays flush with the screen")
        }
    }

    /// A floor-width card and the bar occupy the same frame except for
    /// height, so the transition between them is a pure height change.
    func testBarSharesWidthAndPlacementWithAFloorWidthCard() {
        for housing in housings {
            let bar = chromeOnlyRect(housing: housing)
            let card = NotchPanel.expandedRect(housing: housing, contentSize: .zero,
                                               chromeOnly: false, chromeGroups: measuredGroups())
            XCTAssertEqual(bar.minX, card.minX, "housing \(housing)")
            XCTAssertEqual(bar.width, card.width, "housing \(housing)")
        }
    }

    /// The overlay itself, configured exactly as the coordinator configures
    /// it in chrome-only, must fit the frame the rect maths hands the panel:
    /// fitting height == panel content height (bar + hover halo), nothing
    /// left over for NSHostingView to centre. This is the layout half of the
    /// clipped-buttons bug; the rect half is above.
    func testOverlayFittingSizeMatchesThePanelFrame() {
        for housing in housings {
            let rect = chromeOnlyRect(housing: housing)
            let housingLocal = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
            let overlay = NotchOverlayView(
                content: AnyView(VStack(spacing: 8) { EmptyView() }),
                leadingWing: nil, trailingWing: nil,
                neckHeight: housing.height, revealContent: false,
                topLeadingAccessory: leadingGroup(),
                topTrailingAccessory: trailingGroup(),
                housingLocalRange: housingLocal,
                panelWidth: rect.width,
                chromeGroups: measuredGroups(),
                chromeOnly: true)
            let fitting = NSHostingView(rootView: overlay).fittingSize
            XCTAssertEqual(fitting.height, rect.height + NotchPanel.hoverMargin,
                           accuracy: 0.5, "housing \(housing)")
            XCTAssertLessThanOrEqual(fitting.width, rect.width + NotchPanel.hoverMargin * 2 + 0.5,
                                     "band overflows the frame sideways: housing \(housing)")
        }
    }

    /// Without the flag the content region's fixed padding alone overflows
    /// the bar — the regression this file exists to hold the line on.
    func testContentRegionIsWhatTheFlagSuppresses() {
        for housing in housings {
            let rect = chromeOnlyRect(housing: housing)
            let housingLocal = (housing.minX - rect.minX)...(housing.maxX - rect.minX)
            let overlay = NotchOverlayView(
                content: AnyView(VStack(spacing: 8) { EmptyView() }),
                leadingWing: nil, trailingWing: nil,
                neckHeight: housing.height, revealContent: false,
                topLeadingAccessory: leadingGroup(),
                topTrailingAccessory: trailingGroup(),
                housingLocalRange: housingLocal,
                panelWidth: rect.width,
                chromeGroups: measuredGroups(),
                chromeOnly: false)
            let fitting = NSHostingView(rootView: overlay).fittingSize
            XCTAssertGreaterThan(fitting.height,
                                 housing.height + NotchPanel.hoverMargin + 20,
                                 "padding no longer overflows; is this test stale?")
        }
    }

    func testWidthIsCappedAtThePanelCeiling() {
        for housing in housings {
            let huge = NotchPanel.ChromeGroupWidths(leading: 400, trailing: 400)
            let rect = NotchPanel.expandedRect(housing: housing, contentSize: .zero,
                                               chromeOnly: true, chromeGroups: huge)
            XCTAssertEqual(rect.width, 690)
        }
    }

    /// The groups stay 24pt controls at every display scale, so the band
    /// fits the shallower 32pt neck too.
    func testRealChromeGroupsFitTheShallowestNeck() {
        let groups = measuredGroups()
        XCTAssertEqual(groups.leading, 76, accuracy: 0.5)
        XCTAssertEqual(groups.trailing, 76, accuracy: 0.5, "stats door joined the trailing group")
        let tallest = max(
            NSHostingView(rootView: leadingGroup()).fittingSize.height,
            NSHostingView(rootView: trailingGroup()).fittingSize.height)
        XCTAssertLessThanOrEqual(tallest, housings.map(\.height).min() ?? 32,
                                 "the button row must fit inside the neck band")
    }
}
