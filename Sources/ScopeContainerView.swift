import Cocoa

// Wraps a ScopeView and draws scale labels / ticks. Labels are rendered by a
// transparent overlay placed ABOVE the Metal view, so they stay visible even
// where the scope fills the whole content area (e.g. the square vectorscope).
final class ScopeContainerView: NSView {
    let kind: ScopeKind
    let scopeView: ScopeView
    private let overlay = ScaleOverlay()

    private let tickColor = NSColor(white: 0.34, alpha: 1)
    private let textColor = NSColor(white: 0.62, alpha: 1)
    private let rCol = NSColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1)
    private let gCol = NSColor(red: 0.42, green: 1.0, blue: 0.46, alpha: 1)
    private let bCol = NSColor(red: 0.50, green: 0.66, blue: 1.0, alpha: 1)

    init(kind: ScopeKind) {
        self.kind = kind
        self.scopeView = ScopeView(kind: kind)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.045, alpha: 1).cgColor
        addSubview(scopeView)
        overlay.container = self
        addSubview(overlay)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var insets: NSEdgeInsets {
        switch kind {
        case .waveform, .parade:       return NSEdgeInsets(top: 16, left: 32, bottom: 16, right: 8)
        case .histogram:               return NSEdgeInsets(top: 6, left: 12, bottom: 18, right: 8)
        case .vectorscope, .diamond, .arrowhead:
                                       return NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }
    }

    override func layout() {
        super.layout()
        let i = insets
        scopeView.frame = NSRect(x: i.left, y: i.bottom,
                                 width: max(1, bounds.width - i.left - i.right),
                                 height: max(1, bounds.height - i.top - i.bottom))
        overlay.frame = bounds
        overlay.needsDisplay = true
    }

    private func label(_ s: String, _ color: NSColor, _ size: CGFloat = 10) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: color])
    }

    // called by the overlay (draws into the overlay's graphics context)
    fileprivate func drawScales() {
        let r = scopeView.frame
        switch kind {
        case .waveform:    drawVScale(r)
        case .parade:      drawVScale(r); drawParadeLabels(r)
        case .histogram:   drawHScale(r); drawLegend(at: NSPoint(x: r.maxX - 56, y: r.maxY - 14))
        case .vectorscope: drawVectorLabels(r)
        case .diamond:     drawDiamondLabels(r)
        case .arrowhead:   drawArrowheadScale(r)
        }
    }

    private func drawVScale(_ r: NSRect) {
        tickColor.setStroke()
        for (txt, f) in [("100", 1.0), ("75", 0.75), ("50", 0.5), ("25", 0.25), ("0", 0.0)] {
            let y = r.minY + CGFloat(f) * r.height
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX - 4, y: y)); p.line(to: NSPoint(x: r.minX, y: y))
            p.lineWidth = 1; p.stroke()
            let a = label(txt, textColor); let sz = a.size()
            a.draw(at: NSPoint(x: r.minX - 6 - sz.width, y: y - sz.height / 2))
        }
        label("%", textColor, 9).draw(at: NSPoint(x: 6, y: r.maxY + 1))
    }

    private func drawHScale(_ r: NSRect) {
        tickColor.setStroke()
        for (txt, f) in [("0", 0.0), ("25", 0.25), ("50", 0.5), ("75", 0.75), ("100", 1.0)] {
            let x = r.minX + CGFloat(f) * r.width
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: r.minY)); p.line(to: NSPoint(x: x, y: r.minY - 4))
            p.lineWidth = 1; p.stroke()
            let a = label(txt, textColor, 9); let sz = a.size()
            let lx = min(max(x - sz.width / 2, 0), bounds.width - sz.width)
            a.draw(at: NSPoint(x: lx, y: r.minY - 5 - sz.height))
        }
    }

    private func drawParadeLabels(_ r: NSRect) {
        let cols = [("R", rCol), ("G", gCol), ("B", bCol)]
        for (k, pair) in cols.enumerated() {
            let cx = r.minX + (CGFloat(k) + 0.5) * r.width / 3
            let a = label(pair.0, pair.1, 11); let sz = a.size()
            a.draw(at: NSPoint(x: cx - sz.width / 2, y: r.maxY + 1))
        }
    }

    private func drawLegend(at p: NSPoint) {
        var x = p.x
        for pair in [("R", rCol), ("G", gCol), ("B", bCol)] {
            label(pair.0, pair.1, 10).draw(at: NSPoint(x: x, y: p.y)); x += 18
        }
    }

    private func drawVectorLabels(_ r: NSRect) {
        let S = 0.8 * r.width
        let cx = r.midX, cy = r.midY
        let bars: [(String, (Double, Double, Double))] = [
            ("Yl", (0.75, 0.75, 0)), ("Cy", (0, 0.75, 0.75)), ("G", (0, 0.75, 0)),
            ("Mg", (0.75, 0, 0.75)), ("R", (0.75, 0, 0)), ("B", (0, 0, 0.75))]
        for (name, rgb) in bars {
            let (cb, cr) = cbcr709(rgb)
            let mag = max(0.0001, (cb * cb + cr * cr).squareRoot())
            let px = cx + CGFloat(cb) * S + CGFloat(cb / mag) * 13
            let py = cy + CGFloat(cr) * S + CGFloat(cr / mag) * 13   // Cr up = view y up
            let a = label(name, NSColor(white: 0.78, alpha: 1), 10); let sz = a.size()
            a.draw(at: NSPoint(x: px - sz.width / 2, y: py - sz.height / 2))
        }
        // intermediate hue targets (angular midpoints between adjacent colours)
        let inter: [(String, (Double, Double))] = [
            ("R-Mg", (0.0985, 0.4040)), ("R-Yl", (-0.2866, 0.2506)), ("Yl-G", (-0.3812, -0.1555)),
            ("G-Cy", (-0.0985, -0.4040)), ("Cy-B", (0.2866, -0.2506)), ("B-Mg", (0.3812, 0.1555))]
        for (name, p) in inter {
            let (cb, cr) = p
            let mag = max(0.0001, (cb * cb + cr * cr).squareRoot())
            let px = cx + CGFloat(cb) * S + CGFloat(cb / mag) * 16
            let py = cy + CGFloat(cr) * S + CGFloat(cr / mag) * 16
            let a = label(name, NSColor(white: 0.5, alpha: 1), 8); let sz = a.size()
            a.draw(at: NSPoint(x: px - sz.width / 2, y: py - sz.height / 2))
        }
        // current magnification indicator
        let g = MetalEngine.shared.vectorGain
        if g > 1.001 {
            label(String(format: "gain ×%g", g), NSColor(white: 0.82, alpha: 1), 11)
                .draw(at: NSPoint(x: r.minX + 8, y: r.maxY - 18))
        }
    }

    func refreshOverlay() { overlay.needsDisplay = true }

    private func drawDiamondLabels(_ r: NSRect) {
        let cx = r.midX, my = r.midY
        let S = 0.22 * r.height
        func put(_ s: String, _ x: CGFloat, _ y: CGFloat, _ c: NSColor, _ sz: CGFloat = 10) {
            let a = label(s, c, sz); let z = a.size()
            a.draw(at: NSPoint(x: x - z.width / 2, y: y - z.height / 2))
        }
        put("B", cx + S + 10, my + S, bCol)
        put("G", cx - S - 10, my + S, gCol)
        put("R", cx + S + 10, my - S, rCol)
        put("G", cx - S - 10, my - S, gCol)
        put("100%", cx, my + 2 * S + 9, textColor, 9)
        put("0", cx + 13, my, textColor, 9)
        put("100%", cx, my - 2 * S - 9, textColor, 9)
    }

    private func drawArrowheadScale(_ r: NSRect) {
        let ax = r.minX + 0.12 * r.width
        let y0 = r.minY + 0.06 * r.height   // luma 0
        let y1 = r.minY + 0.94 * r.height   // luma 100 %
        tickColor.setStroke()
        for (txt, f) in [("100", 1.0), ("75", 0.75), ("50", 0.5), ("25", 0.25), ("0", 0.0)] {
            let y = y0 + CGFloat(f) * (y1 - y0)
            let a = label(txt, textColor, 9); let sz = a.size()
            a.draw(at: NSPoint(x: ax - 6 - sz.width, y: y - sz.height / 2))
        }
        label("luma %", textColor, 8).draw(at: NSPoint(x: 2, y: y1 + 3))
    }

    // matches rgb_to_ycbcr() in the shader for Rec.709
    private func cbcr709(_ rgb: (Double, Double, Double)) -> (Double, Double) {
        let (r, g, b) = rgb
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return ((b - y) / (2 * (1 - 0.0722)), (r - y) / (2 * (1 - 0.2126)))
    }
}

private final class ScaleOverlay: NSView {
    weak var container: ScopeContainerView?
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // pass interaction through
    override func draw(_ dirtyRect: NSRect) { container?.drawScales() }
}
