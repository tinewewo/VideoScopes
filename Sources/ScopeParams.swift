import Foundation

// Mirrors `struct ScopeParams` in Shaders.metal — identical field order, all 32-bit.
struct ScopeParams {
    var srcW: UInt32 = 0
    var srcH: UInt32 = 0
    var srcRowBytes: UInt32 = 0
    var dstW: UInt32 = 0
    var dstH: UInt32 = 0
    var matrix: UInt32 = 1     // 0 = 601, 1 = 709, 2 = 2020
    var range: UInt32 = 0      // 0 = narrow, 1 = full
    var mode: UInt32 = 0
    var gain: Float = 0.1
    var vgain: Float = 1     // vectorscope radial magnification (×1 / ×2 / ×5)
}

enum ScopeKind: Int, CaseIterable {
    case waveform, parade, vectorscope, histogram, diamond, arrowhead

    var title: String {
        switch self {
        case .waveform:    return "Waveform (luma)"
        case .parade:      return "RGB parade"
        case .vectorscope: return "Vectorscope"
        case .histogram:   return "Histogram"
        case .diamond:     return "Diamond (RGB gamut)"
        case .arrowhead:   return "Arrowhead (composite)"
        }
    }

    // scope-specific mode passed to the shaders
    var mode: UInt32 {
        switch self {
        case .parade: return 4
        default:      return 0
        }
    }

    // keep the scope's intended aspect (letterbox) instead of stretching to fill —
    // matters in full screen, where window aspect constraints don't apply
    var preservesAspect: Bool {
        switch self {
        case .vectorscope, .diamond: return true
        default:                     return false
        }
    }

    // internal render resolution of the scope (scaled to the window on blit)
    var internalSize: (w: Int, h: Int) {
        switch self {
        case .waveform:    return (512, 512)
        case .parade:      return (768, 512)
        case .vectorscope: return (512, 512)
        case .histogram:   return (512, 300)
        case .diamond:     return (480, 600)
        case .arrowhead:   return (560, 420)
        }
    }

    // number of uint accumulation slots
    var accumCount: Int {
        switch self {
        case .histogram: return 256 * 3
        default:         let s = internalSize; return s.w * s.h
        }
    }

    func gain(srcW: Int, srcH: Int) -> Float {
        switch self {
        case .waveform, .parade:     return 0.10
        case .vectorscope:           return 0.14
        case .diamond, .arrowhead:   return 0.11
        case .histogram:             return 16.0 / Float(max(1, srcW * srcH))
        }
    }

    // default on-screen window frame (origin set when placed)
    var defaultWindowSize: (w: CGFloat, h: CGFloat) {
        switch self {
        case .waveform:    return (480, 360)
        case .parade:      return (560, 360)
        case .vectorscope: return (400, 400)
        case .histogram:   return (480, 300)
        case .diamond:     return (360, 460)
        case .arrowhead:   return (480, 340)
        }
    }
}
