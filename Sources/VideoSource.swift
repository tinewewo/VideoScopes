import Foundation

enum PixelFormat {
    case uyvy    // 8-bit 4:2:2  (BMD bmdFormat8BitYUV / '2vuy')
    case v210    // 10-bit 4:2:2 (BMD bmdFormat10BitYUV / 'v210')
}

struct VideoFrame {
    let width: Int
    let height: Int
    let rowBytes: Int
    let pixelFormat: PixelFormat
    let data: Data
    let matrix: Int   // 0 = 601, 1 = 709, 2 = 2020
    let range: Int    // 0 = narrow, 1 = full
}

protocol VideoSource: AnyObject {
    var displayName: String { get }
    var onFrame: ((VideoFrame) -> Void)? { get set }
    var onFormat: ((String) -> Void)? { get set }
    func start()
    func stop()
}

// ---------------------------------------------------------------------------
// Synthetic source: animated 75% colour bars in UYVY, so the scopes work
// with no capture hardware. Colour-bar targets land exactly on the
// vectorscope graticule boxes.
// ---------------------------------------------------------------------------

final class TestPatternSource: VideoSource {
    let displayName = "Test pattern (75% bars)"
    var onFrame: ((VideoFrame) -> Void)?
    var onFormat: ((String) -> Void)?

    private let width = 1280
    private let height = 720
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private let queue = DispatchQueue(label: "testpattern.gen")

    // 75% colour bars: white, yellow, cyan, green, magenta, red, blue, black
    private let bars: [(Double, Double, Double)] = [
        (0.75, 0.75, 0.75), (0.75, 0.75, 0.0), (0.0, 0.75, 0.75), (0.0, 0.75, 0.0),
        (0.75, 0.0, 0.75), (0.75, 0.0, 0.0), (0.0, 0.0, 0.75), (0.0, 0.0, 0.0)
    ]

    func start() {
        onFormat?("Test pattern · 1280×720 · UYVY · Rec.709")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        t.setEventHandler { [weak self] in self?.generate() }
        timer = t
        t.resume()
    }

    func stop() { timer?.cancel(); timer = nil }

    // Rec.709, 8-bit narrow-range Y'CbCr from linear-coded R'G'B' values.
    private func ycbcr8(_ r: Double, _ g: Double, _ b: Double) -> (UInt8, UInt8, UInt8) {
        let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - y) / 1.8556
        let cr = (r - y) / 1.5748
        let yc = Int((16.0 + 219.0 * y).rounded())
        let cbc = Int((128.0 + 224.0 * cb).rounded())
        let crc = Int((128.0 + 224.0 * cr).rounded())
        func clamp(_ v: Int) -> UInt8 { UInt8(min(255, max(0, v))) }
        return (clamp(yc), clamp(cbc), clamp(crc))
    }

    private func generate() {
        let rowBytes = width * 2
        var buf = [UInt8](repeating: 0, count: rowBytes * height)

        // precompute per-column Y/Cb/Cr for the bars, with a scrolling offset
        let offset = (frameIndex * 2) % width
        var colY = [UInt8](repeating: 16, count: width)
        var colCb = [UInt8](repeating: 128, count: width)
        var colCr = [UInt8](repeating: 128, count: width)
        let barW = width / bars.count
        let markerX = (frameIndex * 6) % width   // moving bright marker

        for x in 0..<width {
            let sx = (x + offset) % width
            var idx = sx / barW
            if idx >= bars.count { idx = bars.count - 1 }
            var (r, g, b) = bars[idx]
            if abs(x - markerX) < 3 { r = 1.0; g = 1.0; b = 1.0 }   // animated white pip
            let (y, cb, cr) = ycbcr8(r, g, b)
            colY[x] = y; colCb[x] = cb; colCr[x] = cr
        }

        buf.withUnsafeMutableBufferPointer { dst in
            for row in 0..<height {
                let base = row * rowBytes
                var x = 0
                while x < width {
                    // UYVY: Cb, Y0, Cr, Y1  (chroma shared from the left pixel)
                    dst[base + x * 2 + 0] = colCb[x]
                    dst[base + x * 2 + 1] = colY[x]
                    dst[base + x * 2 + 2] = colCr[x]
                    dst[base + x * 2 + 3] = (x + 1 < width) ? colY[x + 1] : colY[x]
                    x += 2
                }
            }
        }

        frameIndex += 1
        let frame = VideoFrame(width: width, height: height, rowBytes: rowBytes,
                               pixelFormat: .uyvy, data: Data(buf), matrix: 1, range: 0)
        onFrame?(frame)
    }
}
