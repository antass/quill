import AppKit
import Foundation

// Renders Quill's app icon at every size macOS asks for.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = body.width * 0.225

    // Background gradient
    let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.35, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.42, green: 0.24, blue: 0.72, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: body.minX, y: body.maxY),
                               end: CGPoint(x: body.maxX, y: body.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Broadcast arcs, anchored bottom-left like the classic feed mark
    let origin = CGPoint(x: body.minX + body.width * 0.30, y: body.minY + body.height * 0.30)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round)

    for (index, factor) in [0.26, 0.46].enumerated() {
        let r = body.width * factor
        ctx.setLineWidth(body.width * (index == 0 ? 0.088 : 0.088))
        ctx.addArc(center: origin, radius: r, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        ctx.strokePath()
    }

    ctx.setFillColor(NSColor.white.cgColor)
    let dot = body.width * 0.062
    ctx.fillEllipse(in: CGRect(x: origin.x - dot, y: origin.y - dot, width: dot * 2, height: dot * 2))

    image.unlockFocus()
    return image
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./Quill.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(outputDir)/\(name).png"))
}
print("wrote iconset to \(outputDir)")
