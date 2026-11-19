# Skill: metal-present

## 1. Purpose and scope
Put frames on the MacBook's built-in display. In: 1920x1080 `420v` IOSurface-backed CVPixelBuffers, each with a target host time. Out: a steady 60 fps picture at 3456x1944 with the lowest added latency, plus honest timing numbers.
Covers: CAMetalLayer setup, CAMetalDisplayLink, CVMetalTextureCache (zero copy), BT.709 shader, MetalFX spatial scaler, pacing and its counters, the HUD.
Does not cover: capture, cadence detection, frame interpolation, audio. Real and generated frames take the identical path here: convert -> scaler -> final pass.

## 1a. Decisions from PLAN.md (these win over anything below)
- Names: generation off is called *real-only*; real and generated alternating is *framegen*. Cadence states in code are `locked22`, `native60`, `unknown` (this file's `LOCKED_2_2`, `PASSTHROUGH_60`, `UNKNOWN`). "Passthrough" means only the HDMI cable from the card to the TV.
- Types and signatures: PLAN.md section 6. Example names in this file are for the example only.
- Buffer ownership: PLAN.md section 5 table. Every buffer you receive comes from the app's own pools, never from the capture device.
- Counters: every fallback has a named counter (PLAN.md sections 5 and 5.2). Use those names. Every item and every reservation carries an epoch (PLAN.md section 5, "Epochs").
- Logs: the two ledgers of PLAN.md section 6 (`items.csv`, `slots.csv`) plus `counters.txt` and `run.json` under `runs/<date-time>/`. Acceptance numbers are computed from these files by `tools/stats.py`, never from console prints.
- This skill owns what is shown in each slot: the item assigned to the slot, else hold the last image (`held` + 1). A late midpoint is never shown after its slot.
- The presenter never chooses times. The Conductor (PLAN.md section 5) reserves slot indices with the `Pacer`; the presenter publishes its measured grid through `slotGrid` and reports every callback through `onSlotReport` (never called on the display thread). The presenter has no parity or drift controller of its own: the example's auto-parity logic belongs to the probe only.
- Scaling: the first version converts and scales bilinearly in one pass straight into the drawable. MetalFX is a switch added in phase 4. The example's MetalFX pass is reference material for that task.
- Display mode: the app switches the built-in display to 3456x2234 for its own lifetime with `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(config, .forAppOnly)`. The refresh rate (120 or 59.94) is a launch option; `slotsPerFrame` is 2 or 1 to match.
- The render-pass descriptors are created once and reused; the example creating two per frame is a defect in the example, do not copy it.
- `stop()` is called on the main thread, exactly once; `invalidate()` twice crashes.

## 2. Exact APIs
`SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`. Header paths below are under `$SDK/System/Library/Frameworks/`. Headers read on 2026-11-19. "Measured" means `probes/present_probe.swift` on this Mac, conditions in 2.6. Open the header before you rely on anything not listed here.

### 2.1 CAMetalDisplayLink - `QuartzCore.framework/Headers/CAMetalDisplayLink.h` (macOS 14+)
The header has declarations only, no comments. Every behaviour below is measured or marked not documented.

| Swift | Obj-C | Notes |
|---|---|---|
| `CAMetalDisplayLink(metalLayer:)` | `-initWithMetalLayer:` | Layer must have `device` set. Create it after the window is on screen. |
| `add(to: RunLoop, forMode:)` | `-addToRunLoop:forMode:` | Callbacks arrive on that run loop's thread (measured: 0 of 7437 on another thread). |
| `remove(from:forMode:)`, `invalidate()` | `-removeFromRunLoop:forMode:`, `-invalidate` | A second `invalidate()` crashes with SIGSEGV in `CAMetalLayerSetMetalLinkToken` (measured). Call it once. |
| `delegate` (weak) | `delegate` | Keep your own strong reference to the delegate. |
| `preferredFrameRateRange: CAFrameRateRange` | same | Default is (0, 0, 0) (measured). `CAFrameRateRange(minimum:maximum:preferred:)`; Obj-C `CAFrameRateRangeMake`. Header: `QuartzCore.framework/Headers/CAFrameRateRange.h`. |
| `preferredFrameLatency: Float` | same | Default 2.0 (measured). Meaning not documented. 1 and 2 are accepted; 0, 0.5 and 3 silently stay 2.0 (measured). 1 vs 2 changed no timing in our test (measured). |
| `isPaused` | `paused` | |
| `CAMetalDisplayLinkDelegate.metalDisplayLink(_:needsUpdate:)` | `-metalDisplayLink:needsUpdate:` | The only delegate method. |
| `CAMetalDisplayLink.Update` | `CAMetalDisplayLinkUpdate` | `drawable: CAMetalDrawable`, `targetTimestamp`, `targetPresentationTimestamp` (both `CFTimeInterval`, host seconds, same clock as `CACurrentMediaTime()`). |

Rules and gotchas:
- Run the link on its own thread (QoS `.userInteractive`, its own `RunLoop`, mode `.default`). The main run loop also works (measured) but the project bans blocking main.
- Render into `update.drawable` only. Do not also call `layer.nextDrawable()` (mixing is not tested).
- **`present(atTime:)` and `present(afterMinimumDuration:)` are forbidden with a display link.** Both raise `CAMetalDrawableInvalidOperation` ("-presentAtTime should not be called when using CAMetalDisplayLink.") and abort the process (measured). Use plain `commandBuffer.present(drawable)`. Timing is chosen by which callback you present in.
- Returning from a callback without presenting its drawable is fine. The previous frame stays on screen (measured: 3718 of 7437 callbacks skipped, no error).
- Timestamps (measured): `targetPresentationTimestamp - targetTimestamp` = 33.33 ms at both 60 and 120 Hz link rates. Callback time to `targetPresentationTimestamp` = 41.6 ms with a 120 Hz link, 49.9 ms with a 60 Hz link. That lead is the presenter's latency floor. Measure it at run time and report it. Never hard-code it.
- 120 Hz ProMotion (measured): a 60 Hz link `(60, 60, 60)` gave steady 16.67 ms presents, but every present landed 8.34 ms after `targetPresentationTimestamp` (3 runs of 3). A 120 Hz link presenting in every second callback landed 0.01 ms from target when on the right callback parity and 8.33 ms late on the wrong one (3 of 4 runs started wrong). So: run the link at the display's maximum rate, present in every second callback, and phase-lock: after 8 presents in a row with `presentedTime - targetPresentationTimestamp > 4 ms`, shift to the other parity and count `parityFlips`. With the lock, 6 runs of 6 ended at 0.00 ms error and 41.6 ms callback-to-glass.
- Presenting in every 120 Hz callback: half the drawables came back with `presentedTime == 0` (measured, conditions in 2.6). Do not present 120 times per second.
- Not documented and not measured: behaviour in a full-screen window, with Low Power Mode off, on an external display, across sleep/wake or display reconfiguration.

### 2.2 CAMetalLayer - `QuartzCore.framework/Headers/CAMetalLayer.h`
Swift and Obj-C property names are the same.

| Property | Value | Why (header text unless marked) |
|---|---|---|
| `device` | the one `MTLDevice` | "On macOS this defaults to nil and must be set explicitly before asking for the first drawable." |
| `pixelFormat` | `.bgra8Unorm` | Only `bgra8Unorm` and `bgra8Unorm_sRGB` are listed as supported. The shader writes gamma-encoded values, so not `_sRGB`. |
| `framebufferOnly` | `true` | Recommended value; display-optimised. Consequence: the scaler cannot write into the drawable (it needs `.shaderRead`, see 2.4), so scale into your own texture and draw that. |
| `drawableSize` | screen frame x `backingScaleFactor` | Set it yourself, in pixels. |
| `displaySyncEnabled` | `true` | Default. Never turn off (tearing). |
| `maximumDrawableCount` | `2` | Range is [2, 3]; other values throw. Measured without a display link: 2 drawables = 40.2 ms glass latency, 3 = 56.8 ms. |
| `presentsWithTransaction` | `false` | Default. `true` ties presents to CATransaction commits. |
| `colorspace` | `CGColorSpace(name: CGColorSpace.sRGB)` | `nil` means no colour matching, which shows BT.709 primaries as display P3 (oversaturated). sRGB vs `CGColorSpace.itur_709` is an estimate; keep it a named setting and compare against the TV. |
| `isOpaque` | `true` | Default for CAMetalLayer. |

AppKit: use a borderless `NSWindow` at `screen.frame`, `level = .mainMenu + 1`, black background. Subclass it to return `true` from `canBecomeKey` or it gets no key events. Make the view layer-hosting: set `view.layer = metalLayer` first, then `view.wantsLayer = true`. Do not use native full screen (`toggleFullScreen`): not tested, and it adds a Space animation. "Direct to display" is in no header; whether we get it is not verified.
Display mode (measured): this Mac currently runs the scaled mode 2056x1329 pt at 2x = 4112x2658 backing pixels on the 3456x2234 panel. A 3456x1944 picture is pixel-exact only in the mode 1728x1117 pt (3456x2234 px, offered at 120 Hz). Print `NSScreen` frame, `backingScaleFactor`, `maximumFramesPerSecond`, `minimumRefreshInterval`, `displayUpdateGranularity` (`AppKit.framework/Headers/NSScreen.h`) at start-up and log them. Do not change the display mode without the user's say-so. `safeAreaInsets.top` is 38 pt now; the centred 16:9 picture starts 86 pt down, clear of the notch.

### 2.3 CVMetalTextureCache - `CoreVideo.framework/Headers/CVMetalTextureCache.h`, `CVMetalTexture.h`
C functions, same names in Swift and Obj-C.
- `CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)` once.
- Per frame: `CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .r8Unorm, 1920, 1080, 0, &lumaRef)` and `(..., .rg8Unorm, 960, 540, 1, &chromaRef)`. Then `CVMetalTextureGetTexture(ref)` returns `MTLTexture?`. Check both `CVReturn` values.
- Header: "Clients should retain CVMetalTexture objects until they are done using the images in them." Hold both refs in a small preallocated ring until the GPU has finished that frame.
- Header: `CVMetalTextureCacheFlush(cache, 0)` "must be made periodically". Call it once per second, not per frame.
- The pixel buffer must be IOSurface-backed: without an IOSurface the call fails with -6660 (measured). Set `kCVPixelBufferMetalCompatibilityKey: true` (`CVPixelBuffer.h`) on every pool you create. A 1920x1080 `420v` IOSurface buffer made without that key also gave both plane textures (measured, this Mac), so native capture buffers, which cannot carry the key, are accepted; not tested on live Elgato buffers. Header: choosing a matching Metal pixel format is "the developer's responsibility".
- Format `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ('420v'): luma 16-235, chroma 16-240. Plane 1 is interleaved Cb, Cr -> `.r` = Cb, `.g` = Cr.
- Exact matrix, 8-bit video range BT.709 to full-range R'G'B', inputs are the sampled values in 0...1:
  `y = Y - 16/255`, `cb = Cb - 128/255`, `cr = Cr - 128/255`
  `R = 1.164384*y + 1.792741*cr`
  `G = 1.164384*y - 0.213249*cb - 0.532909*cr`
  `B = 1.164384*y + 2.112402*cb`
  (1.164384 = 255/219; 1.792741 = 1.5748*255/224; 2.112402 = 1.8556*255/224; 0.213249 and 0.532909 = 0.187324 and 0.468124 times 255/224.) Clamp to 0...1. Measured: 0 difference in 8-bit steps against vImage `kvImage_YpCbCrToARGBMatrix_ITU_R_709_2` on 8 colour bars.
- If a buffer's `kCVImageBufferYCbCrMatrixKey` attachment is not `ITU_R_709_2`, increment a counter and log once. Do not silently use another matrix.

### 2.4 MetalFX spatial scaler - `MetalFX.framework/Headers/MTLFXSpatialScaler.h` (macOS 13+)
| Swift | Obj-C | Notes |
|---|---|---|
| `MTLFXSpatialScalerDescriptor()` | same class | Fields: `colorTextureFormat`, `outputTextureFormat`, `inputWidth`, `inputHeight`, `outputWidth`, `outputHeight`, `colorProcessingMode`. |
| `MTLFXSpatialScalerDescriptor.supportsDevice(_:)` | `+supportsDevice:` | Check before creating. |
| `descriptor.makeSpatialScaler(device:)` | `-newSpatialScalerWithDevice:` | Returns nil on failure. Create once. |
| `scaler.colorTexture`, `outputTexture`, `inputContentWidth`, `inputContentHeight` | same | Set once if the textures never change. |
| `scaler.colorTextureUsage`, `outputTextureUsage` | same | Minimum usage bits your textures must have. Read them, do not hard-code. Measured for bgra8Unorm on this GPU: input `.shaderRead`, output `[.shaderRead, .renderTarget]`. |
| `scaler.encode(commandBuffer:)` | `-encodeToCommandBuffer:` | Call between render passes, never while an encoder is open. |
- Use 1920x1080 -> 3456x1944, both `.bgra8Unorm`, `colorProcessingMode = .perceptual` (the default; header: "perceptual color space (sRGB)"). `.linear` and `.hdr` are wrong for gamma-encoded 8-bit input.
- Header: the output texture must have `storageMode = .private`.
- The input texture also needs `.renderTarget` because the convert pass draws into it.

### 2.5 Presenting and measuring - `Metal.framework/Headers/MTLDrawable.h`, `MTLCommandBuffer.h`
| Swift | Obj-C | Notes |
|---|---|---|
| `commandBuffer.present(_:)` | `-presentDrawable:` | The only present call allowed with the display link. |
| `drawable.addPresentedHandler { d in }` | `-addPresentedHandler:` | Block runs on an arbitrary thread after the frame is shown. Add it before commit. |
| `drawable.presentedTime` | `presentedTime` | Host seconds. Header: "Returns 0 if a frame has not been presented or has been skipped." Count zeros as `skippedByDisplay`. |
| `drawable.drawableID` | `drawableID` | Increments per drawable of one layer. |
| `commandBuffer.gpuStartTime`, `gpuEndTime` | `GPUStartTime`, `GPUEndTime` | Host seconds; read in `addCompletedHandler`. GPU time = end - start. It includes waiting behind other GPU users. |
- All pacing statistics come from `presentedTime`. Callback times are not evidence of what reached the screen.
- The two handler blocks are heap-allocated by the API on every frame. That is the only per-frame allocation allowed in this area.

### 2.6 Measured baseline (2026-11-19, `probes/present_probe`)
Conditions for every row: under load (6 to 15 cliprift ffmpeg processes, load average 4 to 18), **Low Power Mode on**, small composited window (432x279 pt), drawable 4112x2658, link on its own thread. Not full screen. Treat as a floor to beat, not as the target.

| What | Measured | Flags |
|---|---|---|
| Callback-to-glass, 120 Hz link, every 2nd callback, phase-locked | 41.58 ms p50, 41.65 ms p99 | `--link-hz 120 --present-every 2` |
| Same, 60 Hz link | 49.9 ms lead + 8.34 ms late = 58.2 ms | `--link-hz 60` |
| No display link, `nextDrawable()` loop, 2 / 3 drawables | 40.2 ms / 56.8 ms | `--mode next [--drawables 3]` |
| Present intervals within 16.67 +- 2 ms, four 60 s runs on recorded footage | 99.94 %, 99.72 %, 99.47 %, 99.94 %; glitches 2, 10, 19, 2 | `--seconds 62 --video ...` |
| GPU time: convert + final pass only | 0.63 ms p50 | `--scaler 0 --hud 0` |
| GPU time: convert + scaler + final pass (5 runs) | 3.9 to 4.8 ms p50, 4.1 to 6.1 ms p99 | `--hud 0` |
| GPU time: the same plus HUD (5 runs) | 4.5 to 4.7 ms p50, 4.9 to 9.2 ms p99 | `--hud 1` |
| Callback CPU time | 0.18 to 0.40 ms p50, 0.61 to 0.68 ms p99 (the two saved runs in `probes/out/present_probe-60s-hud*-underload.txt`) | |
The run-to-run spread is large under this load. The glitch limit and the 4 ms GPU limit are **not met** by this baseline in these conditions.

### 2.7 HUD
Working reference: `final class HUD` and the HUD block of `render` in `probes/present_probe.swift` (compiled and run).
- Draw it in the final render pass, after the picture, with the viewport reset to the full drawable.
- Text: `CTLineCreateWithAttributedString` + `CTLineDraw` (`CoreText.framework/Headers/CTLine.h`) into a preallocated `CGContext` (`premultipliedFirst | byteOrder32Little` = BGRA), then `texture.replace(region:mipmapLevel:withBytes:bytesPerRow:)` (`-replaceRegion:mipmapLevel:withBytes:bytesPerRow:`, `MTLTexture.h`). At most 4 times per second, on a utility queue, never on the present thread. Use two textures and swap an `Atomic<Int>` index (`import Synchronization`, macOS 15+). Blend premultiplied: source `.one`, destination `.oneMinusSourceAlpha`.
- Frame-time graph: one `.lineStrip` draw from a preallocated shared `MTLBuffer` of 240 `SIMD2<Float>` points, rewritten each frame from the trace-record ring.
- Toggle: `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` flips an `Atomic<Bool>`. The present thread only reads it.
- The HUD shows numbers from trace records only. It computes nothing of its own.

## 3. Verified example
Type-checked exactly as printed (extracted from this file) and also run for 8 s with a 60 fps producer:
```
xcrun swiftc -typecheck -swift-version 5 -warnings-as-errors -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 example.swift
```
Result: exit 0, no output, zero warnings (Swift 6.4.2, target arm64-apple-macos27.0, no need to lower it). Run result: `callbacks=957 shown=466 duplicate=8 dropped=1 late=10 early=1 skippedByDisplay=4 renderFailures=0 parityFlips=1` (measured, same conditions as 2.6; the duplicates and lates are the first 0.3 s before the phase lock settles; the one drop and one early were not investigated).
The HUD symbols in 2.7 are proven by `probes/present_probe.swift`, which builds and runs with the command in its first comment.

```swift
import AppKit
import Metal
import MetalFX
import QuartzCore
import CoreVideo
import os

struct ExampleFrame { let pixelBuffer: CVPixelBuffer; let targetTime: CFTimeInterval }   // example only; real type: PLAN.md
enum PresentError: Error { case noDevice, textureCache(CVReturn), scalerUnsupported, scalerNil, texture, shaderFunction(String) }

struct FrameRing {   // pure logic: belongs in FrameGenCore with unit tests
    var slots = [ExampleFrame?](repeating: nil, count: 8), next = 0, lastShown = -Double.infinity
    /// Returns true when it overwrote a frame that was never shown (count it as dropped).
    mutating func push(_ f: ExampleFrame) -> Bool {
        let lost = slots[next].map { $0.targetTime > lastShown } ?? false
        slots[next] = f; next = (next + 1) % slots.count
        return lost
    }
    /// Newest frame with lastShown < targetTime <= deadline, and how many older unshown frames it skips.
    mutating func pick(deadline: CFTimeInterval) -> (frame: ExampleFrame, dropped: Int)? {
        var best: ExampleFrame?, due = 0
        for case let f? in slots where f.targetTime > lastShown && f.targetTime <= deadline {
            due += 1
            if best.map({ f.targetTime > $0.targetTime }) ?? true { best = f }
        }
        guard let b = best else { return nil }
        lastShown = b.targetTime
        return (b, due - 1)
    }
}
struct PresentState {
    var ring = FrameRing(), callbacks = 0, parity = 0, lateRun = 0, parityFlips = 0
    var shown = 0, duplicate = 0, dropped = 0, late = 0, early = 0, skippedByDisplay = 0, renderFailures = 0
}

let exampleShaders = """
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut vsRect(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {   // rect = x, y, w, h in NDC; triangle strip
    float2 p = float2(vid & 1, vid >> 1);
    VOut o; o.pos = float4(rect.xy + p * rect.zw, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
}
fragment float4 fsConvert(VOut in [[stage_in]], texture2d<float> luma [[texture(0)]], texture2d<float> chroma [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 ycbcr = float3(luma.sample(s, in.uv).r, chroma.sample(s, in.uv).rg) - float3(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0);
    const float3x3 m = float3x3(float3(1.164384, 1.164384, 1.164384), float3(0.0, -0.213249, 2.112402), float3(1.792741, -0.532909, 0.0));
    return float4(saturate(m * ycbcr), 1.0);
}
fragment float4 fsTex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return t.sample(s, in.uv);
}
"""

final class ExamplePresenter: NSObject, CAMetalDisplayLinkDelegate {
    static let inW = 1920, inH = 1080, outW = 3456, outH = 1944
    let layer = CAMetalLayer()
    let state = OSAllocatedUnfairLock(uncheckedState: PresentState())
    private let queue: MTLCommandQueue, cache: CVMetalTextureCache, scaler: MTLFXSpatialScaler
    private let rgbTex: MTLTexture, outTex: MTLTexture, convertPSO: MTLRenderPipelineState, blitPSO: MTLRenderPipelineState
    private let slotEvery: Int
    private var link: CAMetalDisplayLink?
    private var fullRect = SIMD4<Float>(-1, -1, 2, 2)
    private var held = [(CVMetalTexture, CVMetalTexture)?](repeating: nil, count: 4), heldIndex = 0   // render thread only

    init(screen: NSScreen) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw PresentError.noDevice }
        self.queue = queue
        slotEvery = max(1, screen.maximumFramesPerSecond / 60)   // 120 Hz panel: one present slot per 2 callbacks
        var c: CVMetalTextureCache?
        let r = CVMetalTextureCacheCreate(nil, nil, device, nil, &c)
        guard r == kCVReturnSuccess, let c else { throw PresentError.textureCache(r) }
        cache = c
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { throw PresentError.scalerUnsupported }
        let sd = MTLFXSpatialScalerDescriptor()
        sd.colorTextureFormat = .bgra8Unorm; sd.outputTextureFormat = .bgra8Unorm
        sd.inputWidth = Self.inW; sd.inputHeight = Self.inH; sd.outputWidth = Self.outW; sd.outputHeight = Self.outH
        sd.colorProcessingMode = .perceptual   // input is gamma-encoded R'G'B' in 0...1
        guard let scaler = sd.makeSpatialScaler(device: device) else { throw PresentError.scalerNil }
        func tex(_ w: Int, _ h: Int, _ usage: MTLTextureUsage) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = usage; d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw PresentError.texture }
            return t
        }
        rgbTex = try tex(Self.inW, Self.inH, scaler.colorTextureUsage.union([.renderTarget, .shaderRead]))
        outTex = try tex(Self.outW, Self.outH, scaler.outputTextureUsage.union(.shaderRead))
        scaler.inputContentWidth = Self.inW; scaler.inputContentHeight = Self.inH
        scaler.colorTexture = rgbTex; scaler.outputTexture = outTex
        self.scaler = scaler
        let lib = try device.makeLibrary(source: exampleShaders, options: nil)
        func pso(_ fs: String) throws -> MTLRenderPipelineState {
            guard let v = lib.makeFunction(name: "vsRect"), let f = lib.makeFunction(name: fs) else { throw PresentError.shaderFunction(fs) }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = v; d.fragmentFunction = f; d.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: d)
        }
        convertPSO = try pso("fsConvert"); blitPSO = try pso("fsTex")
        super.init()
        layer.device = device; layer.pixelFormat = .bgra8Unorm; layer.framebufferOnly = true
        layer.displaySyncEnabled = true; layer.presentsWithTransaction = false; layer.maximumDrawableCount = 2
        layer.isOpaque = true; layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.contentsScale = screen.backingScaleFactor
        layer.drawableSize = CGSize(width: screen.frame.width * screen.backingScaleFactor, height: screen.frame.height * screen.backingScaleFactor)
    }

    /// Call after the layer's view is in a window that is on screen.
    func start(screen: NSScreen) {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.delegate = self   // weak: the caller keeps the presenter alive
        let hz = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: hz, maximum: hz, preferred: hz)
        link.preferredFrameLatency = 1
        self.link = link
        let thread = Thread { link.add(to: .current, forMode: .default); RunLoop.current.run() }
        thread.name = "present"; thread.qualityOfService = .userInteractive
        thread.start()
    }
    func stop() { link?.invalidate(); link = nil }   // exactly once per link: a second invalidate() crashes

    func enqueue(_ f: ExampleFrame) { state.withLockUnchecked { if $0.ring.push(f) { $0.dropped += 1 } } }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let slotTarget = update.targetPresentationTimestamp
        let pick: ExampleFrame? = state.withLockUnchecked { s in
            s.callbacks += 1
            guard (s.callbacks + s.parity) % slotEvery == 0 else { return nil }                 // not a present slot
            guard let p = s.ring.pick(deadline: slotTarget) else { s.duplicate += 1; return nil } // nothing new: last frame stays up
            s.dropped += p.dropped
            return p.frame
        }
        guard let frame = pick else { return }   // leaving update.drawable unpresented is fine (measured)
        var yRef: CVMetalTexture?, cRef: CVMetalTexture?
        let r0 = CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame.pixelBuffer, nil, .r8Unorm, Self.inW, Self.inH, 0, &yRef)
        let r1 = CVMetalTextureCacheCreateTextureFromImage(nil, cache, frame.pixelBuffer, nil, .rg8Unorm, Self.inW / 2, Self.inH / 2, 1, &cRef)
        let drawable = update.drawable
        let conv = MTLRenderPassDescriptor(), final = MTLRenderPassDescriptor()
        conv.colorAttachments[0].texture = rgbTex; conv.colorAttachments[0].loadAction = .dontCare
        final.colorAttachments[0].texture = drawable.texture; final.colorAttachments[0].loadAction = .clear   // black bars
        guard r0 == kCVReturnSuccess, r1 == kCVReturnSuccess, let yRef, let cRef,
              let yTex = CVMetalTextureGetTexture(yRef), let cTex = CVMetalTextureGetTexture(cRef),
              let cb = queue.makeCommandBuffer(), let e1 = cb.makeRenderCommandEncoder(descriptor: conv)
        else { state.withLockUnchecked { $0.renderFailures += 1 }; return }
        held[heldIndex] = (yRef, cRef); heldIndex = (heldIndex + 1) & 3   // keep both alive until the GPU is done with them
        e1.setRenderPipelineState(convertPSO)
        e1.setVertexBytes(&fullRect, length: 16, index: 0)
        e1.setFragmentTexture(yTex, index: 0); e1.setFragmentTexture(cTex, index: 1)
        e1.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e1.endEncoding()
        scaler.encode(commandBuffer: cb)   // between passes; real and generated frames both go convert -> scaler -> final pass
        guard let e2 = cb.makeRenderCommandEncoder(descriptor: final) else { state.withLockUnchecked { $0.renderFailures += 1 }; return }
        let dw = Double(drawable.texture.width), dh = Double(drawable.texture.height), ph = dw * 9 / 16
        e2.setViewport(MTLViewport(originX: 0, originY: (dh - ph) / 2, width: dw, height: ph, znear: 0, zfar: 1))   // 16:9, centred
        e2.setRenderPipelineState(blitPSO)
        e2.setVertexBytes(&fullRect, length: 16, index: 0)
        e2.setFragmentTexture(outTex, index: 0)
        e2.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        e2.endEncoding()   // HUD draws go before this line, in this same pass

        let frameTarget = frame.targetTime, state = self.state
        drawable.addPresentedHandler { d in   // arbitrary thread
            let t = d.presentedTime           // write slotTarget and t into the frame's trace record here
            state.withLockUnchecked { s in
                guard t > 0 else { s.skippedByDisplay += 1; return }   // 0 = never reached the screen
                s.shown += 1
                if t - frameTarget > 1.0 / 60 + 0.002 { s.late += 1 } else if t < frameTarget - 0.002 { s.early += 1 }
                s.lateRun = (t - slotTarget > 0.004) ? s.lateRun + 1 : 0   // phase lock: 8 late in a row -> use the other callbacks
                if s.lateRun >= 8 { s.lateRun = 0; s.parity += 1; s.parityFlips += 1 }
            }
        }
        cb.present(drawable)   // plain present only; present(atTime:) / present(afterMinimumDuration:) raise with a display link
        cb.commit()
    }
}
```
Counter meanings: `duplicate` = a present slot with no new frame due (the old frame stays, the present interval becomes 33 ms). `dropped` = a frame skipped because a newer one was also due, or overwritten in the ring unshown. `late` = shown more than one slot (16.67 ms + 2 ms) after its target time. `early` = shown more than 2 ms before its target time. `skippedByDisplay` = presented but `presentedTime == 0`. Use these definitions unless PLAN.md defines them differently.

## 4. Project conventions
- App code is Swift (language mode 5), one SwiftPM package at the repo root: library target `FrameGenCore` (pure logic: cadence detector, pacing math, statistics; no hardware, fully unit-tested), executable target `FrameGen` (capture, VideoToolbox, Metal, audio, HUD), tests in `Tests/FrameGenCoreTests`. No third-party dependencies.
- Probes and measurement tools are single files under `probes/` (Obj-C or Swift), each with the build command in its first comment.
- Build: `swift build -c release`. Tests: `swift test`. App bundle: `scripts/make-app.sh` (wraps the binary in build/GTA6FrameGen.app with an Info.plist carrying NSCameraUsageDescription and NSMicrophoneUsageDescription).
- One timebase: host time in seconds (mach / CACurrentMediaTime). Capture timestamps are converted to host time once, at capture.
- Every frame carries a trace record (capture time, unique/duplicate verdict, interpolation start/end, scaler end, target present time, actual present time). The HUD and the CSV logs under `runs/` read only from these records.
- Hot path: no heap allocation per frame (CVPixelBufferPool, preallocated rings), no CPU copy of pixel data (IOSurface-backed buffers, CVMetalTextureCache), no locks held across a VideoToolbox or Metal call, no sleeping for pacing, never block the main thread.

## 5. Banned
Placeholders; TODO or FIXME stubs; "simplified version"; functions that return hard-coded or fake data; synthetic numbers presented as measured; skipped error handling; silent fallbacks (every fallback increments a named counter and is logged once); catch-all `try?` on the hot path; claiming something was run without pasting the output; changing a public interface from PLAN.md without saying so; installing anything; touching OBS, ~/Developer/cliprift-studio or the ps5audio helper.

## 6. Interfaces
See PLAN.md, section "Interfaces". Match them exactly.

## 7. How to build and test
```
cd ~/Developer/ps5-framegen
swift build -c release          # must print no warning for files you touched
swift test
# Present probe (reference numbers, no app code needed). Build command is the first comment of the file:
xcrun swiftc -O -swift-version 5 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 probes/present_probe.swift -o probes/present_probe
# Recorded footage, Elgato not needed. Small window (does not take over the screen):
probes/present_probe --seconds 62 --link-hz 120 --present-every 2 --hud 1 --video "<recording>.mp4" --start 600
# Full screen, the real configuration (covers the whole display; h = HUD, q = quit). Ask the user before running it:
probes/present_probe --seconds 600 --link-hz 120 --present-every 2 --window full --video "<recording>.mp4" --start 600
# State of the machine, paste next to every timing table:
uptime; pmset -g | grep lowpowermode; pgrep -x ffmpeg | wc -l
```
- The app itself is run on recorded footage through the file-replay input defined in PLAN.md, on the same file. Do not invent a new flag for it.
- The probe's AVAssetReader calls (`add`, `startReading`, `copyNextSampleBuffer`) are deprecated in macOS 27 and warn. That is accepted in the probe only. App code must build with zero warnings.
- The recording has a webcam overlay at x >= 83 %, y >= 77 %. It does not matter for pacing tests.
- Pure logic (frame pick rule, counters, phase lock, interval statistics) goes in `FrameGenCore` and is tested with `swift test`, no GPU. Test at least: nothing due, one due, two due (one dropped), ring overwrite, 8 late presents flip parity, 7 do not.
- Never run with the Elgato as "tested" unless it was plugged in. Write "not tested" and the command to run later.
- Do not kill, renice or wait out the cliprift ffmpeg jobs. Measure under load and say so.
- Before a definition-of-done run, ask the user to turn Low Power Mode off and to say which display scaling is set. Do not change either yourself.

## 8. Definition of done
- 10 min run: >= 99.5 % of **content intervals** within the mode's interval +- 2 ms. A content interval is the difference between the non-zero `presentedTime` values of two consecutive slots whose `shown` content ids differ, read from `slots.csv`. The mode's interval is 16.68 ms for framegen and for a native 60 source, 33.37 ms for real-only on doubled input. First 2 s excluded. Not callback times, and not drawable-to-drawable times.
- <= 1 pacing glitch (one content interval outside that band) in **every** rolling 15 s window of the run.
- GPU time per frame (`gpuEndTime - gpuStartTime` of the frame's command buffer) at 3456x1944 output: bilinear path (convert + scale in one pass) + HUD p99 <= 2 ms; MetalFX path + HUD: report p50/p99, target p99 <= 8 ms. Measured so far under load: bilinear 0.63 ms p50, MetalFX alone 3.4 ms p50 and 4.5 to 9 ms p99.
- Pacing is judged on **content** intervals (time between presentations of different content ids), in every rolling 15 s window, from `slots.csv`. Re-presenting the same image is `held` and never counts as a new interval.
- Accounting: at exit `enqueued == shown + dropped + cancelled + unpresentedAtExit` and `slotsInGrid == shown + held + skipped`. `cancelTooLate` is a flag on items that were cancelled after commit: they are `shown`, counted once. A run that breaks either equation fails. `dropped` <= 0.1 % of `enqueued`. A slot that re-presents the previous image counts as `held`, never as `shown`.
- The 10 min run uses `FrameGen --replay "<recording>" --start 2904` (or live capture) and its numbers come from `runs/<date-time>/slots.csv` and `items.csv` through `tools/stats.py`.
- Callback-to-glass time (presentedTime minus the callback's entry time) p50 and p99 are reported for every run, with the display mode and `pmset -g | grep lowpowermode`.
- HUD on/off does not change pacing statistics: alternate HUD on and off in 60 s blocks inside one run, report both sets, both must meet the two pacing limits.
- Counters `shown`, `held`, `skipped`, `dropped`, `cancelled`, `cancelTooLate`, `renderFailures` are reported at the end of every run. The presenter has no `late`, `early` or `parityFlips` counters of its own: timing belongs to the Conductor.
- Builds with zero warnings in the files touched. Tests pass. The output format in section 9 is followed.
- If a limit is missed, say so with the measured number and the machine state. Do not change the measurement to pass.

## 9. Required output format from the implementer
(a) Full contents of every file created, or a unified diff of every file edited.
(b) The exact build and test commands, with their real output pasted.
(c) A measured-numbers table (value, how it was measured, machine state: load, Low Power Mode, window mode).
(d) A list titled "Not finished". Write "nothing" only if true.
