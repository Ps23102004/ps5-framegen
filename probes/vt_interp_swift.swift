// vt_interp_swift: what VTLowLatencyFrameInterpolation does when driven from Swift (the sync call is unavailable in Swift).
// Part 1 prints limits, the resolved pixel-buffer attributes, and what each failure case returns.
// Part 2 times midpoint interpolation on recorded gameplay three ways: completion handler, async/await, Metal command buffer.
// Build: xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 vt_interp_swift.swift -o vt_interp_swift
//        (prints warnings: deprecated AVAssetReader calls used to read the test file, and blocking waits in top-level async code.
//         Both are probe-only shortcuts and do not affect the result.)
// Usage: ./vt_interp_swift <video> <start s> <seconds per mode> [width=1920] [height=1080] [risky1|risky2]
//   risky1: endSession with a call in flight, then process after endSession. risky2: startSession again on the same object, then process.
//   Both ended in SIGSEGV on macOS 27.2.1 (see out/vt_interp_swift.txt).
import AVFoundation
import CoreVideo
import Metal
import QuartzCore
import VideoToolbox

func nowMs() -> Double { CACurrentMediaTime() * 1000 }
func fourCC(_ v: OSType) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "\(v)" }
func describe(_ e: Error?) -> String {
    guard let e = e as NSError? else { return "nil" }
    let name = e.domain == VTFrameProcessorErrorDomain ? (VTFrameProcessorError.Code(rawValue: e.code).map { " (\($0))" } ?? "") : ""
    return "domain=\(e.domain) code=\(e.code)\(name) \"\(e.localizedDescription)\""
}
func queueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

setvbuf(stdout, nil, _IONBF, 0) // so a crash does not swallow earlier lines
let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: vt_interp_swift <video> <start s> <seconds per mode> [width] [height]"); exit(2) }
let W = args.count > 4 ? Int(args[4])! : 1920, H = args.count > 5 ? Int(args[5])! : 1080
let seconds = Double(args[3])!

// ---------- Part 1: limits, attributes, failure cases ----------
print("isSupported: \(VTLowLatencyFrameInterpolationConfiguration.isSupported)")
print("maximumDimension(forSpatialScaleFactor: 1) = \(String(describing: VTLowLatencyFrameInterpolationConfiguration.maximumDimension(forSpatialScaleFactor: 1)))  maximumPixelCount = \(String(describing: VTLowLatencyFrameInterpolationConfiguration.maximumPixelCount(forSpatialScaleFactor: 1)))")
guard let cfg = VTLowLatencyFrameInterpolationConfiguration(frameWidth: W, frameHeight: H, numberOfInterpolatedFrames: 1) else { print("config nil"); exit(1) }
print("supportedPixelFormats: \(cfg.supportedPixelFormats.map(fourCC))")
print("sourcePixelBufferAttributes: \(cfg.sourcePixelBufferAttributes)")
print("destinationPixelBufferAttributes: \(cfg.destinationPixelBufferAttributes)")

func resolved(_ required: [String: Any]) -> [String: Any] {
    let mine: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                               kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                               kCVPixelBufferMetalCompatibilityKey as String: true]
    var out: CFDictionary?
    let st = CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault, [required, mine] as CFArray, &out)
    guard st == kCVReturnSuccess, let d = out as? [String: Any] else { print("resolve failed \(st)"); exit(1) }
    return d
}
func makePool(_ attrs: [String: Any], min: Int) -> CVPixelBufferPool {
    var pool: CVPixelBufferPool?
    let st = CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: min] as CFDictionary, attrs as CFDictionary, &pool)
    guard st == kCVReturnSuccess, let p = pool else { print("pool failed \(st)"); exit(1) }
    return p
}
func take(_ pool: CVPixelBufferPool) -> CVPixelBuffer {
    var b: CVPixelBuffer?
    let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &b)
    guard st == kCVReturnSuccess, let buf = b else { print("pool empty \(st)"); exit(1) }
    return buf
}
func plainBuffer(_ format: OSType, ioSurface: Bool) -> CVPixelBuffer {
    var b: CVPixelBuffer?
    let attrs: [String: Any] = ioSurface ? [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] : [:]
    CVPixelBufferCreate(kCFAllocatorDefault, W, H, format, attrs as CFDictionary, &b)
    return b!
}
let srcAttrs = resolved(cfg.sourcePixelBufferAttributes), dstAttrs = resolved(cfg.destinationPixelBufferAttributes)
print("resolved source attributes: \(srcAttrs)")
let srcPool = makePool(srcAttrs, min: 4), dstPool = makePool(dstAttrs, min: 3)

