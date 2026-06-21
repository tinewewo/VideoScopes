import Metal
import MetalKit
import Foundation

final class MetalEngine {
    static let shared = MetalEngine()

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let lib: MTLLibrary

    let psConvertUYVY: MTLComputePipelineState
    let psConvertV210: MTLComputePipelineState
    let psScatterWaveform: MTLComputePipelineState
    let psScatterVector: MTLComputePipelineState
    let psScatterHist: MTLComputePipelineState
    let psResolveWaveform: MTLComputePipelineState
    let psResolveVector: MTLComputePipelineState
    let psResolveHist: MTLComputePipelineState
    let psScatterDiamond: MTLComputePipelineState
    let psResolveDiamond: MTLComputePipelineState
    let psScatterArrowhead: MTLComputePipelineState
    let psResolveArrowhead: MTLComputePipelineState
    let psBlit: MTLRenderPipelineState

    // shared source frame (R'G'B' in rgb, luma in a)
    private(set) var sourceTexture: MTLTexture?
    private(set) var srcW = 0
    private(set) var srcH = 0
    private var srcRowBytes = 0
    private var matrix: UInt32 = 1
    private var range: UInt32 = 0
    private var srcFormat: PixelFormat = .uyvy
    var vectorGain: Float = 1.0     // vectorscope magnification, set from the UI (main thread)

    // triple-buffered upload to avoid CPU/GPU overwrite races
    private var srcBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var srcBufferLen = 0
    private var convertSlot = 0                               // true per-convert round-robin
    private let frameSemaphore = DispatchSemaphore(value: 3)  // ≤3 uploads in flight

    private let lock = NSLock()
    private var pendingFrame: VideoFrame?
    private var frameCounter: UInt64 = 0
    private var convertedCounter: UInt64 = 0

    private init() {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            fatalError("No Metal device available")
        }
        device = dev
        queue = dev.makeCommandQueue()!

        // load shader source from the app bundle and compile at runtime
        guard let path = Bundle.main.path(forResource: "Shaders", ofType: "metal"),
              let src = try? String(contentsOfFile: path, encoding: .utf8) else {
            fatalError("Shaders.metal not found in bundle")
        }
        let library: MTLLibrary
        do {
            library = try dev.makeLibrary(source: src, options: nil)
        } catch {
            fatalError("Shader compile failed: \(error)")
        }

        func cps(_ name: String) -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else { fatalError("missing fn \(name)") }
            return try! dev.makeComputePipelineState(function: fn)
        }
        psConvertUYVY     = cps("convert_uyvy")
        psConvertV210     = cps("convert_v210")
        psScatterWaveform = cps("scatter_waveform")
        psScatterVector   = cps("scatter_vector")
        psScatterHist     = cps("scatter_hist")
        psResolveWaveform = cps("resolve_waveform")
        psResolveVector   = cps("resolve_vector")
        psResolveHist     = cps("resolve_hist")
        psScatterDiamond  = cps("scatter_diamond")
        psResolveDiamond  = cps("resolve_diamond")
        psScatterArrowhead = cps("scatter_arrowhead")
        psResolveArrowhead = cps("resolve_arrowhead")

        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = library.makeFunction(name: "blit_vertex")
        rpd.fragmentFunction = library.makeFunction(name: "blit_fragment")
        rpd.colorAttachments[0].pixelFormat = .bgra8Unorm
        psBlit = try! dev.makeRenderPipelineState(descriptor: rpd)

        lib = library
    }

    func submit(_ frame: VideoFrame) {
        lock.lock()
        pendingFrame = frame
        frameCounter &+= 1
        lock.unlock()
    }

    func pipelines(for kind: ScopeKind) -> (scatter: MTLComputePipelineState, resolve: MTLComputePipelineState) {
        switch kind {
        case .waveform, .parade: return (psScatterWaveform, psResolveWaveform)
        case .vectorscope:       return (psScatterVector, psResolveVector)
        case .histogram:         return (psScatterHist, psResolveHist)
        case .diamond:           return (psScatterDiamond, psResolveDiamond)
        case .arrowhead:         return (psScatterArrowhead, psResolveArrowhead)
        }
    }

    func makeParams(dstW: Int, dstH: Int, mode: UInt32, gain: Float) -> ScopeParams {
        var p = ScopeParams()
        p.srcW = UInt32(srcW); p.srcH = UInt32(srcH); p.srcRowBytes = UInt32(srcRowBytes)
        p.dstW = UInt32(dstW); p.dstH = UInt32(dstH)
        p.matrix = matrix; p.range = range; p.mode = mode; p.gain = gain
        p.vgain = vectorGain
        return p
    }

    // Called on the main thread before scope rendering. Converts the newest
    // frame into the shared source texture exactly once per frame.
    func ensureConverted() {
        lock.lock()
        guard frameCounter != convertedCounter, let f = pendingFrame else { lock.unlock(); return }
        convertedCounter = frameCounter
        lock.unlock()

        // slot must round-robin 0,1,2 by actual conversions — never derive it from
        // the source frame number, which jumps by the number of dropped frames
        let slot = convertSlot % 3
        convertSlot += 1

        srcW = f.width; srcH = f.height; srcRowBytes = f.rowBytes
        matrix = 1                      // fixed Rec.709 (no 601 / 2020)
        range = UInt32(f.range); srcFormat = f.pixelFormat

        // (re)create the upload buffer for this slot
        if srcBuffers[slot] == nil || srcBuffers[slot]!.length < f.data.count {
            srcBuffers[slot] = device.makeBuffer(length: max(f.data.count, 1), options: .storageModeShared)
        }
        let buf = srcBuffers[slot]!
        // block until this slot's previous GPU read has finished before overwriting it
        frameSemaphore.wait()
        f.data.copyBytes(to: buf.contents().assumingMemoryBound(to: UInt8.self), count: f.data.count)

        // (re)create the source texture if size changed
        if sourceTexture == nil || sourceTexture!.width != srcW || sourceTexture!.height != srcH {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: srcW, height: srcH, mipmapped: false)
            td.usage = [.shaderRead, .shaderWrite]
            td.storageMode = .private
            sourceTexture = device.makeTexture(descriptor: td)
        }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { frameSemaphore.signal(); return }
        enc.setComputePipelineState(srcFormat == .v210 ? psConvertV210 : psConvertUYVY)
        enc.setBuffer(buf, offset: 0, index: 0)
        var p = makeParams(dstW: 0, dstH: 0, mode: 0, gain: 0)
        enc.setBytes(&p, length: MemoryLayout<ScopeParams>.stride, index: 1)
        enc.setTexture(sourceTexture, index: 0)
        dispatch(enc, w: srcW, h: srcH)
        enc.endEncoding()
        cmd.addCompletedHandler { [frameSemaphore] _ in frameSemaphore.signal() }
        cmd.commit()
    }

    func dispatch(_ enc: MTLComputeCommandEncoder, w: Int, h: Int) {
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: w, height: h, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
    }
}
