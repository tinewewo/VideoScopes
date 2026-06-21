#include <metal_stdlib>
using namespace metal;

// Shared parameter block. The Swift struct ScopeParams must match this layout
// field-for-field (all 32-bit: uint / float).
struct ScopeParams {
    uint  srcW;
    uint  srcH;
    uint  srcRowBytes;
    uint  dstW;
    uint  dstH;
    uint  matrix;   // 0 = Rec.601, 1 = Rec.709, 2 = Rec.2020
    uint  range;    // 0 = narrow (video), 1 = full (data)
    uint  mode;     // scope-specific: waveform 0=luma 1=R 2=G 3=B 4=parade
    float gain;     // trace brightness scale
    float vgain;    // vectorscope radial magnification (×1 / ×2 / ×5)
};

// Luma coefficients (Kr, Kb) for the selected matrix. Kg = 1 - Kr - Kb.
static inline float2 luma_coeffs(uint matrix) {
    if (matrix == 0) return float2(0.299, 0.114);    // Rec.601
    if (matrix == 2) return float2(0.2627, 0.0593);  // Rec.2020
    return float2(0.2126, 0.0722);                    // Rec.709 (default)
}

// Y'CbCr (Cb,Cr centered, range -0.5..0.5) -> R'G'B'
static inline float3 ycbcr_to_rgb(float Y, float Cb, float Cr, uint matrix) {
    float2 k = luma_coeffs(matrix);
    float Kr = k.x, Kb = k.y, Kg = 1.0 - Kr - Kb;
    float R = Y + 2.0 * (1.0 - Kr) * Cr;
    float B = Y + 2.0 * (1.0 - Kb) * Cb;
    float G = (Y - Kr * R - Kb * B) / Kg;
    return float3(R, G, B);
}

// R'G'B' -> Y'CbCr (Cb,Cr centered, range -0.5..0.5)
static inline void rgb_to_ycbcr(float3 rgb, uint matrix,
                                thread float &Y, thread float &Cb, thread float &Cr) {
    float2 k = luma_coeffs(matrix);
    float Kr = k.x, Kb = k.y, Kg = 1.0 - Kr - Kb;
    Y  = Kr * rgb.r + Kg * rgb.g + Kb * rgb.b;
    Cb = (rgb.b - Y) / (2.0 * (1.0 - Kb));
    Cr = (rgb.r - Y) / (2.0 * (1.0 - Kr));
}

// ---------------------------------------------------------------------------
// Pixel unpack + colour conversion. Output texture stores R'G'B' in .rgb and
// luma Y' in .a, all video-coded and normalised to ~0..1 (may exceed for
// out-of-gamut content, which the scopes deliberately preserve).
// ---------------------------------------------------------------------------