/// Runs one process call through the completion handler and waits for it (probe only; the app never waits).
func runOnce(_ p: VTFrameProcessor, _ prm: VTFrameProcessorParameters) -> (err: Error?, ms: Double, callMs: Double, main: Bool, queue: String, timedOut: Bool) {
    let sem = DispatchSemaphore(value: 0)
    var err: Error?, tDone = 0.0, main = false, q = ""
    let t0 = nowMs()
    p.process(parameters: prm) { _, e in err = e; tDone = nowMs(); main = Thread.isMainThread; q = queueLabel(); sem.signal() }
    let tCall = nowMs()
    let timedOut = sem.wait(timeout: .now() + 5) == .timedOut
    return (err, tDone - t0, tCall - t0, main, q, timedOut)
}
func params(_ prev: CVPixelBuffer, _ pT: CMTime, _ cur: CVPixelBuffer, _ cT: CMTime, _ dst: CVPixelBuffer, _ dT: CMTime) -> VTLowLatencyFrameInterpolationParameters? {
    guard let fp = VTFrameProcessorFrame(buffer: prev, presentationTimeStamp: pT),
          let fs = VTFrameProcessorFrame(buffer: cur, presentationTimeStamp: cT),
          let fd = VTFrameProcessorFrame(buffer: dst, presentationTimeStamp: dT) else { return nil }
    return VTLowLatencyFrameInterpolationParameters(sourceFrame: fs, previousFrame: fp, interpolationPhase: [0.5], destinationFrames: [fd])
}
let t0 = CMTime(value: 0, timescale: 60000), t1 = CMTime(value: 1001, timescale: 60000), t2 = CMTime(value: 2002, timescale: 60000)

