import XCTest
import SwiftUI
@testable import PopNotch

/// The accent extractor's contract: pick the vivid color, never black.
final class ArtworkColorTests: XCTestCase {

    /// Renders a solid-color square with an optional black band, as PNG data.
    private func imageData(color: NSColor, blackFraction: CGFloat = 0) -> Data {
        let side = 60
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            color.setFill()
            rect.fill()
            NSColor.black.setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: rect.height * blackFraction).fill()
            return true
        }
        let tiff = image.tiffRepresentation!
        return NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
    }

    private func hsb(_ color: Color) -> (h: CGFloat, s: CGFloat, b: CGFloat) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB)!
        return (ns.hueComponent, ns.saturationComponent, ns.brightnessComponent)
    }

    func testPicksTheVividColor() {
        let data = imageData(color: NSColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        let accent = ArtworkColor.dominant(in: data)
        XCTAssertNotNil(accent)
        let (h, s, _) = hsb(accent!)
        XCTAssertTrue(h < 0.06 || h > 0.94, "expected red hue, got \(h)")
        XCTAssertGreaterThan(s, 0.5)
    }

    func testIgnoresDominantBlack() {
        // 80% black, 20% blue: black must not win, and must not be returned.
        let data = imageData(color: NSColor(red: 0.15, green: 0.3, blue: 0.9, alpha: 1), blackFraction: 0.8)
        let accent = ArtworkColor.dominant(in: data)
        XCTAssertNotNil(accent)
        let (h, _, b) = hsb(accent!)
        XCTAssertEqual(h, 0.63, accuracy: 0.08, "expected blue hue, got \(h)")
        XCTAssertGreaterThanOrEqual(b, 0.6, "accent must stay readable on black")
    }

    func testColorlessArtReturnsNil() {
        let gray = imageData(color: NSColor(white: 0.5, alpha: 1))
        XCTAssertNil(ArtworkColor.dominant(in: gray), "gray art falls back to the fixed accent")
        let black = imageData(color: .black)
        XCTAssertNil(ArtworkColor.dominant(in: black))
    }

    func testBrightnessIsFloored() {
        // Dark but saturated red: usable hue, brightness lifted to readable.
        let data = imageData(color: NSColor(red: 0.35, green: 0.02, blue: 0.02, alpha: 1))
        if let accent = ArtworkColor.dominant(in: data) {
            XCTAssertGreaterThanOrEqual(hsb(accent).b, 0.6)
        }
        // nil is also acceptable here (below the brightness cutoff): the
        // fallback peach takes over. What may never happen is a dark accent.
    }

    func testGarbageDataReturnsNil() {
        XCTAssertNil(ArtworkColor.dominant(in: Data("not an image".utf8)))
    }
}
