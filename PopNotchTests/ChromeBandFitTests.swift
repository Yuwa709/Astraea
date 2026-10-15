import XCTest
import SwiftUI
import AppKit
import CoreAudio
@testable import PopNotch

/// Width pins for the navigated screens, plus the accessory-inset
/// invariants.
///
/// This file used to model band-versus-housing clearance with the band
/// anchored to the panel corners. That layout is gone: the band now anchors
/// each group to the housing itself (`NotchOverlayView.bandGapRange`), and
/// clearance across every expanded state and housing geometry is asserted
/// in ExpandedBandClearanceTests against the real layout function rather
/// than a re-derived model. What remains here are the content-width pins —
/// measured, not assumed, from a throwaway `NSHostingView` with the
/// coordinator's own padding — which those clearance tests take as input.
@MainActor
final class ChromeBandFitTests: XCTestCase {

    /// Measured on hardware 2026-08-30: `{{647, 924}, {176, 32}}`.
    private let notchWidth: CGFloat = 176
    private let neckHeight: CGFloat = 32

    /// Mirrors `NotchCoordinator.measureExpandedContent` exactly. If that
    /// padding ever changes, this drifts and the test stops meaning anything,
    /// which is why it is spelled out rather than approximated.
    private func panelWidth<V: View>(for content: V) -> CGFloat {
        let probe = NSHostingView(rootView:
            content
                .padding(.top, neckHeight + 20)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        )
        let measured = probe.fittingSize.width
        let minWidth = notchWidth + (NotchPanel.leadingWingWidth + 24) * 2
        return min(max(measured, minWidth), 690).rounded(.up)
    }

    /// Navigated screens carry Back plus caffeine alone: doors are a way *to*
    /// a screen, so they do not render once you are on one. That is the rule
    /// `leadingAccessory()` always had, which moving the doors to the trailing
    /// side dropped by accident and which took the clipboard screen 6pt past
    /// the housing.
    /// The pinned widths ExpandedBandClearanceTests runs its clearance
    /// sweep over; a redesign that moves one shows up here first.
    func testNavigatedClipboardScreenWidthIsPinned() {
        // 484 since the filter-tab redesign widened the content 320 -> 420;
        // it was 384 before that, and the tight case that motivated this file.
        XCTAssertEqual(panelWidth(for: ClipboardExpandedView(service: ClipboardService())),
                       484, accuracy: 0.5, "clipboard screen width")
    }

    func testNavigatedFileShelfScreenWidthIsPinned() {
        XCTAssertEqual(panelWidth(for: FileShelfExpandedView(service: FileShelfService())),
                       690, accuracy: 0.5,
                       "shelf content is 626pt by design — the panel width ceiling")
    }

    /// The two shelf modes are deliberately different sizes — the chooser
    /// hugs its zones (user-requested), the resting shelf is wider. That is
    /// safe only because a mode swap cannot happen under a mid-drag cursor
    /// any more: a shelf-originated drag never shows the chooser, so its
    /// transitions coincide with a drag arriving at or leaving the panel.
    /// The pins keep both from drifting.
    func testShelfModeWidthsArePinned() {
        let service = FileShelfService()
        XCTAssertEqual(panelWidth(for: FileShelfExpandedView(service: service)),
                       690, accuracy: 0.5, "resting shelf: 626pt content")
        service.setDragHovering(true)
        XCTAssertEqual(panelWidth(for: FileShelfExpandedView(service: service)),
                       540, accuracy: 0.5, "chooser hugs its 230×125 zones: 476pt content")
    }


    func testNavigatedAppVolumeScreenWidthIsPinned() {
        // Constructing the service registers nothing: listeners only exist
        // once startWatching runs, which this test never does. Empty rows
        // draw the empty state at the same fixed 420pt content width.
        XCTAssertEqual(panelWidth(for: AppVolumePageView(service: AppVolumeService())),
                       484, accuracy: 0.5,
                       "the clipboard page's width, so the doors read as one family")
    }

    /// The mixer page must never out-measure the panel's 460pt height
    /// ceiling, however many apps play: past eight rows the list scrolls
    /// (`AppVolumePageView.listHeight`). Measured with the coordinator's own
    /// padding, at a row count well past the cap.
    func testAppVolumePageStaysUnderThePanelHeightCeiling() {
        let source = StubAudioProcessSource()
        let owners = (0..<20).map {
            AudioOwner(key: "app.\($0)", name: "App \($0)", kind: .app, resolution: .ownApp)
        }
        let service = AppVolumeService(source: source,
                                       resolve: { .shown(owners[Int($0.pid)]) },
                                       isAppRunning: { _ in true })
        service.startWatching()
        source.publish(owners.indices.map {
            AudioProcessSnapshot(objectID: AudioObjectID(100 + $0), pid: pid_t($0),
                                 bundleID: nil, isRunningOutput: true)
        })
        XCTAssertEqual(service.mixerRows.count, 20, "the fixture really is past the cap")

        let probe = NSHostingView(rootView:
            AppVolumePageView(service: service)
                .padding(.top, neckHeight + 20)
                .padding(.horizontal, 32)
                .padding(.bottom, 20)
        )
        XCTAssertLessThanOrEqual(probe.fittingSize.height, 460,
                                 "twenty rows must scroll, not outgrow the panel")
    }

    /// The band sits nearer the corner than the content column, and must not
    /// reach the rounded corner itself.
    func testAccessoryInsetIsOutsideTheCornerRadius() {
        XCTAssertLessThan(NotchOverlayView.accessorySideInset,
                          NotchOverlayView.contentSideInset,
                          "chrome hugs the corner more tightly than content")
        XCTAssertGreaterThan(NotchOverlayView.accessorySideInset,
                             NotchShape.expandedTopRadius,
                             "inside the corner radius the control gets clipped")
    }
}
