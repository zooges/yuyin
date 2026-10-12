// Renders the Yuyin (余音, "lingering sound") app icon: a coral sound source with three
// echo arcs fading into a dark field — the same palette as the app.
//
//     swift scripts/make_icon.swift
//
// Writes the macOS / iOS icons into the asset catalog and docs/assets/logo.png.
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconSet = root.appendingPathComponent("Apps/Yuyin/Resources/Assets.xcassets/AppIcon.appiconset")
let docs = root.appendingPathComponent("docs/assets")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let coral = color(1.00, 0.37, 0.33)
let coralLight = color(1.00, 0.50, 0.42)

/// Draws the artwork into `rect` (a square), in a context whose origin is bottom-left.
func drawArtwork(_ ctx: CGContext, in rect: CGRect) {
    let w = rect.width
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * w) }

    // Field: charcoal, a little lighter at the top.
    let field = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        color(0.17, 0.17, 0.21), color(0.06, 0.06, 0.08),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(field, start: p(0.5, 1), end: p(0.5, 0), options: [])

    // The group (dot + arcs) is centred optically: the dot sits left of centre.
    let center = p(0.36, 0.5)

    // Soft coral glow behind the source.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
        color(1.00, 0.37, 0.33, 0.28), color(1.00, 0.37, 0.33, 0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 0.42 * w, options: [])

    // Echo arcs, fading as they travel.
    ctx.setLineCap(.round)
    ctx.setLineWidth(0.052 * w)
    for (radius, alpha) in [(0.235, 0.9), (0.33, 0.55), (0.425, 0.26)] as [(CGFloat, CGFloat)] {
        ctx.setStrokeColor(color(1.00, 0.37, 0.33, alpha))
        ctx.addArc(center: center, radius: radius * w, startAngle: -.pi * 0.27, endAngle: .pi * 0.27, clockwise: false)
        ctx.strokePath()
    }

    // The source: a coral dot with a gentle top highlight.
    let r = 0.125 * w
    let dot = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    ctx.saveGState()
    ctx.addEllipse(in: dot)
    ctx.clip()
    let fill = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [coralLight, coral] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: center.x, y: dot.maxY), end: CGPoint(x: center.x, y: dot.minY), options: [])
    ctx.restoreGState()
}

/// macOS: rounded body on the 1024 grid (824 pt, 100 pt margin) with a soft shadow.
/// iOS: full bleed; the system applies the mask.
func render(pixels: Int, mac: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(pixels) / 1024
    ctx.scaleBy(x: s, y: s)
    ctx.interpolationQuality = .high
    if mac {
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(color(0.06, 0.06, 0.08))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        drawArtwork(ctx, in: body)
        ctx.restoreGState()
        // Hairline edge, as on the app's panels.
        ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 184, cornerHeight: 184, transform: nil))
        ctx.setStrokeColor(color(1, 1, 1, 0.10))
        ctx.setLineWidth(3)
        ctx.strokePath()
    } else {
        drawArtwork(ctx, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

var images: [[String: String]] = []
try render(pixels: 1024, mac: false).write(to: iconSet.appendingPathComponent("icon-ios-1024.png"))
images.append(["filename": "icon-ios-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
for point in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon-mac-\(point)@\(scale)x.png"
        try render(pixels: point * scale, mac: true).write(to: iconSet.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(point)x\(point)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconSet.appendingPathComponent("Contents.json"))
try render(pixels: 512, mac: true).write(to: docs.appendingPathComponent("logo.png"))
print("icons written to \(iconSet.path)")
