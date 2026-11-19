// Present-path probe: 420v CVPixelBuffer -> CVMetalTextureCache -> BT.709 shader -> MetalFX spatial 1920x1080 -> 3456x1944
// -> CAMetalLayer drawable via CAMetalDisplayLink (--mode link) or via CADisplayLink + layer.nextDrawable() (--mode vsync), with HUD.
// Prints pacing statistics from MTLDrawable.presentedTime.
// Build: xcrun swiftc -O -swift-version 5 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 probes/present_probe.swift -o probes/present_probe
// Run:   probes/present_probe --seconds 10 [--link-hz 60] [--present-every 1] [--latency 2] [--drawables 2] [--hud 1] [--auto-parity 1] [--scaler 1] [--drawable WxH] [--warmup 2] [--expect-ms N]
//          [--runloop thread|main] [--window small|full] [--video <file> --start <s>] [--mode link|next|vsync] [--min-duration s] [--at-time 0]
//          [--source index|counter] [--display-mode keep|native120|native5994] [--slots-csv <path>]
//          [--present plain|at-slot] [--render-delay-ms D] [--colorspace srgb|p3|none]
//   --source index    (default) content frame = floor((target - t0) * 60): the old 60.000 Hz index. Uses --present-every and the parity lock.
//   --source counter  gate G1 (PLAN.md 4, 5.2): positions i = 0,1,2.. at c_i = t0 + i*1001/60000 s (t0 = targetPresentationTimestamp of the first callback),
//                     each reserved a slot by the PLAN.md 5.2 rule (base 0, N 0, eps 1.5 ms, step = round(H/S): 2 at 120 Hz, 1 at 59.94 Hz) on the measured
//                     slot grid; a callback draws the position reserved for its slot (picture = frame id % frameCount, bar at x = id % 240 steps), else
//                     presents nothing ("held"). Ignores --present-every and the parity lock. Needs --mode link or vsync. Prints the G1 report and ends with a "G1 RESULT:" line.
//                     Latency lines exclude the first --warmup (2.0) s after the first present, like the content intervals.
//   --mode vsync      (needs --source counter) no CAMetalDisplayLink. A CADisplayLink from the chosen NSScreen (displayLink(target:selector:)), range = --link-hz, is added
//                     to the run loop chosen by --runloop thread|main in .common mode. One tick = one slot; slot time = the link's targetTimestamp (next vsync); the slot index
//                     advances by max(1, round(gap / S)) per tick and S / the grid are fitted as in link mode (median of the last 120 target differences); the same Pacer reserves.
//                     Per tick: (a) wait until tick entry + --render-delay-ms (mach_wait_until); (b) record the pick time and take the reserved position, none = "held" and return;
//                     (c) layer.nextDrawable() (allowsNextDrawableTimeout = true, nil = "skipped"), its blocking time is recorded; (d) encode the link-mode pipeline;
//                     (e) --present plain = commandBuffer.present(drawable), at-slot = commandBuffer.present(drawable, atTime: slot time); (f) commit.
//                     In this mode the CSV column callback_time (and "callback" in the latency lines) is the PICK time, after the delay. target_time = the slot time (targetTimestamp).
//                     present(_:atTime:) is allowed only here: it raises CAMetalDrawableInvalidOperation with a CAMetalDisplayLink drawable (--mode link).
//   --present         plain (default) | at-slot; only --mode vsync. G1 RESULT prints present=n/a in other modes.
//   --render-delay-ms D  (default 0) only --mode vsync, see (a). At most one slot minus 1.5 ms.
//   --drain-ms X      (default 0 = off) only --mode vsync: when nextDrawable() blocks longer than X ms, this tick's drawable is returned unpresented (outcome "skipped")
//                     so a queued frame drains; at most once per second. Counted as drains= in the housekeeping and G1 RESULT lines.
//   --colorspace      srgb (default) | p3 (Display P3) | none (layer.colorspace = nil). Every mode; printed in the config: line.
//   --display-mode    keep (default) leaves the display alone. native120 / native5994 switch the built-in display to its 3456x2234 mode at 120 / 59.94 Hz
//                     for this process only (CGCompleteDisplayConfiguration .forAppOnly) and print the mode read back; on failure "DISPLAY MODE NOT APPLIED: <reason>".
//                     (list = print the built-in display's 3456x2234 modes and exit; changes nothing.)
//   --slots-csv path  (needs --source counter) one row per display-link callback: slot,target_time,callback_time,outcome,content_id,gpu_start,gpu_end,presented_time
//                     outcome = shown | held | skipped (the position's draw failed). Buffered, written at exit.
//   --mode next       no display link, free-running nextDrawable() loop; prints "DIAGNOSTIC ONLY: no slot grid"; latency timer starts before nextDrawable() is called. Cannot be combined with --source counter.
//   --pacer-selftest  (hidden) runs the slot rule on synthetic grids for 10 simulated minutes and prints results to compare with `python3 probes/pacer_sim.py`.
// Keys (window=full only): h = HUD on/off, q or esc = quit. No capture device is opened.
import AppKit
import Metal
import MetalFX
import QuartzCore
import CoreVideo
import CoreText
import AVFoundation
import Accelerate
import Synchronization

func arg(_ k: String, _ d: String) -> String {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: "--" + k), i + 1 < a.count { return a[i + 1] }
    return d
}
func die(_ s: String) -> Never { print("FATAL: \(s)"); exit(1) }

let seconds = Double(arg("seconds", "8"))!
let linkHz = Float(arg("link-hz", "60"))!
let presentEvery = Int(arg("present-every", "1"))!
let latencyArg = Float(arg("latency", "-1"))!
let drawablesArg = Int(arg("drawables", "2"))!
let atTime = arg("at-time", "0") == "1"
let fullWindow = arg("window", "small") == "full"
let videoPath = arg("video", "")
let useScaler = arg("scaler", "1") == "1"            // 0 = skip MetalFX, blit the 1080p texture (cost comparison only)
let modeArg = arg("mode", "link")
let nextMode = modeArg == "next"                     // next = no display link: a thread loops on layer.nextDrawable()
let vsyncMode = modeArg == "vsync"                   // vsync = CADisplayLink clock + nextDrawable() per tick (no CAMetalDisplayLink)
let presentArg = arg("present", "plain")
let atSlot = vsyncMode && presentArg == "at-slot"
let renderDelayMs = Double(arg("render-delay-ms", "0")) ?? -1
let colorspaceArg = arg("colorspace", "srgb")
let drainMs = Double(arg("drain-ms", "0")) ?? 0          // --mode vsync: see the drain comment in counterCallback. 0 = off
let minDuration = Double(arg("min-duration", "0"))!   // present(afterMinimumDuration:) in seconds, 0 = plain present
let autoParity = arg("auto-parity", "1") == "1"
let drawableArg = arg("drawable", "")                 // WxH in pixels; default = screen backing size
let inW = 1920, inH = 1080, outW = 3456, outH = 1944
let sourceArg = arg("source", "index")
let displayModeArg = arg("display-mode", "keep")
let slotsCSV = arg("slots-csv", "")
let counterMode = sourceArg == "counter"
let contentH = 1001.0 / 60000.0                       // s between content positions (59.94 Hz)

