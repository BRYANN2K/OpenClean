// Renders the OpenClean app icon (same geometry as AppIconView in Theme.swift) to an .icns file.
// Usage: swift scripts/make-app-icon.swift Apps/OpenClean/Resources/AppIcon.icns
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws into a square of side `size` using a y-down coordinate space, like the SVG and SwiftUI versions.
func drawIcon(in context: CGContext, size: CGFloat) {
    context.translateBy(x: 0, y: size)
    context.scaleBy(x: 1, y: -1)

    // macOS icon grid: the artwork is a 824/1024 squircle centred in the canvas.
    let inset = size * 100 / 1024
    let side = size - inset * 2
    let tile = CGRect(x: inset, y: inset, width: side, height: side)
    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: size * 0.012), blur: size * 0.03, color: color(0x000000, 0.3))
    context.addPath(tilePath)
    context.setFillColor(color(0x0A4756))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let background = CGGradient(
        colorsSpace: space, colors: [color(0x4BF2B8), color(0x12A88B), color(0x0A4756)] as CFArray,
        locations: [0, 0.5, 1])!
    context.drawLinearGradient(
        background, start: tile.origin, end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])
    let gloss = CGGradient(
        colorsSpace: space, colors: [color(0xFFFFFF, 0.5), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    let glossCenter = CGPoint(x: tile.minX + side * 0.3, y: tile.minY + side * 0.15)
    context.drawRadialGradient(
        gloss, startCenter: glossCenter, startRadius: 0, endCenter: glossCenter, endRadius: side * 0.6, options: [])
    context.restoreGState()

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tile.minX + x * side, y: tile.minY + y * side) }

    // Open ring, with a soft shadow below it.
    let ring = CGMutablePath()
    let center = point(0.5, 0.534)
    let radius = side * 0.267
    for degrees in stride(from: 0.0, through: 270.0, by: 1) {
        let radians = CGFloat(degrees) * .pi / 180
        let p = CGPoint(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
        if ring.isEmpty { ring.move(to: p) } else { ring.addLine(to: p) }
    }
    context.setLineCap(.round)
    context.setLineWidth(side * 0.112)
    context.saveGState()
    context.translateBy(x: 0, y: side * 0.017)
    context.addPath(ring)
    context.setStrokeColor(color(0x04303A, 0.28))
    context.strokePath()
    context.restoreGState()
    context.addPath(ring)
    context.setStrokeColor(color(0xFFFFFF))
    context.strokePath()

    func spark(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, alpha: CGFloat) {
        let c = point(cx, cy)
        let r = r * side
        let near = r * 0.112
        let far = r * 0.224
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x, y: c.y - r))
        path.addCurve(
            to: CGPoint(x: c.x + r, y: c.y), control1: CGPoint(x: c.x + near, y: c.y - far),
            control2: CGPoint(x: c.x + far, y: c.y - near))
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y + r), control1: CGPoint(x: c.x + far, y: c.y + near),
            control2: CGPoint(x: c.x + near, y: c.y + far))
        path.addCurve(
            to: CGPoint(x: c.x - r, y: c.y), control1: CGPoint(x: c.x - near, y: c.y + far),
            control2: CGPoint(x: c.x - far, y: c.y + near))
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y - r), control1: CGPoint(x: c.x - far, y: c.y - near),
            control2: CGPoint(x: c.x - near, y: c.y - far))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color(0xFFFFFF, alpha))
        context.fillPath()
    }
    spark(0.716, 0.316, 0.119, alpha: 1)
    spark(0.85, 0.133, 0.044, alpha: 0.85)
}

func png(size: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    drawIcon(in: context, size: CGFloat(size))
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-app-icon.swift <output.icns>\n".data(using: .utf8)!)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
exit(iconutil.terminationStatus)
