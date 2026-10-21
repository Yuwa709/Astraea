// Draws the DMG window background: a night sky in the app icon's purple,
// a golden halo where the app icon sits, and a golden arrow to Applications.
//
// Run by scripts/release.sh, never part of the app target:
//     swift scripts/dmg-background.swift <out-dir>
// Writes background.png (660x400) and background@2x.png (1320x800).
//
// The layout constants must match the Finder positions release.sh sets:
// window content 660x400, app icon centred at (170, 190), Applications at
// (490, 190), both in Finder's top-left coordinates. Stars come from a fixed
// seed, so every release draws the same sky.
import AppKit

let width: CGFloat = 660
let height: CGFloat = 400
let appCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 490, y: 190)

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: dmg-background.swift <out-dir>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

/// Finder's top-left coordinates to Core Graphics' bottom-left ones.
func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Deterministic, so the sky is identical across releases.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(state >> 11) / CGFloat(1 << 53)
    }
}

func radialGlow(_ ctx: CGContext, at center: CGPoint, radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                    colors: [color(hex, alpha), color(hex, 0)] as CFArray,
                                    locations: [0, 1]) else { return }
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius, options: [])
}

func sparkle(_ ctx: CGContext, at p: CGPoint, size: CGFloat, _ hex: UInt32, _ alpha: CGFloat) {
    radialGlow(ctx, at: p, radius: size * 2.2, hex, alpha * 0.35)
    ctx.setFillColor(color(hex, alpha))
    let path = CGMutablePath()
    let thin = size * 0.16
    path.move(to: CGPoint(x: p.x, y: p.y + size))
    path.addQuadCurve(to: CGPoint(x: p.x + size, y: p.y), control: CGPoint(x: p.x + thin, y: p.y + thin))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y - size), control: CGPoint(x: p.x + thin, y: p.y - thin))
    path.addQuadCurve(to: CGPoint(x: p.x - size, y: p.y), control: CGPoint(x: p.x - thin, y: p.y - thin))
    path.addQuadCurve(to: CGPoint(x: p.x, y: p.y + size), control: CGPoint(x: p.x - thin, y: p.y + thin))
    ctx.addPath(path)
    ctx.fillPath()
}

func drawText(_ text: String, font: NSFont, color textColor: NSColor, kern: CGFloat, centerX: CGFloat, top: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .kern: kern]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    string.draw(at: CGPoint(x: centerX - size.width / 2, y: height - top - size.height))
}

func draw(_ ctx: CGContext) {
    // Sky: near-black indigo at the top into the icon's violet at the bottom.
    if let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                            colors: [color(0x0B0420), color(0x1C0A45), color(0x35107A)] as CFArray,
                            locations: [0, 0.55, 1]) {
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
    }

    // Nebula haze.
    radialGlow(ctx, at: CGPoint(x: 90, y: 330), radius: 260, 0x6A2BD9, 0.28)
    radialGlow(ctx, at: CGPoint(x: 600, y: 60), radius: 280, 0xB0309E, 0.20)
    radialGlow(ctx, at: CGPoint(x: 420, y: 380), radius: 200, 0x3A4BE0, 0.16)

    // Star field, kept clear of the two icons and the title.
    var random = SeededRandom(state: 0xA57AEA)
    for _ in 0..<170 {
        let p = CGPoint(x: random.next() * width, y: random.next() * height)
        let finder = flip(p)
        let nearIcon = hypot(finder.x - appCenter.x, finder.y - appCenter.y) < 80
            || hypot(finder.x - applicationsCenter.x, finder.y - applicationsCenter.y) < 80
        let r = 0.35 + random.next() * random.next() * 1.3
        let alpha = 0.25 + random.next() * 0.65
        if nearIcon { continue }
        ctx.setFillColor(color(random.next() < 0.15 ? 0xFFE6A8 : 0xFFFFFF, alpha))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // A few golden four-point sparkles, echoing the icon's star.
    for (x, y, s, a) in [(58.0, 62.0, 7.0, 0.9), (612.0, 96.0, 5.5, 0.8), (322.0, 300.0, 4.5, 0.7),
                         (596.0, 338.0, 6.5, 0.85), (40.0, 300.0, 4.0, 0.6), (150.0, 150.0, 3.5, 0.6)] {
        sparkle(ctx, at: flip(CGPoint(x: x, y: y)), size: s, 0xFFD45C, a)
    }

    // Golden halo behind the app icon, soft violet one behind Applications.
    radialGlow(ctx, at: flip(appCenter), radius: 115, 0xFFD86B, 0.20)
    radialGlow(ctx, at: flip(appCenter), radius: 62, 0xFFF2C4, 0.16)
    radialGlow(ctx, at: flip(applicationsCenter), radius: 105, 0x9C7BFF, 0.22)

    // Arrow: a shallow golden arc between the icons, dotted like a star trail,
    // with a solid head.
    let start = flip(CGPoint(x: appCenter.x + 92, y: appCenter.y))
    let end = flip(CGPoint(x: applicationsCenter.x - 96, y: applicationsCenter.y))
    let control = CGPoint(x: (start.x + end.x) / 2, y: start.y + 34)
    let steps = 15
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let u = 1 - t
        let p = CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                        y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        let r = 1.4 + t * 1.6
        radialGlow(ctx, at: p, radius: r * 3.5, 0xFFC93C, 0.25)
        ctx.setFillColor(color(0xFFD45C, 0.45 + t * 0.55))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }
    // Head, pointing along the curve's final tangent.
    let angle = atan2(end.y - control.y, end.x - control.x)
    let tip = CGPoint(x: end.x + 12 * cos(angle), y: end.y + 12 * sin(angle))
    let back: CGFloat = 15, spread: CGFloat = 0.55
    let head = CGMutablePath()
    head.move(to: tip)
    head.addLine(to: CGPoint(x: tip.x - back * cos(angle - spread), y: tip.y - back * sin(angle - spread)))
    head.addLine(to: CGPoint(x: tip.x - back * 0.55 * cos(angle), y: tip.y - back * 0.55 * sin(angle)))
    head.addLine(to: CGPoint(x: tip.x - back * cos(angle + spread), y: tip.y - back * sin(angle + spread)))
    head.closeSubpath()
    radialGlow(ctx, at: tip, radius: 16, 0xFFC93C, 0.35)
    ctx.setFillColor(color(0xFFD45C))
    ctx.addPath(head)
    ctx.fillPath()

    // Title and instruction. AppKit text drawing needs the context current.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let titleFont = NSFont.systemFont(ofSize: 30, weight: .semibold)
    let rounded = titleFont.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 30) } ?? titleFont
    drawText("Astraea", font: rounded, color: NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 1),
             kern: 1.5, centerX: width / 2, top: 30)
    drawText("Drag Astraea into Applications to install",
             font: NSFont.systemFont(ofSize: 13, weight: .medium),
             color: NSColor(white: 1, alpha: 0.62), kern: 0.3, centerX: width / 2, top: 346)
    NSGraphicsContext.restoreGraphicsState()
}

func render(scale: CGFloat, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let graphics = NSGraphicsContext(bitmapImageRep: rep)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = NSSize(width: width, height: height)
    let ctx = graphics.cgContext
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx)
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: url)
}

do {
    try render(scale: 1, to: outDir.appendingPathComponent("background.png"))
    try render(scale: 2, to: outDir.appendingPathComponent("background@2x.png"))
} catch {
    FileHandle.standardError.write(Data("dmg-background: \(error)\n".utf8))
    exit(1)
}