// ---------- slot reservation (PLAN.md 5.2): port of run() in probes/pacer_sim.py. Pure logic, units are the caller's (ms in the self-test, s live) ----------
struct SlotGrid {
    var idx = 0, t = 0.0, S = 1.0     // latest observed slot: callback counter, its targetPresentationTimestamp; S = period
    func slotTime(_ k: Int) -> Double { t + Double(k - idx) * S }
    func ceilSlot(_ g: Double) -> Int { idx + Int(((g - t) / S).rounded(.up)) }
}
struct Pacer {
    var hasLast = false, last = 0, skipNextMid = false
    var corrections = 0, collision = 0, pushedLate = 0, catchUpSkip = 0
    /// Position i (even = real, odd = midpoint) with earliest glass time g. Returns its slot, or nil when the position is dropped.
    mutating func reserve(i: Int, g: Double, grid: SlotGrid, step: Int, eps: Double, nextPickable: Int) -> Int? {
        let real = i % 2 == 0
        if !real && skipNextMid { skipNextMid = false; catchUpSkip += 1; return nil }
        var k: Int
        if !hasLast {
            k = max(grid.ceilSlot(g), nextPickable)
        } else {
            k = last + step
            let t = grid.slotTime(k)
            if !(g <= t && t < g + grid.S + 2 * eps) {
                k = grid.ceilSlot(g); corrections += 1
                if k <= last {                                   // a reservation never moves
                    if !real { collision += 1; return nil }      // midpoint dropped, previous real frame held
                    k = last + 1; pushedLate += 1; skipNextMid = true
                }
            }
        }
        last = k; hasLast = true
        return k
    }
}
func pacerSelftest() -> Never {
    let H = 1001.0 / 60.0, eps = 1.5                 // ms
    func runCase(S: Double, step: Int, phase: Double, jitter: Double) -> String {
        let n = Int(10.0 * 60000.0 / H)
        var p = Pacer(), early = 0, positions = 0, shared = 0
        var seen = Set<Int>(), hash: UInt64 = 0xcbf29ce484222325, count = 0
        let grid = SlotGrid(idx: 0, t: 0, S: S)
        for i in 0..<n {
            let j = i % 2 == 1 ? jitter : -jitter
            let g = phase + Double(i) * H + j
            positions += 1
            guard let k = p.reserve(i: i, g: g, grid: grid, step: step, eps: eps, nextPickable: Int.min) else { continue }
            if grid.slotTime(k) < g - 1e-9 { early += 1 }
            if !seen.insert(k).inserted { shared += 1 }
            hash = (hash ^ UInt64(k)) &* 0x100000001b3; count += 1
        }
        return "slots=\(count) corrections=\(p.corrections) dropped=\(p.collision + p.catchUpSkip) (collision=\(p.collision) catchUpSkip=\(p.catchUpSkip)) pushed=\(p.pushedLate) early=\(early) shared=\(shared) fnv=\(hash)"
    }
    for (name, S, step) in [("120Hz S=1000/120 ms", 1000.0 / 120, 2), ("59.94Hz S=H*(1+50e-6)", H * (1 + 50 * 1e-6), 1)] {
        for ph in [0.0, 0.3, 0.8] {
            print("swift \(name) step=\(step) phase=\(ph) jitter=+-1ms: " + runCase(S: S, step: step, phase: ph * S, jitter: 1.0))
        }
    }
    exit(0)
}
if CommandLine.arguments.contains("--pacer-selftest") { pacerSelftest() }
if sourceArg != "index" && sourceArg != "counter" { die("--source must be index or counter (got \(sourceArg))") }
if !["keep", "native120", "native5994", "list"].contains(displayModeArg) { die("--display-mode must be keep, native120 or native5994 (got \(displayModeArg))") }
if !["link", "next", "vsync"].contains(modeArg) { die("--mode must be link, next or vsync (got \(modeArg))") }
if !["plain", "at-slot"].contains(presentArg) { die("--present must be plain or at-slot (got \(presentArg))") }
if !["srgb", "p3", "none"].contains(colorspaceArg) { die("--colorspace must be srgb, p3 or none (got \(colorspaceArg))") }
// A delay of a slot or more makes the next tick fire off the vsync grid (review finding: S fitted as 22.3 ms at 120 Hz with a 20 ms delay).
if !(renderDelayMs >= 0 && renderDelayMs <= 1000 / Double(linkHz) - 1.5) { die("--render-delay-ms must be a number from 0 to one slot minus 1.5 ms (\(1000 / Double(linkHz) - 1.5) ms at --link-hz \(linkHz))") }
var tbInfo = mach_timebase_info_data_t(); let _ = mach_timebase_info(&tbInfo)
let renderDelayTicks = UInt64(renderDelayMs / 1000 * 1e9 * Double(tbInfo.denom) / Double(tbInfo.numer))   // mach_wait_until units
if vsyncMode && (atTime || minDuration > 0) { die("--at-time and --min-duration do not apply to --mode vsync; use --present at-slot") }
if counterMode && nextMode { die("--source counter needs a slot grid; it cannot be combined with --mode next. Use --mode link or vsync, or --source index for the nextDrawable diagnostic.") }
if vsyncMode && !counterMode { die("--mode vsync needs --source counter") }
if (presentArg != "plain" || renderDelayMs > 0) && !vsyncMode { die("--present at-slot and --render-delay-ms need --mode vsync") }
if !slotsCSV.isEmpty && !counterMode { die("--slots-csv needs --source counter") }

