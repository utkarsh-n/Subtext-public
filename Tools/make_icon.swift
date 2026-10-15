import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 1024×1024 opaque icon drawn straight into a CGContext (NSImage.lockFocus renders at 2x).
let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

let colors = [CGColor(colorSpace: space, components: [0.09, 0.09, 0.12, 1])!, CGColor(colorSpace: space, components: [0.02, 0.02, 0.04, 1])!] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

let amber = CGColor(colorSpace: space, components: [1.0, 0.84, 0.42, 1])!
let white = CGColor(colorSpace: space, components: [0.95, 0.95, 0.97, 1])!
let dim = CGColor(colorSpace: space, components: [0.55, 0.55, 0.6, 1])!

// Dynamic Island pill.
let pill = CGRect(x: 262, y: 760, width: 500, height: 150)
ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 75, cornerHeight: 75, transform: nil))
ctx.fillPath()
ctx.setStrokeColor(CGColor(colorSpace: space, components: [0.3, 0.3, 0.34, 1])!)
ctx.setLineWidth(6)
ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 75, cornerHeight: 75, transform: nil))
ctx.strokePath()
// A glowing dot in the pill (the listening indicator).
ctx.setFillColor(amber)
ctx.fillEllipse(in: CGRect(x: 322, y: 805, width: 60, height: 60))
// Short caption bar inside the pill.
ctx.setFillColor(white)
ctx.addPath(CGPath(roundedRect: CGRect(x: 420, y: 818, width: 280, height: 34), cornerWidth: 17, cornerHeight: 17, transform: nil))
ctx.fillPath()

// Subtitle lines below, like captions on a screen.
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ color: CGColor) {
    ctx.setFillColor(color)
    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 58), cornerWidth: 29, cornerHeight: 29, transform: nil))
    ctx.fillPath()
}
bar(192, 420, 640, white)
bar(292, 320, 440, white)
bar(232, 190, 560, dim)
bar(342, 90, 340, dim)

let image = ctx.makeImage()!
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.path) \(image.width)x\(image.height)")