print("\n== failure cases")
do { // too large: does Swift's `try` throw?
    let big = VTLowLatencyFrameInterpolationConfiguration(frameWidth: 2560, frameHeight: 1440, numberOfInterpolatedFrames: 1)!
    let p = VTFrameProcessor()
    do { try p.startSession(configuration: big); print("2560x1440 startSession: DID NOT THROW") } catch { print("2560x1440 startSession: threw \(describe(error))") }
    func big420v() -> CVPixelBuffer { var b: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 2560, 1440, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &b); return b! }
    if let prm = params(big420v(), t0, big420v(), t2, big420v(), t1) { let r = runOnce(p, prm); print("2560x1440 process after that start: error \(describe(r.err)) timedOut=\(r.timedOut)") } else { print("2560x1440 parameters init returned nil") }
    p.endSession()
}
do { // process without a session
    let p = VTFrameProcessor()
    let r = runOnce(p, params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1)!)
    print("process before startSession: error \(describe(r.err)) timedOut=\(r.timedOut)")
}
let proc = VTFrameProcessor()
let s0 = nowMs()
do { try proc.startSession(configuration: cfg) } catch { print("startSession threw \(describe(error))"); exit(1) }
print("\(W)x\(H) startSession: ok in \(Int(nowMs() - s0)) ms")
do { try proc.startSession(configuration: cfg); print("second startSession on an active session: DID NOT THROW") } catch { print("second startSession on an active session: threw \(describe(error))") }
print("VTFrameProcessorFrame from a buffer without IOSurface: \(VTFrameProcessorFrame(buffer: plainBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioSurface: false), presentationTimeStamp: t0) == nil ? "nil" : "non-nil")")
print("parameters with phase [0.0]: \(VTLowLatencyFrameInterpolationParameters(sourceFrame: VTFrameProcessorFrame(buffer: take(srcPool), presentationTimeStamp: t2)!, previousFrame: VTFrameProcessorFrame(buffer: take(srcPool), presentationTimeStamp: t0)!, interpolationPhase: [0.0], destinationFrames: [VTFrameProcessorFrame(buffer: take(dstPool), presentationTimeStamp: t1)!]) == nil ? "nil" : "non-nil")")
print("parameters with phase [0.25] on a 1-frame config: \(VTLowLatencyFrameInterpolationParameters(sourceFrame: VTFrameProcessorFrame(buffer: take(srcPool), presentationTimeStamp: t2)!, previousFrame: VTFrameProcessorFrame(buffer: take(srcPool), presentationTimeStamp: t0)!, interpolationPhase: [0.25], destinationFrames: [VTFrameProcessorFrame(buffer: take(dstPool), presentationTimeStamp: t1)!]) == nil ? "nil" : "non-nil")")
func tryCase(_ name: String, _ prm: VTLowLatencyFrameInterpolationParameters?) {
    guard let prm = prm else { print("\(name): parameters init returned nil"); return }
    let r = runOnce(proc, prm); print("\(name): error \(describe(r.err)) timedOut=\(r.timedOut) \(String(format: "%.1f ms", r.ms))")
}
tryCase("phase [0.25] processed on a 1-frame config", params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1).flatMap { _ in
    VTLowLatencyFrameInterpolationParameters(sourceFrame: VTFrameProcessorFrame(buffer: take(srcPool), presentationTimeStamp: t2)!, previousFrame: VTFrameProcessorFrame(buffer: take(srcPool), presentationTimeStamp: t0)!, interpolationPhase: [0.25], destinationFrames: [VTFrameProcessorFrame(buffer: take(dstPool), presentationTimeStamp: t1)!]) })
tryCase("good call (pooled buffers, pts 0 < 1 < 2)", params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1))
tryCase("previous pts AFTER source pts", params(take(srcPool), t2, take(srcPool), t0, take(dstPool), t1))
tryCase("all three pts equal", params(take(srcPool), t0, take(srcPool), t0, take(dstPool), t0))
tryCase("pts going backwards vs the previous call", params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1))
tryCase("invalid pts (CMTime.invalid)", params(take(srcPool), .invalid, take(srcPool), .invalid, take(dstPool), .invalid))
tryCase("BGRA source and previous", params(plainBuffer(kCVPixelFormatType_32BGRA, ioSurface: true), t0, plainBuffer(kCVPixelFormatType_32BGRA, ioSurface: true), t2, take(dstPool), t1))
tryCase("420f (full range) source and previous", params(plainBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, ioSurface: true), t0, plainBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, ioSurface: true), t2, take(dstPool), t1))
tryCase("x420 (10-bit) source and previous", params(plainBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, ioSurface: true), t0, plainBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, ioSurface: true), t2, take(dstPool), t1))
tryCase("plain 420v IOSurface buffers, no extended pixels, all three", params(plainBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioSurface: true), t0, plainBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioSurface: true), t2, plainBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, ioSurface: true), t1))
tryCase("BGRA destination", params(take(srcPool), t0, take(srcPool), t2, plainBuffer(kCVPixelFormatType_32BGRA, ioSurface: true), t1))
tryCase("good call again (is the session still alive after the errors?)", params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1))

// ---------- Part 2: timing on recorded gameplay ----------
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
guard let track = try await asset.loadTracks(withMediaType: .video).first else { print("no video track"); exit(1) }
var xfer: VTPixelTransferSession?
VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &xfer)