kernel void convert_uyvy(device const uchar      *src    [[buffer(0)]],
                         constant ScopeParams     &p      [[buffer(1)]],
                         texture2d<float, access::write> dst [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    uint base = gid.y * p.srcRowBytes + (gid.x >> 1) * 4u;  // UYVY: 2 px per 4 bytes
    float Cbv = (float)src[base + 0];
    float Y0  = (float)src[base + 1];
    float Crv = (float)src[base + 2];
    float Y1  = (float)src[base + 3];
    float Yv  = ((gid.x & 1u) == 0u) ? Y0 : Y1;

    float Yn, Cbn, Crn;
    if (p.range == 1u) {            // full range
        Yn  = Yv / 255.0;
        Cbn = (Cbv - 128.0) / 255.0;
        Crn = (Crv - 128.0) / 255.0;
    } else {                        // narrow (video) range
        Yn  = (Yv - 16.0) / 219.0;
        Cbn = (Cbv - 128.0) / 224.0;
        Crn = (Crv - 128.0) / 224.0;
    }
    float3 rgb = ycbcr_to_rgb(Yn, Cbn, Crn, p.matrix);
    dst.write(float4(rgb, Yn), gid);
}

kernel void convert_v210(device const uint        *src    [[buffer(0)]],
                         constant ScopeParams      &p      [[buffer(1)]],
                         texture2d<float, access::write> dst [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    uint wordsPerRow = p.srcRowBytes / 4u;
    uint rowBase = gid.y * wordsPerRow;
    uint group   = gid.x / 6u;          // 6 pixels per 4 words
    uint local   = gid.x % 6u;
    uint w0 = src[rowBase + group * 4u + 0u];
    uint w1 = src[rowBase + group * 4u + 1u];
    uint w2 = src[rowBase + group * 4u + 2u];
    uint w3 = src[rowBase + group * 4u + 3u];

    // luma per local index
    float Yv;
    switch (local) {
        case 0: Yv = (float)((w0 >> 10) & 0x3ff); break;
        case 1: Yv = (float)( w1        & 0x3ff); break;
        case 2: Yv = (float)((w1 >> 20) & 0x3ff); break;
        case 3: Yv = (float)((w2 >> 10) & 0x3ff); break;
        case 4: Yv = (float)( w3        & 0x3ff); break;
        default:Yv = (float)((w3 >> 20) & 0x3ff); break;
    }
    // chroma per pixel pair
    float Cbv, Crv;
    if (local < 2u)      { Cbv = (float)( w0        & 0x3ff); Crv = (float)((w0 >> 20) & 0x3ff); }
    else if (local < 4u) { Cbv = (float)((w1 >> 10) & 0x3ff); Crv = (float)( w2        & 0x3ff); }
    else                 { Cbv = (float)((w2 >> 20) & 0x3ff); Crv = (float)((w3 >> 10) & 0x3ff); }

    float Yn, Cbn, Crn;
    if (p.range == 1u) {            // full range, 10-bit
        Yn  = Yv / 1023.0;
        Cbn = (Cbv - 512.0) / 1023.0;
        Crn = (Crv - 512.0) / 1023.0;
    } else {                        // narrow range, 10-bit
        Yn  = (Yv - 64.0) / 876.0;
        Cbn = (Cbv - 512.0) / 896.0;
        Crn = (Crv - 512.0) / 896.0;
    }
    float3 rgb = ycbcr_to_rgb(Yn, Cbn, Crn, p.matrix);
    dst.write(float4(rgb, Yn), gid);
}

// ---------------------------------------------------------------------------
// Scatter passes: accumulate pixel density into a uint buffer (atomic add).
// ---------------------------------------------------------------------------

kernel void scatter_waveform(texture2d<float, access::read> srcTex [[texture(0)]],
                             constant ScopeParams           &p      [[buffer(0)]],
                             device atomic_uint             *accum  [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    float4 s = srcTex.read(gid);

    if (p.mode == 4u) {                       // RGB parade: three side-by-side panels
        uint subW = p.dstW / 3u;
        float3 ch = s.rgb;
        for (uint c = 0u; c < 3u; ++c) {
            float v = clamp(ch[c], 0.0, 1.0);
            uint bx = c * subW + (gid.x * subW) / p.srcW;
            uint by = (uint)((1.0 - v) * (float)(p.dstH - 1u));
            if (bx < p.dstW && by < p.dstH)
                atomic_fetch_add_explicit(&accum[by * p.dstW + bx], 1u, memory_order_relaxed);
        }
        return;
    }

    float v;
    if      (p.mode == 1u) v = s.r;
    else if (p.mode == 2u) v = s.g;
    else if (p.mode == 3u) v = s.b;
    else                   v = s.a;           // luma
    v = clamp(v, 0.0, 1.0);
    uint bx = (gid.x * p.dstW) / p.srcW;
    uint by = (uint)((1.0 - v) * (float)(p.dstH - 1u));
    if (bx < p.dstW && by < p.dstH)
        atomic_fetch_add_explicit(&accum[by * p.dstW + bx], 1u, memory_order_relaxed);
}

kernel void scatter_vector(texture2d<float, access::read> srcTex [[texture(0)]],
                           constant ScopeParams           &p      [[buffer(0)]],
                           device atomic_uint             *accum  [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    float4 s = srcTex.read(gid);
    float Y, Cb, Cr;
    rgb_to_ycbcr(s.rgb, p.matrix, Y, Cb, Cr);
    float g = (p.vgain > 0.0) ? p.vgain : 1.0;   // radial magnification (graticule stays)
    float S = (float)p.dstW * 0.8;
    float cx = (float)p.dstW * 0.5;
    float cy = (float)p.dstH * 0.5;
    int px = (int)(cx + Cb * g * S);
    int py = (int)(cy - Cr * g * S);          // Cr up
    if (px >= 0 && py >= 0 && px < (int)p.dstW && py < (int)p.dstH)
        atomic_fetch_add_explicit(&accum[(uint)py * p.dstW + (uint)px], 1u, memory_order_relaxed);
}

kernel void scatter_hist(texture2d<float, access::read> srcTex [[texture(0)]],
                         constant ScopeParams           &p      [[buffer(0)]],
                         device atomic_uint             *accum  [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    float3 rgb = srcTex.read(gid).rgb;
    for (uint c = 0u; c < 3u; ++c) {
        uint bin = (uint)clamp(rgb[c] * 255.0, 0.0, 255.0);
        atomic_fetch_add_explicit(&accum[c * 256u + bin], 1u, memory_order_relaxed);
    }
}

// ---------------------------------------------------------------------------
// Resolve passes: read accumulation buffer, draw trace + procedural graticule.
// ---------------------------------------------------------------------------

static inline bool near_line(float a, float target, float tol) {
    return fabs(a - target) <= tol;
}

kernel void resolve_waveform(constant ScopeParams           &p      [[buffer(0)]],
                             device const uint              *accum  [[buffer(1)]],
                             texture2d<float, access::write> outTex [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.dstW || gid.y >= p.dstH) return;
    float3 col = float3(0.05);
    float fy = (float)gid.y / (float)(p.dstH - 1u);

    // horizontal level lines at 0/25/50/75/100 %
    float3 grat = float3(0.20, 0.24, 0.26);
    float tol = 0.6 / (float)p.dstH;
    if (near_line(fy, 0.0, tol) || near_line(fy, 0.25, tol) ||
        near_line(fy, 0.5, tol) || near_line(fy, 0.75, tol) || near_line(fy, 1.0, tol))
        col = grat;

    if (p.mode == 4u) {  // parade: vertical dividers at thirds
        float fx = (float)gid.x / (float)(p.dstW - 1u);
        if (near_line(fx, 1.0/3.0, 0.6/(float)p.dstW) ||
            near_line(fx, 2.0/3.0, 0.6/(float)p.dstW))
            col = grat;
    }

    uint c = accum[gid.y * p.dstW + gid.x];
    if (c > 0u) {
        float inten = saturate(log2(1.0 + (float)c) * p.gain);
        float3 trace = (p.mode == 1u) ? float3(1.0, 0.3, 0.3) :
                       (p.mode == 2u) ? float3(0.3, 1.0, 0.4) :
                       (p.mode == 3u) ? float3(0.4, 0.6, 1.0) :
                                        float3(0.5, 1.0, 0.6);
        col = max(col, trace * inten);
    }
    outTex.write(float4(col, 1.0), gid);
}

// six 75% colour-bar targets, precomputed positions done on the fly
kernel void resolve_vector(constant ScopeParams           &p      [[buffer(0)]],
                           device const uint              *accum  [[buffer(1)]],
                           texture2d<float, access::write> outTex [[texture(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.dstW || gid.y >= p.dstH) return;
    float3 col = float3(0.05);
    float S  = (float)p.dstW * 0.8;
    float cx = (float)p.dstW * 0.5;
    float cy = (float)p.dstH * 0.5;
    float dx = (float)gid.x - cx;
    float dy = (float)gid.y - cy;
    float r  = sqrt(dx * dx + dy * dy);
    float3 grat = float3(0.20, 0.24, 0.26);

    // reference circle near 100% primaries and a center cross
    if (fabs(r - 0.42 * (float)p.dstW) < 0.7) col = grat;
    if (fabs(dx) < 0.7 || fabs(dy) < 0.7)     col = grat * 0.8;

    // 75% bar targets: Yl, Cy, Gn, Mg, Rd, Bl
    const float3 bars[6] = {
        float3(0.75,0.75,0.0), float3(0.0,0.75,0.75), float3(0.0,0.75,0.0),
        float3(0.75,0.0,0.75), float3(0.75,0.0,0.0),  float3(0.0,0.0,0.75)
    };
    for (uint i = 0u; i < 6u; ++i) {
        float Y, Cb, Cr;
        rgb_to_ycbcr(bars[i], p.matrix, Y, Cb, Cr);
        float tx = cx + Cb * S;
        float ty = cy - Cr * S;
        float bdx = fabs((float)gid.x - tx);
        float bdy = fabs((float)gid.y - ty);
        float bs = 4.0;
        if (bdx < bs && bdy < bs && (bdx > bs - 1.4 || bdy > bs - 1.4))
            col = float3(0.55, 0.6, 0.62);
    }

    // intermediate hue targets at the angular midpoints between adjacent
    // primaries/secondaries (Rec.709). Order: R-Mg, R-Yl, Yl-G, G-Cy, Cy-B, B-Mg.
    const float2 inter[6] = {
        float2( 0.0985,  0.4040), float2(-0.2866,  0.2506), float2(-0.3812, -0.1555),
        float2(-0.0985, -0.4040), float2( 0.2866, -0.2506), float2( 0.3812,  0.1555)
    };
    for (uint i = 0u; i < 6u; ++i) {
        float tx = cx + inter[i].x * S;
        float ty = cy - inter[i].y * S;
        float bdx = fabs((float)gid.x - tx);
        float bdy = fabs((float)gid.y - ty);
        float bs = 3.0;
        if (bdx < bs && bdy < bs && (bdx > bs - 1.2 || bdy > bs - 1.2))
            col = max(col, float3(0.40, 0.44, 0.46));
    }

    // skin-tone (I) axis: a ray from the centre toward ~123° (11 o'clock,
    // between R and Yl), upper half only, dashed.
    float ia = 123.0 * 3.14159265 / 180.0;
    float2 idir = float2(cos(ia), -sin(ia));         // Cr up -> screen y down
    float2 rel  = float2((float)gid.x - cx, (float)gid.y - cy);
    float along = rel.x * idir.x + rel.y * idir.y;
    float perp  = fabs(rel.x * idir.y - rel.y * idir.x);
    if (perp < 0.7 && along > 0.0 && along < 0.42 * (float)p.dstW && fmod(along, 12.0) < 7.0)
        col = max(col, float3(0.30, 0.36, 0.32));

    // CDM12 skin-tone reference targets along the I-line (toggle: mode == 1)
    if (p.mode == 1u) {
        const float radii[4] = { 0.09, 0.15, 0.21, 0.27 };
        for (uint i = 0u; i < 4u; ++i) {
            float m = radii[i] * S;
            float bdx = fabs((float)gid.x - (cx + idir.x * m));
            float bdy = fabs((float)gid.y - (cy + idir.y * m));
            float bs = 3.5;
            if (bdx < bs && bdy < bs && (bdx > bs - 1.4 || bdy > bs - 1.4))
                col = max(col, float3(0.95, 0.62, 0.45));   // skin/peach tint
        }
    }

    uint c = accum[gid.y * p.dstW + gid.x];
    if (c > 0u) {
        float inten = saturate(log2(1.0 + (float)c) * p.gain);
        col = max(col, float3(0.5, 1.0, 0.6) * inten);
    }
    outTex.write(float4(col, 1.0), gid);
}

kernel void resolve_hist(constant ScopeParams           &p      [[buffer(0)]],
                         device const uint              *accum  [[buffer(1)]],
                         texture2d<float, access::write> outTex [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.dstW || gid.y >= p.dstH) return;
    float3 col = float3(0.05);
    float fy = (float)gid.y / (float)(p.dstH - 1u);
    if (near_line(fy, 0.5, 0.6/(float)p.dstH)) col = float3(0.18);

    uint bin = (gid.x * 256u) / p.dstW;
    float fromBottom = 1.0 - fy;
    const float3 chCol[3] = { float3(1.0,0.25,0.25), float3(0.25,1.0,0.3), float3(0.35,0.55,1.0) };
    for (uint c = 0u; c < 3u; ++c) {
        float h = saturate((float)accum[c * 256u + bin] * p.gain);
        if (fromBottom <= h) col += chCol[c] * 0.5;
    }
    outTex.write(float4(min(col, float3(1.0)), 1.0), gid);
}

// ---------------------------------------------------------------------------
// Diamond display (Tektronix): RGB gamut. Upper diamond from (B',G'),
// lower from (R',G'); black at the shared centre, white at each outer tip.
// A component < 0 or > 1 pushes the trace across a diamond edge.
// ---------------------------------------------------------------------------

kernel void scatter_diamond(texture2d<float, access::read> srcTex [[texture(0)]],
                            constant ScopeParams           &p      [[buffer(0)]],
                            device atomic_uint             *accum  [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    float3 c = srcTex.read(gid).rgb;
    float cx = (float)p.dstW * 0.5;
    float midY = (float)p.dstH * 0.5;
    float S = (float)p.dstH * 0.22;
    int ux = (int)(cx + (c.b - c.g) * S);
    int uy = (int)(midY - (c.b + c.g) * S);
    if (ux >= 0 && uy >= 0 && ux < (int)p.dstW && uy < (int)p.dstH)
        atomic_fetch_add_explicit(&accum[(uint)uy * p.dstW + (uint)ux], 1u, memory_order_relaxed);
    int lx = (int)(cx + (c.r - c.g) * S);
    int ly = (int)(midY + (c.r + c.g) * S);
    if (lx >= 0 && ly >= 0 && lx < (int)p.dstW && ly < (int)p.dstH)
        atomic_fetch_add_explicit(&accum[(uint)ly * p.dstW + (uint)lx], 1u, memory_order_relaxed);
}

kernel void resolve_diamond(constant ScopeParams           &p      [[buffer(0)]],
                            device const uint              *accum  [[buffer(1)]],
                            texture2d<float, access::write> outTex [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.dstW || gid.y >= p.dstH) return;
    float3 col = float3(0.05);
    float cx = (float)p.dstW * 0.5;
    float midY = (float)p.dstH * 0.5;
    float S = (float)p.dstH * 0.22;
    float3 grat = float3(0.24, 0.28, 0.30);
    float te = 1.0 / S;
    float fx = (float)gid.x, fy = (float)gid.y;

    float dx = (fx - cx) / S;
    if (fy <= midY + 1.0) {              // upper diamond (B,G)
        float dy = (midY - fy) / S;
        float B = (dy + dx) * 0.5, G = (dy - dx) * 0.5;
        bool onB = (fabs(B) < te || fabs(B - 1.0) < te) && G > -te && G < 1.0 + te;
        bool onG = (fabs(G) < te || fabs(G - 1.0) < te) && B > -te && B < 1.0 + te;
        if (onB || onG) col = grat;
    }
    if (fy >= midY - 1.0) {              // lower diamond (R,G)
        float dy = (fy - midY) / S;
        float R = (dy + dx) * 0.5, G = (dy - dx) * 0.5;
        bool onR = (fabs(R) < te || fabs(R - 1.0) < te) && G > -te && G < 1.0 + te;
        bool onG = (fabs(G) < te || fabs(G - 1.0) < te) && R > -te && R < 1.0 + te;
        if (onR || onG) col = grat;
    }
    if (fabs(fx - cx) < 0.7) col = max(col, grat * 0.5);   // monochrome axis

    uint cnt = accum[gid.y * p.dstW + gid.x];
    if (cnt > 0u) {
        float inten = saturate(log2(1.0 + (float)cnt) * p.gain);
        col = max(col, float3(0.5, 1.0, 0.6) * inten);
    }
    outTex.write(float4(col, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Arrowhead display (Tektronix): composite gamut. Luma on the vertical axis
// (blanking lower-left), chroma-subcarrier magnitude on the horizontal axis
// (zero at the left edge). Sloped lines = 100 % / 75 % composite limits.
// ---------------------------------------------------------------------------

static inline float seg_dist(float2 pt, float2 a, float2 b) {
    float2 ab = b - a, ap = pt - a;
    float t = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-5), 0.0, 1.0);
    return distance(pt, a + t * ab);
}

static inline float arrow_x(float cmag, float left, float right) {
    return left + clamp(cmag / 0.5, 0.0, 1.3) * (right - left);
}
static inline float arrow_y(float Y, float top, float bot) {
    return bot - clamp(Y, 0.0, 1.0) * (bot - top);
}

kernel void scatter_arrowhead(texture2d<float, access::read> srcTex [[texture(0)]],
                              constant ScopeParams           &p      [[buffer(0)]],
                              device atomic_uint             *accum  [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.srcW || gid.y >= p.srcH) return;
    float4 s = srcTex.read(gid);
    float yy, cb, cr;
    rgb_to_ycbcr(s.rgb, p.matrix, yy, cb, cr);
    float cmag = sqrt(cb * cb + cr * cr);
    float left = 0.12 * (float)p.dstW, right = 0.96 * (float)p.dstW;
    float top  = 0.06 * (float)p.dstH, bot   = 0.94 * (float)p.dstH;
    int xi = (int)arrow_x(cmag, left, right);
    int yi = (int)arrow_y(s.a, top, bot);
    if (xi >= 0 && yi >= 0 && xi < (int)p.dstW && yi < (int)p.dstH)
        atomic_fetch_add_explicit(&accum[(uint)yi * p.dstW + (uint)xi], 1u, memory_order_relaxed);
}

kernel void resolve_arrowhead(constant ScopeParams           &p      [[buffer(0)]],
                              device const uint              *accum  [[buffer(1)]],
                              texture2d<float, access::write> outTex [[texture(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= p.dstW || gid.y >= p.dstH) return;
    float3 col = float3(0.05);
    float left = 0.12 * (float)p.dstW, right = 0.96 * (float)p.dstW;
    float top  = 0.06 * (float)p.dstH, bot   = 0.94 * (float)p.dstH;
    float2 pt = float2((float)gid.x, (float)gid.y);
    float3 grat = float3(0.22, 0.26, 0.28);

    float tipY = bot - 0.55 * (bot - top);
    float2 A100 = float2(left, top), B100 = float2(left, bot);
    float2 T100 = float2(right, tipY);
    float2 T75  = float2(left + 0.75 * (right - left), tipY);

    if (fabs(pt.x - left) < 0.8 && pt.y >= top && pt.y <= bot) col = grat;   // luma axis
    if (seg_dist(pt, A100, T100) < 0.8) col = grat;                          // upper 100 %
    if (seg_dist(pt, B100, T100) < 0.8) col = grat;                          // lower 100 %
    if (seg_dist(pt, A100, T75)  < 0.7) col = max(col, grat * 0.7);          // upper 75 %
    if (seg_dist(pt, B100, T75)  < 0.7) col = max(col, grat * 0.7);          // lower 75 %

    // faint luma graticule at 0/50/100 %
    for (uint k = 0u; k <= 2u; ++k) {
        float yy = bot - (float)k * 0.5 * (bot - top);
        if (fabs(pt.y - yy) < 0.6 && pt.x >= left && pt.x <= right)
            col = max(col, grat * 0.5);
    }

    uint cnt = accum[gid.y * p.dstW + gid.x];
    if (cnt > 0u) {
        float inten = saturate(log2(1.0 + (float)cnt) * p.gain);
        col = max(col, float3(0.5, 1.0, 0.6) * inten);
    }
    outTex.write(float4(col, 1.0), gid);
}

// ---------------------------------------------------------------------------
// Blit: draw a scope output texture onto the view drawable (fullscreen tri).
// ---------------------------------------------------------------------------

struct VSOut { float4 pos [[position]]; float2 uv; };

vertex VSOut blit_vertex(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
    float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VSOut o;
    o.pos = float4(p[vid] * scale, 0.0, 1.0);   // scale<1 letterboxes to preserve aspect
    o.uv  = float2((p[vid].x + 1.0) * 0.5, 1.0 - (p[vid].y + 1.0) * 0.5);
    return o;
}

fragment float4 blit_fragment(VSOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return tex.sample(s, in.uv);
}
