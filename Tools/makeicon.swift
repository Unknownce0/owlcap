// Renders AppIcon.iconset — an owl whose eyes are a record button.
// Run: swift Tools/makeicon.swift <output-iconset-dir>
import AppKit

func draw(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size

    // Rounded-square body with a warm night gradient.
    let inset = s * 0.055
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: s * 0.235, cornerHeight: s * 0.235, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.32, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.36, green: 0.20, blue: 0.52, alpha: 1).cgColor]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
    ctx.restoreGState()

    // Ear tufts.
    let tuft = CGMutablePath()
    tuft.move(to: CGPoint(x: s * 0.28, y: s * 0.78))
    tuft.addLine(to: CGPoint(x: s * 0.36, y: s * 0.93))
    tuft.addLine(to: CGPoint(x: s * 0.46, y: s * 0.80))
    tuft.closeSubpath()
    tuft.move(to: CGPoint(x: s * 0.72, y: s * 0.78))
    tuft.addLine(to: CGPoint(x: s * 0.64, y: s * 0.93))
    tuft.addLine(to: CGPoint(x: s * 0.54, y: s * 0.80))
    tuft.closeSubpath()
    ctx.addPath(tuft)
    ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.83, blue: 0.42, alpha: 1).cgColor)
    ctx.fillPath()

    // Eyes: the left one is a record button.
    func eye(center: CGPoint, radius: CGFloat, pupil: NSColor) {
        ctx.setFillColor(NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                   width: radius * 2, height: radius * 2))
        let pr = radius * 0.52
        ctx.setFillColor(pupil.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - pr, y: center.y - pr, width: pr * 2, height: pr * 2))
    }
    let r = s * 0.175
    eye(center: CGPoint(x: s * 0.365, y: s * 0.545), radius: r,
        pupil: NSColor(calibratedRed: 0.92, green: 0.22, blue: 0.24, alpha: 1))
    eye(center: CGPoint(x: s * 0.635, y: s * 0.545), radius: r,
        pupil: NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.30, alpha: 1))

    // Beak.
    let beak = CGMutablePath()
    beak.move(to: CGPoint(x: s * 0.50, y: s * 0.285))
    beak.addLine(to: CGPoint(x: s * 0.445, y: s * 0.395))
    beak.addLine(to: CGPoint(x: s * 0.555, y: s * 0.395))
    beak.closeSubpath()
    ctx.addPath(beak)
    ctx.setFillColor(NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.28, alpha: 1).cgColor)
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (size, name) in sizes {
    let rep = draw(size: CGFloat(size))
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("wrote \(sizes.count) icon sizes to \(out)")
