// Draws the FaceRec app icon and writes every size the asset catalog needs.
// Usage: swift Tools/make_icon.swift FaceRec/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    let g = context.cgContext
    let s = CGFloat(pixels) / 1024          // design in a 1024 canvas, y up
    g.scaleBy(x: s, y: s)
    func rgb(_ r: CGFloat, _ gr: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: r / 255, green: gr / 255, blue: b / 255, alpha: a)
    }
    let space = CGColorSpaceCreateDeviceRGB()

    // Rounded tile, following the macOS icon grid (824 pt tile in a 1024 canvas).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
    g.addPath(shape); g.setFillColor(rgb(12, 18, 28)); g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(shape); g.clip()
    let background = CGGradient(colorsSpace: space, colors: [rgb(28, 40, 62), rgb(9, 13, 22)] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft green glow behind the face.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(64, 220, 110, 0.30), rgb(64, 220, 110, 0)] as CFArray, locations: [0, 1])!
    g.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 500), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 500), endRadius: 420, options: [])

    // The face: head and shoulders, in a pale gradient.
    let person = CGMutablePath()
    person.addEllipse(in: CGRect(x: 512 - 112, y: 520, width: 224, height: 248))
    person.move(to: CGPoint(x: 512 - 196, y: 296))
    person.addCurve(to: CGPoint(x: 512, y: 474), control1: CGPoint(x: 512 - 196, y: 410), control2: CGPoint(x: 512 - 120, y: 474))
    person.addCurve(to: CGPoint(x: 512 + 196, y: 296), control1: CGPoint(x: 512 + 120, y: 474), control2: CGPoint(x: 512 + 196, y: 410))
    person.closeSubpath()
    g.saveGState()
    g.addPath(person); g.clip()
    let skin = CGGradient(colorsSpace: space, colors: [rgb(245, 250, 255), rgb(168, 186, 210)] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(skin, start: CGPoint(x: 512, y: 770), end: CGPoint(x: 512, y: 296), options: [])
    g.restoreGState()

    // Four rounded corner brackets, the app's face marker.
    let box = CGRect(x: 232, y: 232, width: 560, height: 560)
    let arm: CGFloat = 150, radius: CGFloat = 70
    let brackets = CGMutablePath()
    func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
        brackets.move(to: CGPoint(x: x, y: y + dy * arm))
        brackets.addLine(to: CGPoint(x: x, y: y + dy * radius))
        brackets.addQuadCurve(to: CGPoint(x: x + dx * radius, y: y), control: CGPoint(x: x, y: y))
        brackets.addLine(to: CGPoint(x: x + dx * arm, y: y))
    }
    corner(box.minX, box.minY, 1, 1); corner(box.maxX, box.minY, -1, 1)
    corner(box.minX, box.maxY, 1, -1); corner(box.maxX, box.maxY, -1, -1)
    g.saveGState()
    g.setShadow(offset: .zero, blur: 30, color: rgb(64, 220, 110, 0.8))
    g.addPath(brackets)
    g.setStrokeColor(rgb(74, 226, 120)); g.setLineWidth(44); g.setLineCap(.round); g.setLineJoin(.round)
    g.strokePath()
    g.restoreGState()
    g.restoreGState()

    // A thin light rim on the tile.
    g.addPath(shape); g.setStrokeColor(rgb(255, 255, 255, 0.10)); g.setLineWidth(4); g.strokePath()
    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

var images: [[String: String]] = []
for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try draw(points * scale)?.write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icon images to \(output.path)")
