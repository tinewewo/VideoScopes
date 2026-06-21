import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// App icon: a vectorscope — dark squircle, graticule ring + crosshair, a green
// centre trace glow, and the six colour-bar targets at their Rec.709 angles.

let CS = CGColorSpaceCreateDeviceRGB()
func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
    CGColor(colorSpace: CS, components: [r, g, b, a])!
}

func cbcr709(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
    let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    return ((b - y) / (2 * (1 - 0.0722)), (r - y) / (2 * (1 - 0.2126)))
}

// rgb to derive angle, plus the vivid display colour for the dot
let targets: [(Double, Double, Double, CGFloat, CGFloat, CGFloat)] = [
    (1, 0, 0, 1.00, 0.27, 0.27),   // R
    (1, 1, 0, 0.92, 0.79, 0.20),   // Yl
    (0, 1, 0, 0.28, 0.84, 0.36),   // G
    (0, 1, 1, 0.22, 0.83, 0.90),   // Cy
    (0, 0, 1, 0.30, 0.48, 1.00),   // B
    (1, 0, 1, 0.90, 0.42, 0.86),   // Mg
]

func drawIcon(_ S: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CS,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let f = CGFloat(S)
    ctx.setAllowsAntialiasing(true)

    // rounded-rect tile with a subtle vertical gradient
    let m = f * 0.045
    let rect = CGRect(x: m, y: m, width: f - 2 * m, height: f - 2 * m)
    let radius = (f - 2 * m) * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let bg = CGGradient(colorsSpace: CS,
                        colors: [col(0.08, 0.11, 0.17, 1), col(0.02, 0.03, 0.05, 1)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: f), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    let cx = f / 2, cy = f / 2
    let rOuter = (f - 2 * m) * 0.40

    // centre green trace glow
    let glow = CGGradient(colorsSpace: CS,
                          colors: [col(0.42, 1.0, 0.58, 0.95), col(0.3, 0.9, 0.5, 0.0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                           endCenter: CGPoint(x: cx, y: cy), endRadius: rOuter * 0.55, options: [])

    // graticule ring + crosshair
    ctx.setStrokeColor(col(0.42, 0.50, 0.60, 0.6))
    ctx.setLineWidth(max(1, f * 0.007))
    ctx.strokeEllipse(in: CGRect(x: cx - rOuter, y: cy - rOuter, width: 2 * rOuter, height: 2 * rOuter))
    ctx.setStrokeColor(col(0.42, 0.50, 0.60, 0.35))
    ctx.setLineWidth(max(1, f * 0.004))
    ctx.move(to: CGPoint(x: cx - rOuter, y: cy)); ctx.addLine(to: CGPoint(x: cx + rOuter, y: cy)); ctx.strokePath()
    ctx.move(to: CGPoint(x: cx, y: cy - rOuter)); ctx.addLine(to: CGPoint(x: cx, y: cy + rOuter)); ctx.strokePath()

    // six colour targets at their Rec.709 angles (even hexagon)
    let rDot = rOuter * 0.82
    let dotR = f * 0.055
    for t in targets {
        let (cb, cr) = cbcr709(t.0, t.1, t.2)
        let ang = atan2(cr, cb)
        let px = cx + rDot * CGFloat(cos(ang))
        let py = cy + rDot * CGFloat(sin(ang))      // CG y is up, Cr is up
        let c = col(t.3, t.4, t.5, 1)
        ctx.setFillColor(col(t.3, t.4, t.5, 0.30))  // halo
        ctx.fillEllipse(in: CGRect(x: px - dotR * 1.9, y: py - dotR * 1.9, width: dotR * 3.8, height: dotR * 3.8))
        ctx.setFillColor(c)
        ctx.fillEllipse(in: CGRect(x: px - dotR, y: py - dotR, width: 2 * dotR, height: 2 * dotR))
    }
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, image, nil)
    CGImageDestinationFinalize(dst)
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/VideoScopes.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in variants {
    writePNG(drawIcon(px), "\(outDir)/\(name).png")
}
writePNG(drawIcon(512), "/tmp/icon_preview.png")
print("wrote iconset to \(outDir)")