func lumaMAD(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Double { // mean abs luma difference on a sparse grid, excluding the webcam corner
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let pa = CVPixelBufferGetBaseAddressOfPlane(a, 0)!.assumingMemoryBound(to: UInt8.self), pb = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
    let ra = CVPixelBufferGetBytesPerRowOfPlane(a, 0), rb = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    var sum = 0, n = 0
    for y in stride(from: 0, to: Int(Double(H) * 0.77), by: 8) { for x in stride(from: 0, to: W, by: 8) { sum += abs(Int(pa[y * ra + x]) - Int(pb[y * rb + x])); n += 1 } }
    return Double(sum) / Double(n)
}
func report(_ name: String, _ ms: [Double], extra: String = "") {
    let s = ms.sorted(); guard !s.isEmpty else { print("\(name): no frames"); return }
    func q(_ x: Double) -> Double { s[min(s.count - 1, Int(x * Double(s.count)))] }
    print(String(format: "%@: n %d  p50 %.2f  p95 %.2f  p99 %.2f  max %.2f ms  %@", name, s.count, q(0.5), q(0.95), q(0.99), s.last!, extra))
}
enum Mode: String { case handler = "completion handler", awaitCall = "async/await", commandBuffer = "Metal command buffer" }
let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!

@MainActor func timed(_ mode: Mode, start: Double) async throws {
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: seconds, preferredTimescale: 600))
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
    out.alwaysCopiesSampleData = false; reader.add(out); reader.startReading()
    var ms: [Double] = [], callMs: [Double] = [], fails = 0, n = 0, mains = 0, queues = Set<String>(), mid = 0, checked = 0
    ms.reserveCapacity(4096)
    var prev: CVPixelBuffer?, prevT = CMTime.zero
    var next = nowMs()
    while let sb = out.copyNextSampleBuffer() {
        n += 1; if n % 2 == 0 { continue } // 30 real frames inside 60 Hz
        guard let src = CMSampleBufferGetImageBuffer(sb) else { continue }
        let t = CMSampleBufferGetPresentationTimeStamp(sb)
        let cur = take(srcPool); VTPixelTransferSessionTransferImage(xfer!, from: src, to: cur)
        if let p = prev {
            let dst = take(dstPool)
            guard let prm = params(p, prevT, cur, t, dst, CMTimeMultiplyByRatio(CMTimeAdd(t, prevT), multiplier: 1, divisor: 2)) else { fails += 1; continue }
            next += 33.37; let wait = next - nowMs(); if wait > 0 { usleep(useconds_t(wait * 1000)) } else { next = nowMs() } // one call per real game frame, like the live app
            switch mode {
            case .handler:
                let r = runOnce(proc, prm)
                if r.err != nil || r.timedOut { fails += 1; if fails <= 3 { print("  error \(describe(r.err)) timedOut=\(r.timedOut)") } } else { ms.append(r.ms); callMs.append(r.callMs); if r.main { mains += 1 }; queues.insert(r.queue) }
            case .awaitCall:
                let a = nowMs()
                do { let _: any VTFrameProcessorParameters = try await proc.process(parameters: prm); ms.append(nowMs() - a) } catch { fails += 1; if fails <= 3 { print("  error \(describe(error))") } }
            case .commandBuffer:
                let cb = queue.makeCommandBuffer()!
                let a = nowMs()
                proc.process(with: cb, parameters: prm)
                let enc = nowMs(); cb.commit(); cb.waitUntilCompleted()
                if let e = cb.error { fails += 1; if fails <= 3 { print("  command buffer error \(describe(e))") } } else { ms.append(nowMs() - a); callMs.append(enc - a) }
            }
            if checked < 200, ms.count % 9 == 0 { // is the output really between the two inputs?
                let dp = lumaMAD(dst, p), dc = lumaMAD(dst, cur), pc = lumaMAD(p, cur)
                if pc > 2 { checked += 1; if dp < pc && dc < pc { mid += 1 } }
            }
        }
        prev = cur; prevT = t
    }
    reader.cancelReading()
    report("\(W)x\(H) \(mode.rawValue), paced 33.37 ms, pooled", ms, extra: "fails \(fails)")
    if !callMs.isEmpty { report("    time inside the call itself (before it returns)", callMs) }
    if mode == .handler { print("    handler ran on main thread: \(mains) of \(ms.count); queue labels: \(queues.sorted())") }
    print("    output closer to both inputs than they are to each other (moving frames only): \(mid) of \(checked)")
}
print("\n== timing, \(seconds) s of footage per mode, UNDER LOAD unless the machine is idle")
let start = Double(args[2])!
try await timed(.handler, start: start)
try await timed(.awaitCall, start: start)
try await timed(.commandBuffer, start: start)
try await timed(.handler, start: start)