let shaderSource = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
// rect = (x, y, w, h) in NDC. 4 vertices, triangle strip. uv (0,0) = top-left texel.
vertex VOut vsRect(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    float2 p = float2(vid & 1, vid >> 1);
    VOut o;
    o.pos = float4(rect.xy + p * rect.zw, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
// 8-bit video-range BT.709 Y'CbCr -> full-range non-linear R'G'B'. Columns multiply (Y-16/255, Cb-128/255, Cr-128/255).
fragment float4 fsConvert(VOut in [[stage_in]], texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ycbcr = float3(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg)
                 - float3(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0);
    const float3x3 m = float3x3(float3(1.164384, 1.164384, 1.164384),
                                float3(0.0, -0.213249, 2.112402),
                                float3(1.792741, -0.532909, 0.0));
    return float4(saturate(m * ycbcr), 1.0);
}
fragment float4 fsTex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
vertex float4 vsLine(uint vid [[vertex_id]], const device float2 *pts [[buffer(0)]]) {
    return float4(pts[vid], 0.0, 1.0);
}
fragment float4 fsColor(constant float4 &c [[buffer(0)]]) { return c; }
"""

// ---------- pixel buffers ----------
func makeBuffer() -> CVPixelBuffer {
    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true]
    var pb: CVPixelBuffer?
    let r = CVPixelBufferCreate(nil, inW, inH, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
    guard r == kCVReturnSuccess, let pb else { die("CVPixelBufferCreate \(r)") }
    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return pb
}
/// fill(x, y) returns (Y, Cb, Cr) for luma pixel x,y. Probe-only CPU write.
func fill(_ pb: CVPixelBuffer, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) {
    CVPixelBufferLockBaseAddress(pb, [])
    let yp = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let cp = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), cs = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
    for y in 0..<inH { for x in 0..<inW {
        let v = f(x, y)
        yp[y * ys + x] = v.0
        if y & 1 == 0 && x & 1 == 0 { cp[(y / 2) * cs + x] = v.1; cp[(y / 2) * cs + x + 1] = v.2 }
    } }
    CVPixelBufferUnlockBaseAddress(pb, [])
}
let bars: [(UInt8, UInt8, UInt8)] = [(235, 128, 128), (219, 16, 138), (188, 154, 16), (173, 42, 26),
                                     (78, 214, 230), (63, 102, 240), (32, 240, 118), (16, 128, 128)]
let barBuffer = makeBuffer()
fill(barBuffer) { x, _ in bars[x * 8 / inW] }

var frames: [CVPixelBuffer] = []
if videoPath.isEmpty {
    for i in 0..<60 {   // 1 s loop: a white bar moving 32 px per frame over a grey ramp
        let pb = makeBuffer(); let bx = i * 32
        fill(pb) { x, y in (x >= bx && x < bx + 24) ? (235, 128, 128) : (UInt8(16 + (x + y) % 200), 128, 128) }
        frames.append(pb)
    }
} else {
    // ponytail: preloads 120 decoded frames (about 370 MB) and loops them; swap for a decode thread + ring if longer runs matter.
    let asset = AVURLAsset(url: URL(fileURLWithPath: videoPath))
    guard let reader = try? AVAssetReader(asset: asset), let track = asset.tracks(withMediaType: .video).first else { die("cannot open \(videoPath)") }
    reader.timeRange = CMTimeRange(start: CMTime(seconds: Double(arg("start", "600"))!, preferredTimescale: 600),
                                   duration: CMTime(seconds: 10, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: inW, kCVPixelBufferHeightKey as String: inH,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true])
    out.alwaysCopiesSampleData = false
    reader.add(out)
    guard reader.startReading() else { die("startReading: \(String(describing: reader.error))") }
    while frames.count < 120, let sb = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(sb) { frames.append(pb) }
    }
    guard let f0 = frames.first else { die("no frames decoded") }
    let m = CVBufferCopyAttachment(f0, kCVImageBufferYCbCrMatrixKey, nil).map { "\($0)" } ?? "none"
    print("video: \(frames.count) frames \(CVPixelBufferGetWidth(f0))x\(CVPixelBufferGetHeight(f0)) iosurface=\(CVPixelBufferGetIOSurface(f0) != nil) matrix=\(m)")
}

// ---------- Metal setup ----------
guard let device0 = MTLCreateSystemDefaultDevice(), let queue0 = device0.makeCommandQueue() else { die("no Metal device") }
let device: MTLDevice = device0, queue: MTLCommandQueue = queue0   // plain lets are globals; guard-let bindings are not
let library: MTLLibrary
do { library = try device.makeLibrary(source: shaderSource, options: nil) } catch { die("shader: \(error)") }

func pipeline(_ vs: String, _ fs: String, blend: Bool = false) -> MTLRenderPipelineState {
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = library.makeFunction(name: vs)
    d.fragmentFunction = library.makeFunction(name: fs)
    let a = d.colorAttachments[0]!
    a.pixelFormat = .bgra8Unorm
    if blend {   // premultiplied alpha
        a.isBlendingEnabled = true
        a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one
        a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    do { return try device.makeRenderPipelineState(descriptor: d) } catch { die("pipeline \(vs)/\(fs): \(error)") }
}
let convertPSO = pipeline("vsRect", "fsConvert")
let blitPSO = pipeline("vsRect", "fsTex")
let textPSO = pipeline("vsRect", "fsTex", blend: true)
let linePSO = pipeline("vsLine", "fsColor")
let barPSO = pipeline("vsRect", "fsColor")

var cacheOut: CVMetalTextureCache?
guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheOut) == kCVReturnSuccess, let cache0 = cacheOut else { die("texture cache") }
let cache: CVMetalTextureCache = cache0

guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { die("MetalFX spatial scaler not supported") }
let sd = MTLFXSpatialScalerDescriptor()
sd.colorTextureFormat = .bgra8Unorm
sd.outputTextureFormat = .bgra8Unorm
sd.inputWidth = inW; sd.inputHeight = inH
sd.outputWidth = outW; sd.outputHeight = outH
sd.colorProcessingMode = .perceptual
guard let scaler0 = sd.makeSpatialScaler(device: device) else { die("makeSpatialScaler returned nil") }
let scaler: MTLFXSpatialScaler = scaler0
print("scaler usage: colorTextureUsage=\(scaler.colorTextureUsage.rawValue) outputTextureUsage=\(scaler.outputTextureUsage.rawValue) (1=shaderRead 2=shaderWrite 4=renderTarget)")

func texture(_ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ mode: MTLStorageMode) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = usage; d.storageMode = mode
    guard let t = device.makeTexture(descriptor: d) else { die("makeTexture \(w)x\(h)") }
    return t
}
let rgbTex = texture(inW, inH, scaler.colorTextureUsage.union([.renderTarget, .shaderRead]), .private)
let outTex = texture(outW, outH, scaler.outputTextureUsage.union(.shaderRead), .private)
scaler.inputContentWidth = inW; scaler.inputContentHeight = inH
scaler.colorTexture = rgbTex; scaler.outputTexture = outTex

var fullRect = SIMD4<Float>(-1, -1, 2, 2)

func encodeConvert(_ cb: MTLCommandBuffer, _ y: MTLTexture, _ c: MTLTexture) {
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = rgbTex
    rp.colorAttachments[0].loadAction = .dontCare
    rp.colorAttachments[0].storeAction = .store
    guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { die("convert encoder") }
    e.setRenderPipelineState(convertPSO)
    e.setVertexBytes(&fullRect, length: 16, index: 0)
    e.setFragmentTexture(y, index: 0); e.setFragmentTexture(c, index: 1)
    e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    e.endEncoding()
}
func planes(_ pb: CVPixelBuffer) -> (CVMetalTexture, CVMetalTexture, MTLTexture, MTLTexture)? {
    var yRef: CVMetalTexture?, cRef: CVMetalTexture?
    let r0 = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .r8Unorm, inW, inH, 0, &yRef)
    let r1 = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .rg8Unorm, inW / 2, inH / 2, 1, &cRef)
    guard r0 == kCVReturnSuccess, r1 == kCVReturnSuccess, let yRef, let cRef,
          let y = CVMetalTextureGetTexture(yRef), let c = CVMetalTextureGetTexture(cRef) else { return nil }
    return (yRef, cRef, y, c)
}

// ---------- colour self-check: GPU shader vs vImage BT.709 video-range on flat colour bars ----------
do {
    guard let p = planes(barBuffer), let cb = queue.makeCommandBuffer() else { die("self-check setup") }
    encodeConvert(cb, p.2, p.3)
    let shared = texture(inW, inH, .shaderRead, .shared)
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: rgbTex, to: shared); blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    var gpu = [UInt8](repeating: 0, count: inW * inH * 4)
    shared.getBytes(&gpu, bytesPerRow: inW * 4, from: MTLRegionMake2D(0, 0, inW, inH), mipmapLevel: 0)

    var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240, YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
    var info = vImage_YpCbCrToARGB()
    vImageConvert_YpCbCrToARGB_GenerateConversion(kvImage_YpCbCrToARGBMatrix_ITU_R_709_2, &range, &info, kvImage420Yp8_CbCr8, kvImageARGB8888, vImage_Flags(kvImageNoFlags))
    CVPixelBufferLockBaseAddress(barBuffer, .readOnly)
    var srcY = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(barBuffer, 0), height: vImagePixelCount(inH), width: vImagePixelCount(inW), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(barBuffer, 0))
    var srcC = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(barBuffer, 1), height: vImagePixelCount(inH / 2), width: vImagePixelCount(inW / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(barBuffer, 1))
    var ref = [UInt8](repeating: 0, count: inW * inH * 4)
    ref.withUnsafeMutableBytes { rb in
        var dst = vImage_Buffer(data: rb.baseAddress, height: vImagePixelCount(inH), width: vImagePixelCount(inW), rowBytes: inW * 4)
        vImageConvert_420Yp8_CbCr8ToARGB8888(&srcY, &srcC, &dst, &info, nil, 255, vImage_Flags(kvImageNoFlags))
    }
    CVPixelBufferUnlockBaseAddress(barBuffer, .readOnly)
    var maxDiff = 0
    for b in 0..<8 {
        let i = (inH / 2 * inW + b * inW / 8 + inW / 16) * 4
        let g = (Int(gpu[i + 2]), Int(gpu[i + 1]), Int(gpu[i]))          // gpu is BGRA
        let v = (Int(ref[i + 1]), Int(ref[i + 2]), Int(ref[i + 3]))      // ref is ARGB
        maxDiff = max(maxDiff, abs(g.0 - v.0), abs(g.1 - v.1), abs(g.2 - v.2))
        print("bar \(b) YCbCr=\(bars[b]) gpuRGB=\(g) vImageRGB=\(v)")
    }
    print("colour self-check: max |GPU - vImage| = \(maxDiff) (8-bit steps)")
}

// ---------- HUD: CoreText -> CGContext -> texture (2 textures, swapped atomically), graph = line strip ----------
let hudW = 1024, hudH = 96, graphN = 240
final class HUD {
    let textures = [texture(hudW, hudH, .shaderRead, .shared), texture(hudW, hudH, .shaderRead, .shared)]
    let front = Atomic<Int>(0)
    let visible = Atomic<Bool>(arg("hud", "1") == "1")
    let ctx = CGContext(data: nil, width: hudW, height: hudH, bitsPerComponent: 8, bytesPerRow: hudW * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let font = CTFontCreateWithName("Menlo-Bold" as CFString, 34, nil)
    let graph = device.makeBuffer(length: graphN * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)!
    /// Called at most 4 times per second, never on the render thread.
    func setText(_ s: String) {
        ctx.clear(CGRect(x: 0, y: 0, width: hudW, height: hudH))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6)); ctx.fill(CGRect(x: 0, y: 0, width: hudW, height: hudH))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)]))
        ctx.textPosition = CGPoint(x: 16, y: 32)
        CTLineDraw(line, ctx)
        let back = 1 - front.load(ordering: .acquiring)
        textures[back].replace(region: MTLRegionMake2D(0, 0, hudW, hudH), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: hudW * 4)
        front.store(back, ordering: .releasing)
    }
}
let hud = HUD()

// ---------- per-slot log (--source counter): preallocated, written by the callback and the Metal handlers, read at exit ----------
struct SlotRow {
    var slot: Int32 = 0, contentId: Int32 = -1
    var outcome: UInt8 = 1, handlerRan: UInt8 = 0      // outcome: 0 shown, 1 held, 2 skipped
    var target = 0.0, cb = 0.0, gpuStart = 0.0, gpuEnd = 0.0, presented = 0.0
    var ndWait = 0.0, ndTried: UInt8 = 0, ndNil: UInt8 = 0   // --mode vsync: nextDrawable() blocking time, tried, returned nil
}
func allocate<T>(_ n: Int, _ v: T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: n); p.initialize(repeating: v, count: n); return p
}
let rowCap = counterMode ? Int(seconds * Double(max(linkHz, 120)) * 1.05) + 2000 : 1
let rows = allocate(rowCap, SlotRow())
let posCap = counterMode ? Int(seconds * 61) + 1000 : 1       // positions reserved over the run
let posSlot = allocate(posCap, -1)                              // slot of each position, -1 = dropped
let resCap = 1024                                               // reserved-but-not-yet-due positions, ring
let resSlot = allocate(resCap, 0), resId = allocate(resCap, 0)
let diffRing = allocate(120, 0.0), diffScratch = allocate(120, 0.0)

// ---------- renderer ----------
final class Renderer: NSObject, CAMetalDisplayLinkDelegate {
    let lock = NSLock()
    var t0 = 0.0, callbacks = 0, texFail = 0, wrongThread = 0, lateRun = 0, parityFlips = 0
    // counter source (link thread only until finish)
    var slotIdx = 0
    var grid = SlotGrid(), pacer = Pacer(), nextPos = 0, t0c = 0.0, lastTarget = 0.0, diffN = 0
    var resHead = 0, resTail = 0, lastShownId = -1, stepUsed = 0, sMedian = 0.0
    var missedSlot = 0, nominalS = 0, gapCallbacks = 0, queueFull = 0, posOverflow = 0, rowOverflow = 0, shownDraws = 0, nilDrawables = 0, drains = 0, lastDrain = 0.0
    var barColor = SIMD4<Float>(1, 0, 1, 1)
    let parity = Atomic<Int>(Int(arg("parity", "0"))!)   // which callbacks present when present-every > 1; flipped when presents land one refresh late
    var linkThread: Thread?
    var cbTime: [Double] = [], lead: [Double] = [], tgtGap: [Double] = [], cpu: [Double] = [], gpu: [Double] = []
    var presented: [(target: Double, picked: Double, actual: Double)] = []
    var held: [(CVMetalTexture, CVMetalTexture)?] = [nil, nil, nil, nil]   // keeps plane textures alive past GPU use
    var intervals = [Float](repeating: 16.7, count: graphN), lastPresented = 0.0, ivIndex = 0
    var hudRect = SIMD4<Float>(-0.98, 0.86, Float(hudW) / Float(outW) * 2, Float(hudH) / Float(outH) * 2)
    var green = SIMD4<Float>(0.2, 1, 0.3, 1)

    override init() {
        super.init()
        cbTime.reserveCapacity(100_000); lead.reserveCapacity(100_000); tgtGap.reserveCapacity(100_000)
        cpu.reserveCapacity(100_000); gpu.reserveCapacity(100_000); presented.reserveCapacity(100_000)
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let now = CACurrentMediaTime()
        if linkThread != nil && Thread.current != linkThread { wrongThread += 1 }
        if t0 == 0 { t0 = update.targetPresentationTimestamp }
        callbacks += 1
        cbTime.append(now)
        lead.append(update.targetPresentationTimestamp - now)
        tgtGap.append(update.targetPresentationTimestamp - update.targetTimestamp)
        if counterMode { counterCallback(target: update.targetPresentationTimestamp, now: now, drawable: update.drawable); return }
        if (callbacks + parity.load(ordering: .relaxed)) % presentEvery != 0 { return }
        render(update.drawable, target: update.targetPresentationTimestamp, now: now)
    }

    /// --mode vsync: one CADisplayLink tick = one slot (slot time = targetTimestamp). No print, no file I/O here.
    @objc func vsyncTick(_ dl: CADisplayLink) {
        let entry = CACurrentMediaTime(), entryTicks = mach_absolute_time()
        if renderDelayTicks > 0 { mach_wait_until(entryTicks + renderDelayTicks) }   // (a)
        let now = CACurrentMediaTime()                 // pick time
        if linkThread != nil && Thread.current != linkThread { wrongThread += 1 }
        let target = dl.targetTimestamp
        if t0 == 0 { t0 = target }
        callbacks += 1
        cbTime.append(now)
        lead.append(target - entry)
        counterCallback(target: target, now: now, drawable: nil)
    }

    /// --source counter. Slot index advances by round(target difference / S) per callback, so a skipped callback does not shift the grid; slot time = `target`
    /// (link mode: targetPresentationTimestamp, vsync mode: targetTimestamp); S = median of the last 120 target differences.
    /// `drawable` is nil in vsync mode: the drawable is taken with layer.nextDrawable() only after a position was reserved for this slot.
    /// No print, no file I/O, no allocation here beyond what render() already does.
    func counterCallback(target: Double, now: Double, drawable: CAMetalDrawable?) {
        let cbN = callbacks - 1                        // row in the log: one per callback
        var S = 1.0 / Double(linkHz)
        if cbN > 0 {
            diffRing[diffN % 120] = target - lastTarget; diffN += 1
        }
        let m = min(diffN, 120)
        if m > 0 {
            for j in 0..<m { diffScratch[j] = diffRing[j] }
            var sortBuf = UnsafeMutableBufferPointer(start: diffScratch, count: m); sortBuf.sort()   // in place, no allocation
            S = m % 2 == 1 ? diffScratch[m / 2] : (diffScratch[m / 2 - 1] + diffScratch[m / 2]) / 2
            if target - lastTarget > 1.5 * S { gapCallbacks += 1 }
            slotIdx += max(1, Int(((target - lastTarget) / S).rounded()))   // a missed callback still advances the slot index
        } else { nominalS += 1 }                       // first callback only: no difference observed yet, nominal 1 / link-hz
        lastTarget = target
        sMedian = S
        let idx = slotIdx
        grid = SlotGrid(idx: idx, t: target, S: S)
        let step = max(1, Int((contentH / S).rounded()))
        stepUsed = step
        if t0c == 0 { t0c = target }
        // Reserve every position whose content time is within 100 ms of now.
        while nextPos < posCap {
            let c = t0c + Double(nextPos) * contentH
            if c >= now + 0.1 { break }
            if let k = pacer.reserve(i: nextPos, g: c, grid: grid, step: step, eps: 0.0015, nextPickable: idx) {
                posSlot[nextPos] = k
                if resTail - resHead >= resCap { queueFull += 1 } else { resSlot[resTail % resCap] = k; resId[resTail % resCap] = nextPos; resTail += 1 }
            } else { posSlot[nextPos] = -1 }
            nextPos += 1
        }
        if nextPos >= posCap { posOverflow = 1 }
        while resHead < resTail && resSlot[resHead % resCap] < idx { missedSlot += 1; resHead += 1 }   // slot already past: never shown
        let row = cbN < rowCap ? cbN : -1
        if row >= 0 { rows[row].slot = Int32(idx); rows[row].target = target; rows[row].cb = now } else { rowOverflow += 1 }
        if resHead < resTail && resSlot[resHead % resCap] == idx {
            let id = resId[resHead % resCap]; resHead += 1
            var d = drawable
            if vsyncMode {                             // (c) blocking time of nextDrawable() is logged; nil = skipped
                let t1 = CACurrentMediaTime()
                d = layer.nextDrawable()
                if row >= 0 { rows[row].ndWait = CACurrentMediaTime() - t1; rows[row].ndTried = 1; rows[row].ndNil = d == nil ? 1 : 0 }
                if d == nil { nilDrawables += 1 }
                // Measured 2026-11-19 (probes/out/g1/matrix_1646.txt, matrix_1651.txt): when nextDrawable() blocks, a frame is queued ahead of this one and every
                // later frame reaches the glass one refresh later (33.3 ms after the slot time instead of 16.7), and it stays that way. --drain-ms X: when the wait
                // exceeds X ms, give this drawable back unpresented so the queue drains by one. Costs one held frame; at most once per second.
                else if drainMs > 0 && (CACurrentMediaTime() - t1) * 1000 > drainMs && now - lastDrain > 1 { d = nil; drains += 1; lastDrain = now }
            }
            var ok = false
            if let d { ok = render(d, target: target, now: now, content: id, row: row) }
            if ok { lastShownId = id; shownDraws += 1 }
            if row >= 0 { rows[row].outcome = ok ? 0 : 2; rows[row].contentId = Int32(id) }
        } else if row >= 0 {                           // nothing reserved for this slot: no present, the previous image stays on glass
            rows[row].outcome = 1; rows[row].contentId = Int32(lastShownId)
        }
    }

    /// --mode next: nextDrawable() blocks until a drawable is free, so the loop is paced by the swap queue, not by sleeping.
    /// The latency timer starts before nextDrawable() is called, so the wait for a free drawable is inside the measured latency.
    func loopNextDrawable(_ layer: CAMetalLayer) {
        while true {
            autoreleasepool {
                let before = CACurrentMediaTime()
                guard let d = layer.nextDrawable() else { texFail += 1; return }
                let got = CACurrentMediaTime()
                if t0 == 0 { t0 = before }
                callbacks += 1
                cbTime.append(before)
                render(d, target: before, now: before, cpuStart: got)
            }
        }
    }

    /// content == nil: --source index (frame from the 60.000 Hz index). content = position id: --source counter (frame id % count, bar at id % 240).
    /// row >= 0: this slot's row in `rows` receives gpu start/end and the presented time from the Metal handlers.
    @discardableResult
    func render(_ drawable: CAMetalDrawable, target: Double, now: Double, cpuStart: Double? = nil, content: Int? = nil, row: Int = -1) -> Bool {
        // Stand-in for the frame queue: content frame k is due at t0 + k/60. Newest frame with due time <= target.
        let k = (content ?? Int(((target - t0) * 60).rounded(.down))) % frames.count
        guard let p = planes(frames[k]), let cb = queue.makeCommandBuffer() else { texFail += 1; return false }
        held[callbacks & 3] = (p.0, p.1)
        encodeConvert(cb, p.2, p.3)
        if useScaler { scaler.encode(commandBuffer: cb) }

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = drawable.texture
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { texFail += 1; return false }
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height)
        let ph = dw * 9 / 16   // 16:9 picture, centred, black bars above and below
        e.setViewport(MTLViewport(originX: 0, originY: (dh - ph) / 2, width: dw, height: ph, znear: 0, zfar: 1))
        e.setRenderPipelineState(blitPSO)
        e.setVertexBytes(&fullRect, length: 16, index: 0)
        e.setFragmentTexture(useScaler ? outTex : rgbTex, index: 0)
        e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        if let id = content {   // a camera can see the content id change: a magenta bar, 2 steps wide, x = id % 240 steps across the picture
            var bar = SIMD4<Float>(-1 + 2 * Float(id % 240) / 240, -1, 4.0 / 240, 2)
            e.setRenderPipelineState(barPSO)
            e.setVertexBytes(&bar, length: 16, index: 0)
            e.setFragmentBytes(&barColor, length: 16, index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if hud.visible.load(ordering: .relaxed) {
            e.setRenderPipelineState(textPSO)
            e.setVertexBytes(&hudRect, length: 16, index: 0)
            e.setFragmentTexture(hud.textures[hud.front.load(ordering: .acquiring)], index: 0)
            e.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            let v = hud.graph.contents().bindMemory(to: SIMD2<Float>.self, capacity: graphN)
            lock.lock()
            for i in 0..<graphN {   // x: left quarter of the picture, y: 0..33.3 ms mapped under the text
                let ms = min(intervals[(ivIndex + i) % graphN], 33.3)
                v[i] = SIMD2<Float>(-0.98 + Float(i) / Float(graphN) * 0.5, 0.60 + ms / 33.3 * 0.24)
            }
            lock.unlock()
            e.setRenderPipelineState(linePSO)
            e.setVertexBuffer(hud.graph, offset: 0, index: 0)
            e.setFragmentBytes(&green, length: 16, index: 0)
            e.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: graphN)
        }
        e.endEncoding()

        drawable.addPresentedHandler { [self] d in
            let t = d.presentedTime
            lock.lock()
            presented.append((target, now, t))
            if row >= 0 { rows[row].presented = t; rows[row].handlerRan = 1 }
            // Phase lock: 8 presents in a row landing > 4 ms after their target means the display refreshes on the other callback parity.
            // (Not in --source counter: there the reservations decide which callback presents.)
            if autoParity && presentEvery > 1 && t > 0 && !counterMode {
                lateRun = (t - target > 0.004) ? lateRun + 1 : 0
                if lateRun >= 8 { lateRun = 0; parityFlips += 1; parity.store(parity.load(ordering: .relaxed) + 1, ordering: .relaxed) }
            }
            if t > 0 && lastPresented > 0 { intervals[ivIndex] = Float((t - lastPresented) * 1000); ivIndex = (ivIndex + 1) % graphN }
            if t > 0 { lastPresented = t }
            lock.unlock()
        }
        cb.addCompletedHandler { [self] c in
            lock.lock(); gpu.append(c.gpuEndTime - c.gpuStartTime)
            if row >= 0 { rows[row].gpuStart = c.gpuStartTime; rows[row].gpuEnd = c.gpuEndTime }
            lock.unlock()
        }
        // Measured 2026-11-19: with a CAMetalDisplayLink drawable, present(atTime:) and present(afterMinimumDuration:) both raise
        // CAMetalDrawableInvalidOperation. --at-time 1 and --min-duration in link mode exist only to reproduce that.
        // --mode vsync has no CAMetalDisplayLink on the layer, so present(_:atTime:) is allowed there: slot time = the link's targetTimestamp.
        if vsyncMode { if atSlot { cb.present(drawable, atTime: target) } else { cb.present(drawable) } }
        else if minDuration > 0 { cb.present(drawable, afterMinimumDuration: minDuration) }
        else if atTime { cb.present(drawable, atTime: target) } else { cb.present(drawable) }
        cb.commit()
        cpu.append(CACurrentMediaTime() - (cpuStart ?? now))
        return true
    }
}

// ---------- window ----------
final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }
let app = NSApplication.shared

// ---------- display mode (--display-mode): built-in panel, 3456x2234, app-scoped only (.forAppOnly: reverts when this process exits) ----------
func builtinDisplayID() -> CGDirectDisplayID? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return nil }
    return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
}
func modeText(_ m: CGDisplayMode) -> String {
    String(format: "%dx%d pt, %dx%d px, %.3f Hz", m.width, m.height, m.pixelWidth, m.pixelHeight, m.refreshRate)
}
/// Returns the text for the report. Prints "DISPLAY MODE NOT APPLIED: <reason>" and returns "keep (NOT APPLIED: <reason>) ..." on any failure.
func applyDisplayMode(_ which: String) -> String {
    let id = builtinDisplayID() ?? CGMainDisplayID()
    let cur = CGDisplayCopyDisplayMode(id).map(modeText) ?? "unknown"
    func fail(_ why: String) -> String {
        print("DISPLAY MODE NOT APPLIED: \(why)")
        return "NOT APPLIED (\(why)); running in the current mode \(cur)"
    }
    if which == "keep" { return "keep: current mode \(cur)" }
    guard CGDisplayIsBuiltin(id) != 0 else { return fail("no built-in display is active") }
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    guard let all = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return fail("CGDisplayCopyAllDisplayModes returned nothing") }
    let native = all.filter { $0.pixelWidth == 3456 && $0.pixelHeight == 2234 }
    if which == "list" {
        print("current: \(cur)")
        for m in native { print("3456x2234 px mode: \(modeText(m)) usableForDesktopGUI=\(m.isUsableForDesktopGUI()) ioFlags=0x\(String(m.ioFlags, radix: 16))") }
        print("(\(all.count) modes in total, \(native.count) at 3456x2234 px)")
        return "list"
    }
    let want = which == "native120" ? 120.0 : 59.94
    let cands = native.filter { abs($0.refreshRate - want) <= 0.01 }
    // Prefer the HiDPI mode (1728x1117 pt at 2x) over a 1x mode with the same pixel size.
    guard let mode = cands.first(where: { $0.pixelWidth > $0.width && $0.isUsableForDesktopGUI() }) ?? cands.first else {
        return fail("no 3456x2234 px mode at \(want) Hz; the built-in display offers: " + native.map(modeText).joined(separator: "; "))
    }
    var cfg: CGDisplayConfigRef?
    let b = CGBeginDisplayConfiguration(&cfg)
    guard b == .success, let cfg else { return fail("CGBeginDisplayConfiguration error \(b.rawValue)") }
    let c = CGConfigureDisplayWithDisplayMode(cfg, id, mode, nil)
    guard c == .success else { CGCancelDisplayConfiguration(cfg); return fail("CGConfigureDisplayWithDisplayMode error \(c.rawValue)") }
    let d = CGCompleteDisplayConfiguration(cfg, .forAppOnly)
    guard d == .success else { return fail("CGCompleteDisplayConfiguration error \(d.rawValue)") }
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.5))   // let AppKit's screen list follow the change before the window is made
    guard let now = CGDisplayCopyDisplayMode(id) else { return fail("CGDisplayCopyDisplayMode returned nil after the change") }
    let applied = modeText(now)
    print("display mode requested: \(modeText(mode))")
    print("display mode applied (read back): \(applied)")
    if now.pixelWidth != 3456 || now.pixelHeight != 2234 || abs(now.refreshRate - want) > 0.01 {
        return fail("read-back mode is \(applied), not 3456x2234 at \(want) Hz")
    }
    return "\(which): \(applied) (was \(cur))"
}
// A locked screen or a sleeping display stops the display link after a few callbacks and makes the mode switch fail (error 1014): refuse to measure.
if fullWindow || (displayModeArg != "keep" && displayModeArg != "list") {
    let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    if locked || CGDisplayIsAsleep(builtinDisplayID() ?? CGMainDisplayID()) != 0 { die("screen is locked or the display is asleep: unlock the Mac and run again") }
}
// Display sleep is 1 min on this Mac and a run has no user input: hold the display awake for this process only (no system setting is changed).
let awake = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: "present_probe run")
let displayModeNote = applyDisplayMode(displayModeArg)
if displayModeArg == "list" { exit(0) }

var chosenScreen = NSScreen.main
if displayModeArg != "keep", let id = builtinDisplayID(),
   let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) { chosenScreen = s }
guard let screen = chosenScreen else { die("no screen") }
print("display mode: \(displayModeNote)")
print("screen: frame=\(screen.frame) scale=\(screen.backingScaleFactor) maxFPS=\(screen.maximumFramesPerSecond) minRefresh=\(screen.minimumRefreshInterval * 1000) ms maxRefresh=\(screen.maximumRefreshInterval * 1000) ms granularity=\(screen.displayUpdateGranularity * 1000) ms safeTop=\(screen.safeAreaInsets.top) pt")

let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.framebufferOnly = true
layer.displaySyncEnabled = true
layer.presentsWithTransaction = false
layer.maximumDrawableCount = drawablesArg
layer.isOpaque = true
layer.colorspace = colorspaceArg == "none" ? nil : CGColorSpace(name: colorspaceArg == "p3" ? CGColorSpace.displayP3 : CGColorSpace.sRGB)
layer.allowsNextDrawableTimeout = true
layer.contentsScale = screen.backingScaleFactor
// Drawable is always full-screen pixel size so GPU cost matches the real app even in the small window.
layer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
if !drawableArg.isEmpty { let p = drawableArg.split(separator: "x").map { Double($0)! }; layer.drawableSize = CGSize(width: p[0], height: p[1]) }

let window: NSWindow
if fullWindow {
    app.setActivationPolicy(.regular)
    window = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.level = .mainMenu + 1
    window.backgroundColor = .black
} else {
    app.setActivationPolicy(.accessory)
    window = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 432, height: 279), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    window.title = "present_probe"
}
let view = NSView(frame: window.contentLayoutRect)
view.layer = layer            // layer-hosting view: set layer first, then wantsLayer
view.wantsLayer = true
window.contentView = view
if fullWindow { window.makeKeyAndOrderFront(nil); window.orderFrontRegardless(); app.activate(ignoringOtherApps: true) } else { window.orderFrontRegardless() }

let renderer = Renderer()
let link: CAMetalDisplayLink? = vsyncMode ? nil : CAMetalDisplayLink(metalLayer: layer)   // --mode vsync: no CAMetalDisplayLink on this layer
var vsyncLink: CADisplayLink?
if let link {
    print("link defaults: preferredFrameLatency=\(link.preferredFrameLatency) range=\(link.preferredFrameRateRange) drawableCount=\(layer.maximumDrawableCount)")
    link.delegate = renderer
    link.preferredFrameRateRange = CAFrameRateRange(minimum: linkHz, maximum: linkHz, preferred: linkHz)
    if latencyArg >= 0 { link.preferredFrameLatency = latencyArg }
}
if vsyncMode {
    let dl = screen.displayLink(target: renderer, selector: #selector(Renderer.vsyncTick(_:)))
    dl.preferredFrameRateRange = CAFrameRateRange(minimum: linkHz, maximum: linkHz, preferred: linkHz)
    vsyncLink = dl
    print("vsync link: CADisplayLink from NSScreen, range=\(dl.preferredFrameRateRange) drawableCount=\(layer.maximumDrawableCount)")
    if arg("runloop", "thread") == "main" {
        renderer.linkThread = Thread.main
        dl.add(to: .main, forMode: .common)
    } else {
        let thread = Thread {
            renderer.linkThread = Thread.current
            dl.add(to: .current, forMode: .common)
            RunLoop.current.run()
        }
        thread.name = "present"; thread.qualityOfService = .userInteractive
        thread.start()
    }
} else if nextMode {
    link!.invalidate()   // exactly once: a second invalidate() crashed (SIGSEGV in CAMetalLayerSetMetalLinkToken, measured 2026-11-19)
    let thread = Thread { renderer.loopNextDrawable(layer) }
    thread.name = "present"; thread.qualityOfService = .userInteractive
    thread.start()
} else if arg("runloop", "thread") == "main" {
    renderer.linkThread = Thread.main
    link!.add(to: .main, forMode: .common)
} else {
    let thread = Thread {
        renderer.linkThread = Thread.current
        link!.add(to: .current, forMode: .default)
        RunLoop.current.run()
    }
    thread.name = "present"; thread.qualityOfService = .userInteractive
    thread.start()
}

let hudTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "hud", qos: .utility))
hudTimer.schedule(deadline: .now(), repeating: 0.25)
hudTimer.setEventHandler {
    renderer.lock.lock(); let n = renderer.presented.count; let last = renderer.intervals[(renderer.ivIndex + graphN - 1) % graphN]; renderer.lock.unlock()
    hud.setText(String(format: "presented %d   last interval %.2f ms", n, last))
}
hudTimer.resume()

func shell(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return "unavailable (\(error))" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// G1 report for --source counter, computed from the same rows that go to --slots-csv. Call with r.lock held, after the link is invalidated.
func counterReport(_ r: Renderer) {
    let n = min(r.callbacks, rowCap)
    var shown = 0, held = 0, skipped = 0, zeroPresented = 0, handlerNotRun = 0
    var lat: [(t: Double, lat: Double, late: Double)] = [], pres: [(t: Double, id: Int)] = []   // t = presented_time; late = presented - slot time
    var ndw: [(cb: Double, w: Double)] = [], ndNils = 0
    var zeroCb: [Double] = [], lastGoodCb = 0.0     // shown rows never confirmed on glass; pick time of the last confirmed one
    var shownId = [Bool](repeating: false, count: posCap)
    for i in 0..<n {
        let w = rows[i]
        if w.ndTried != 0 { ndw.append((w.cb, w.ndWait)); ndNils += Int(w.ndNil) }
        switch w.outcome {
        case 0:
            shown += 1
            if w.contentId >= 0 && Int(w.contentId) < posCap { shownId[Int(w.contentId)] = true }
            if w.presented == 0 { zeroPresented += 1; zeroCb.append(w.cb); if w.handlerRan == 0 { handlerNotRun += 1 } }
            else { lastGoodCb = w.cb; lat.append((w.presented, w.presented - w.cb, w.presented - w.target)); pres.append((w.presented, Int(w.contentId))) }
        case 1: held += 1
        default: skipped += 1
        }
    }
    print("---- G1 report (--source counter) ----")
    print("display mode applied: \(displayModeNote)")
    let S = r.sMedian
    print(String(format: "link rate: requested %.1f Hz, measured %.3f Hz (1 / S median); step = %d slot(s) per position; S median = %.4f ms (last 120 target differences)", Double(linkHz), S > 0 ? 1 / S : 0, r.stepUsed, S * 1000))
    print("pmset -g batt (first line): \(shell("pmset -g batt | head -1"))")
    print("pmset -g | grep lowpowermode: \(shell("pmset -g | grep lowpowermode"))")
    var la = [Double](repeating: 0, count: 3); getloadavg(&la, 3)
    print(String(format: "load average at exit: %.2f %.2f %.2f", la[0], la[1], la[2]))
    func q(_ s: [Double], _ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] }
    // Latency lines exclude the first `warm` s after the first non-zero presented time, like the content intervals below.
    let warm = Double(arg("warmup", "2"))!
    let first = pres.first?.t ?? 0
    let steady = lat.filter { $0.t >= first + warm }
    let ls = steady.map { $0.lat }.sorted(), lt = steady.map { $0.late }.sorted()
    var p99 = Double.nan
    if ls.isEmpty { print("latency (presented_time - callback_time, shown rows, non-zero presented, first \(warm) s excluded): no samples") }
    else {
        p99 = q(ls, 0.99) * 1000
        print(String(format: "latency (presented_time - callback_time, shown rows, non-zero presented, first %.1f s excluded): n=%d p50=%.3f p99=%.3f max=%.3f ms", warm, ls.count, q(ls, 0.5) * 1000, p99, ls[ls.count - 1] * 1000))
        let lateN = lt.filter { $0 > S / 2 }.count
        print(String(format: "presented_time - slot time (target_time of the row, same rows): p50=%.3f p99=%.3f max=%.3f ms; rows more than half a slot (%.3f ms) late: %d of %d", q(lt, 0.5) * 1000, q(lt, 0.99) * 1000, lt[lt.count - 1] * 1000, S * 500, lateN, lt.count))
    }
    if vsyncMode {
        let t0r = ndw.first?.cb ?? 0
        let nw = ndw.filter { $0.cb >= t0r + warm }.map { $0.w }.sorted()
        if nw.isEmpty { print("nextDrawable() wait: no samples; nil drawables: \(ndNils)") }
        else { print(String(format: "nextDrawable() wait (first %.1f s excluded): n=%d p50=%.3f p99=%.3f max=%.3f ms; nil drawables (whole run): %d", warm, nw.count, q(nw, 0.5) * 1000, q(nw, 0.99) * 1000, nw[nw.count - 1] * 1000, ndNils)) }
    }
    // Content intervals: consecutive shown rows with non-zero presented time and different content ids. A shown row with presented_time 0 is left out,
    // so the interval across it is about two positions long and counts as out of band. Shown rows with presented_time 0 AFTER the last confirmed row have no
    // interval across them: each is counted as one out-of-band event (review finding: 753 such rows were invisible in one at-slot run).
    var ivs: [(iv: Double, t: Double)] = [], inBand = 0, outT: [Double] = []
    var outList: [String] = []
    for j in 1..<max(1, pres.count) where pres[j].id != pres[j - 1].id && pres[j].t >= first + warm {
        let iv = pres[j].t - pres[j - 1].t
        ivs.append((iv, pres[j].t))
        if abs(iv - 0.016683) <= 0.002 { inBand += 1 } else { outT.append(pres[j].t); outList.append(String(format: "%.2fms@%.2fs", iv * 1000, pres[j].t - first)) }
    }
    let trailingZero = zeroCb.filter { $0 > lastGoodCb }
    outT.append(contentsOf: trailingZero)             // pick times, same host clock as presented times; later than every interval above
    var worst15 = 0, lo = 0
    for hi in 0..<outT.count {
        while outT[hi] - outT[lo] >= 15 { lo += 1 }
        worst15 = max(worst15, hi - lo + 1)
    }
    let inPct = ivs.isEmpty ? Double.nan : 100 * Double(inBand) / Double(ivs.count + trailingZero.count)
    print(String(format: "content intervals (first %.1f s excluded): count=%d within 16.683 +- 2 ms: %d = %.3f %%, out of band: %d, max out-of-band in any rolling 15 s window: %d", warm, ivs.count, inBand, inPct, outT.count, worst15))
    if !outList.isEmpty { print("out-of-band intervals (interval@time since first present, first \(min(40, outList.count)) of \(outList.count)): " + outList.prefix(40).joined(separator: " ")) }
    var reserved = 0, neverShown = 0, pendingAtExit = 0
    for i in 0..<min(r.nextPos, posCap) where posSlot[i] >= 0 {
        reserved += 1
        if posSlot[i] > r.slotIdx { pendingAtExit += 1 } else if !shownId[i] { neverShown += 1 }
    }
    print("slots: shown=\(shown) held=\(held) skipped=\(skipped) (callbacks=\(r.callbacks), rows=\(n)); shown rows with presented_time == 0: \(zeroPresented) (of which handler had not run at exit: \(handlerNotRun))")
    print("pacer: corrections=\(r.pacer.corrections) collision=\(r.pacer.collision) pushedLate=\(r.pacer.pushedLate) catchUpSkip=\(r.pacer.catchUpSkip); positions reserved=\(reserved) never shown=\(neverShown) (slot already past when due: \(r.missedSlot)) pending at exit=\(pendingAtExit) dropped at reservation=\(r.pacer.collision + r.pacer.catchUpSkip)")
    print("housekeeping: nominalS=\(r.nominalS) gapCallbacks=\(r.gapCallbacks) reservationQueueFull=\(r.queueFull) positionLogFull=\(r.posOverflow) rowLogFull=\(r.rowOverflow) nilDrawables=\(r.nilDrawables) drains=\(r.drains)")
    print(String(format: "G1 RESULT: latency_p99_ms=%@ in_band_pct=%@ max_glitches_per_15s=%d mode=%@ present=%@ render_delay_ms=%g zero_presented=%d trailing_zero=%d drain_ms=%g drains=%d",
                 p99.isNaN ? "n/a" : String(format: "%.2f", p99), inPct.isNaN ? "n/a" : String(format: "%.3f", inPct), worst15,
                 vsyncMode ? "vsync" : "link", vsyncMode ? presentArg : "n/a", renderDelayMs, zeroPresented, trailingZero.count, drainMs, r.drains))
    if !slotsCSV.isEmpty {
        var s = "slot,target_time,callback_time,outcome,content_id,gpu_start,gpu_end,presented_time\n"
        s.reserveCapacity(n * 100)
        let names = ["shown", "held", "skipped"]
        for i in 0..<n {
            let w = rows[i]
            s += String(format: "%d,%.6f,%.6f,", w.slot, w.target, w.cb) + names[Int(min(w.outcome, 2))]
            s += String(format: ",%d,%.6f,%.6f,%.6f\n", w.contentId, w.gpuStart, w.gpuEnd, w.presented)
        }
        do { try s.write(toFile: slotsCSV, atomically: true, encoding: .utf8); print("slots csv: \(n) rows written to \(slotsCSV)") }
        catch { print("slots csv NOT WRITTEN: \(error)") }
    }
}

func finish() -> Never {
    if vsyncMode { vsyncLink?.invalidate() } else if !nextMode { link?.invalidate() }
    Thread.sleep(forTimeInterval: vsyncMode ? 1.2 : 0.3)   // let the last presented handlers arrive; vsync: also outlast nextDrawable()'s 1 s timeout in a tick in flight. Probe shutdown only
    let r = renderer
    if nextMode { print("DIAGNOSTIC ONLY: no slot grid") }
    r.lock.lock()
    func stats(_ name: String, _ xs: [Double], _ scale: Double = 1000) {
        let s = xs.sorted(); guard !s.isEmpty else { print("\(name): no samples"); return }
        func q(_ p: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * p))] * scale }
        print(String(format: "%@: n=%d min=%.3f p50=%.3f p99=%.3f max=%.3f mean=%.3f ms", name, s.count, s[0] * scale, q(0.5), q(0.99), s[s.count - 1] * scale, s.reduce(0, +) / Double(s.count) * scale))
    }
    print("config: mode=\(modeArg) present=\(vsyncMode ? presentArg : "n/a") render-delay-ms=\(renderDelayMs) colorspace=\(colorspaceArg) min-duration=\(minDuration) link-hz=\(linkHz) present-every=\(presentEvery) latency=\(link.map { "\($0.preferredFrameLatency)" } ?? "n/a") drawables=\(layer.maximumDrawableCount) at-time=\(atTime) hud=\(hud.visible.load(ordering: .relaxed)) window=\(fullWindow ? "full" : "small") drawable=\(Int(layer.drawableSize.width))x\(Int(layer.drawableSize.height)) scaler=\(useScaler) picture=\(videoPath.isEmpty ? "synthetic" : "video") source=\(sourceArg) display-mode=\(displayModeArg)")
    print("callbacks=\(r.callbacks) parityFlips=\(r.parityFlips) wrongThread=\(r.wrongThread) textureFailures=\(r.texFail) presentedHandlers=\(r.presented.count) presentedTime==0: \(r.presented.filter { $0.actual == 0 }.count)")
    stats("callback interval", zip(r.cbTime.dropFirst(), r.cbTime).map { $0 - $1 })
    stats(vsyncMode ? "lead (targetTimestamp - tick entry)" : "lead (targetPresentationTimestamp - callback now)", r.lead)
    if !vsyncMode { stats("targetPresentationTimestamp - targetTimestamp", r.tgtGap) }
    stats("callback CPU time", r.cpu)
    stats("GPU time (GPUEndTime - GPUStartTime)", r.gpu)
    let all = r.presented.filter { $0.actual > 0 }.sorted { $0.actual < $1.actual }
    let warmup = Double(arg("warmup", "2"))!   // seconds after the first present that are left out of the present statistics
    let ok = all.filter { $0.actual >= (all.first?.actual ?? 0) + warmup }
    print("present statistics exclude the first \(warmup) s (\(all.count - ok.count) frames)")
    if !nextMode { stats(vsyncMode ? "presentedTime - slot time (targetTimestamp)" : "presentedTime - targetPresentationTimestamp", ok.map { $0.actual - $0.target }) }
    stats("glass latency (presentedTime - time the frame was picked)", ok.map { $0.actual - $0.picked })
    if counterMode { counterReport(r); r.lock.unlock(); exit(0) }   // the index-source interval / glitch lines below do not apply to the counter source
    let iv = zip(ok.dropFirst(), ok).map { $0.actual - $1.actual }
    stats("presented interval", iv)
    let expected = Double(arg("expect-ms", "0"))! > 0 ? Double(arg("expect-ms", "0"))! / 1000 : (nextMode ? max(minDuration, screen.minimumRefreshInterval) : Double(presentEvery) / Double(linkHz))
    let good = iv.filter { abs($0 - expected) <= 0.002 }.count
    let t0p = ok.first?.actual ?? 0
    let bad = iv.enumerated().filter { abs($0.element - expected) > 0.002 }.prefix(12).map { String(format: "%.2fms@%.2fs", $0.element * 1000, ok[$0.offset + 1].actual - t0p) }
    if !bad.isEmpty { print("glitches (interval@time since first present): \(bad.joined(separator: " "))") }
    if !iv.isEmpty { print(String(format: "presented intervals within %.2f ms +- 2 ms: %d / %d = %.3f %%, glitches=%d", expected * 1000, good, iv.count, 100 * Double(good) / Double(iv.count), iv.count - good)) }
    r.lock.unlock()
    exit(0)
}
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish() }
NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
    switch ev.charactersIgnoringModifiers {
    case "h": hud.visible.store(!hud.visible.load(ordering: .relaxed), ordering: .relaxed); return nil
    case "q", "\u{1b}": finish()
    default: return ev
    }
}
app.run()
