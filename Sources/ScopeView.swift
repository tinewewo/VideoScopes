import Cocoa
import Metal
import MetalKit

final class ScopeRenderer: NSObject, MTKViewDelegate {
    let engine: MetalEngine
    let kind: ScopeKind
    private var accum: MTLBuffer
    private var outTex: MTLTexture
    private let iw: Int
    private let ih: Int

    init(engine: MetalEngine, kind: ScopeKind) {
        self.engine = engine
        self.kind = kind
        let s = kind.internalSize
        iw = s.w; ih = s.h
        accum = engine.device.makeBuffer(length: kind.accumCount * 4, options: .storageModePrivate)!
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: iw, height: ih, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        td.storageMode = .private
        outTex = engine.device.makeTexture(descriptor: td)!
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        // convert the newest frame first (this is what creates sourceTexture)
        engine.ensureConverted()

        // no signal yet: just clear the drawable
        guard engine.sourceTexture != nil else {
            guard let cmd = engine.queue.makeCommandBuffer(),
                  let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.endEncoding()
            cmd.present(drawable)
            cmd.commit()
            return
        }

        guard let cmd = engine.queue.makeCommandBuffer() else { return }

        // 1. clear accumulation buffer
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.fill(buffer: accum, range: 0..<accum.length, value: 0)
            blit.endEncoding()
        }

        let mode: UInt32 = (kind == .vectorscope && engine.showSkinTargets) ? 1 : kind.mode
        var p = engine.makeParams(dstW: iw, dstH: ih, mode: mode,
                                  gain: kind.gain(srcW: engine.srcW, srcH: engine.srcH))
        let (scatterPS, resolvePS) = engine.pipelines(for: kind)

        // 2. scatter source pixels into the accumulation buffer
        if let c1 = cmd.makeComputeCommandEncoder() {
            c1.setComputePipelineState(scatterPS)
            c1.setTexture(engine.sourceTexture, index: 0)
            c1.setBytes(&p, length: MemoryLayout<ScopeParams>.stride, index: 0)
            c1.setBuffer(accum, offset: 0, index: 1)
            engine.dispatch(c1, w: engine.srcW, h: engine.srcH)
            c1.endEncoding()
        }

        // 3. resolve into the scope output texture (trace + graticule)
        if let c2 = cmd.makeComputeCommandEncoder() {
            c2.setComputePipelineState(resolvePS)
            c2.setBytes(&p, length: MemoryLayout<ScopeParams>.stride, index: 0)
            c2.setBuffer(accum, offset: 0, index: 1)
            c2.setTexture(outTex, index: 0)
            engine.dispatch(c2, w: iw, h: ih)
            c2.endEncoding()
        }

        // 4. blit the scope output onto the view drawable (scaled to fit)
        rpd.colorAttachments[0].loadAction = .clear
        if let r = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            r.setRenderPipelineState(engine.psBlit)
            r.setFragmentTexture(outTex, index: 0)
            r.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            r.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()
    }
}

final class ScopeView: MTKView {
    private let renderer: ScopeRenderer

    init(kind: ScopeKind) {
        let engine = MetalEngine.shared
        renderer = ScopeRenderer(engine: engine, kind: kind)
        super.init(frame: .zero, device: engine.device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1)
        framebufferOnly = true
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        delegate = renderer
    }

    required init(coder: NSCoder) { fatalError() }
}
