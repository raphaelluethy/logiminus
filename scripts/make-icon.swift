// Renders the app icon: a dark squircle with a soft spotlight and a red laser dot.
//   swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let rgb = CGColorSpaceCreateDeviceRGB()

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor(white: 0, alpha: 0.35).cgColor)
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let bg = CGGradient(colorsSpace: rgb, colors: [
        NSColor(srgbRed: 0.15, green: 0.16, blue: 0.24, alpha: 1).cgColor,
        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.09, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])

    // Spotlight: soft-edged pool of light.
    let c = CGPoint(x: s * 0.54, y: s * 0.53)
    let r = s * 0.27
    let light = CGGradient(colorsSpace: rgb, colors: [
        NSColor(white: 1, alpha: 0.42).cgColor,
        NSColor(white: 1, alpha: 0.30).cgColor,
        NSColor(white: 1, alpha: 0.0).cgColor,
    ] as CFArray, locations: [0, 0.9, 1])!
    ctx.drawRadialGradient(light, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])

    // Laser dot with glow.
    let glow = CGGradient(colorsSpace: rgb, colors: [
        NSColor(srgbRed: 1, green: 0.2, blue: 0.15, alpha: 0.55).cgColor,
        NSColor(srgbRed: 1, green: 0.2, blue: 0.15, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.12, options: [])
    let dr = s * 0.045
    ctx.setFillColor(NSColor(srgbRed: 1, green: 0.17, blue: 0.12, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - dr, y: c.y - dr, width: 2 * dr, height: 2 * dr))
    ctx.setFillColor(NSColor(white: 1, alpha: 0.85).cgColor)
    let hr = dr * 0.35
    ctx.fillEllipse(in: CGRect(x: c.x - dr * 0.35 - hr / 2, y: c.y + dr * 0.25 - hr / 2, width: hr, height: hr))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try render(base * scale).write(to: out.appendingPathComponent(name))
    }
}