// ---------- Part 3: session lifecycle ----------
print("\n== lifecycle")
func fillLuma(_ b: CVPixelBuffer, _ v: UInt8) { CVPixelBufferLockBaseAddress(b, []); memset(CVPixelBufferGetBaseAddressOfPlane(b, 0), Int32(v), CVPixelBufferGetBytesPerRowOfPlane(b, 0) * H); CVPixelBufferUnlockBaseAddress(b, []) }
func lumaIsStill(_ b: CVPixelBuffer, _ v: UInt8) -> Bool { CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let p = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self), r = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
    return stride(from: 0, to: H, by: 16).allSatisfy { y in stride(from: 0, to: W, by: 16).allSatisfy { x in p[y * r + x] == v } } }
do { // a processor that was never started reports no error: does it write the destination?
    let p = VTFrameProcessor(), a = take(srcPool), b = take(srcPool), d = take(dstPool)
    fillLuma(a, 40); fillLuma(b, 200); fillLuma(d, 0x55)
    let r = runOnce(p, params(a, t0, b, t2, d, t1)!)
    print("never-started processor: error \(describe(r.err)); destination untouched: \(lumaIsStill(d, 0x55))")
    let d2 = take(dstPool); fillLuma(d2, 0x55)
    let r2 = runOnce(proc, params(a, t0, b, t2, d2, t1)!)
    print("started processor, same inputs: error \(describe(r2.err)); destination untouched: \(lumaIsStill(d2, 0x55))")
}
do { // two calls submitted without waiting
    let sem = DispatchSemaphore(value: 0); var done = [Double](repeating: 0, count: 2); let a = nowMs()
    for i in 0..<2 { proc.process(parameters: params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1)!) { _, e in done[i] = nowMs() - a; if e != nil { print("  in-flight pair error \(describe(e))") }; sem.signal() } }
    sem.wait(); sem.wait()
    print(String(format: "two calls submitted back to back: first done after %.1f ms, second after %.1f ms", done[0], done[1]))
}
proc.endSession()
let proc2 = VTFrameProcessor() // a NEW object: reusing the old one after endSession crashes (see risky2)
do {
    let a = nowMs()
    do { try proc2.startSession(configuration: cfg); print("new VTFrameProcessor after the old one ended: no throw, \(Int(nowMs() - a)) ms") } catch { print("start threw \(describe(error))") }
    for i in 1...3 { let r = runOnce(proc2, params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1)!); print(String(format: "  call %d on the new processor: error %@, %.1f ms", i, describe(r.err), r.ms)) }
}
let risky = args.count > 6 ? args[6] : ""
if risky == "risky1" {
    let sem = DispatchSemaphore(value: 0)
    proc2.process(parameters: params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1)!) { _, e in print("in-flight call when endSession was called: handler ran, error \(describe(e))"); sem.signal() }
    let a = nowMs(); proc2.endSession(); print(String(format: "endSession with one call in flight returned after %.1f ms", nowMs() - a))
    if sem.wait(timeout: .now() + 5) == .timedOut { print("in-flight call when endSession was called: handler NEVER ran (5 s)") }
    print("now calling process after endSession, no restart...")
    print("process after endSession: \(describe(runOnce(proc2, params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1)!).err))")
} else if risky == "risky2" {
    proc2.endSession()
    do { try proc2.startSession(configuration: cfg); print("startSession again on the SAME object after endSession: no throw") } catch { print("restart threw \(describe(error))") }
    print("now calling process on the restarted object...")
    print("process on the restarted object: \(describe(runOnce(proc2, params(take(srcPool), t0, take(srcPool), t2, take(dstPool), t1)!).err))")
} else { proc2.endSession(); print("endSession done (6th argument risky1 or risky2 runs the cases that crash)") }
