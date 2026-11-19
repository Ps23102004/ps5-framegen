# Skill: VideoToolbox frame interpolation (vt-interpolation)

## 1. Purpose and scope
Use this for any task that touches `VTFrameProcessor`: making the midpoint frame between two real 30 fps game frames with `VTLowLatencyFrameInterpolation`, its session lifecycle, its pixel buffers, its errors, and what happens when a generated frame is late or fails.
Not in scope: capture, cadence detection, the MetalFX upscale, presenting. Those have their own skills.
Everything below was read in the macOS 27.2 SDK headers or measured on this Mac (M3 Pro, macOS 27.2.1). Measured numbers are **under load** (unrelated ffmpeg jobs were running). If you state something that is not in this file, open the header first.

## 1a. Decisions from PLAN.md (these win over anything below)
- Names: generation off is called *real-only*; real and generated alternating is *framegen*. Cadence states in code are `locked22`, `native60`, `unknown` (this file's `LOCKED_2_2`, `PASSTHROUGH_60`, `UNKNOWN`). "Passthrough" means only the HDMI cable from the card to the TV.
- Types and signatures: PLAN.md section 6. Example names in this file are for the example only.
- Buffer ownership: PLAN.md section 5 table. Every buffer you receive comes from the app's own pools, never from the capture device.
- Counters: every fallback has a named counter (PLAN.md sections 5 and 5.2). Use those names. Every item and every reservation carries an epoch (PLAN.md section 5, "Epochs").
- Logs: the two ledgers of PLAN.md section 6 (`items.csv`, `slots.csv`) plus `counters.txt` and `run.json` under `runs/<date-time>/`. Acceptance numbers are computed from these files by `tools/stats.py`, never from console prints.
- This skill covers the interpolator only. What the presenter does with a missing or late midpoint is in `skills/metal-present/SKILL.md` and PLAN.md section 5.
- The interpolation size is a parameter (default 1920x1080). 1600x896 and 1280x720 must also work.

## 2. Exact APIs
Headers: `$SDK/System/Library/Frameworks/VideoToolbox.framework/Headers/`, with `SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`.
Swift-only refinements: `$SDK/System/Library/Frameworks/VideoToolbox.framework/Versions/A/Modules/VideoToolbox.swiftmodule/arm64e-apple-macos.swiftinterface`.

| What | Header | Obj-C | Swift |
|---|---|---|---|
| Processor | `VTFrameProcessor.h` | `[VTFrameProcessor new]` | `VTFrameProcessor()` |
| Start | same | `-startSessionWithConfiguration:error:` | `try startSession(configuration:)` |
| Process, blocking | same | `-processWithParameters:error:` | **not available in Swift** (`NS_SWIFT_UNAVAILABLE`) |
| Process, callback | same | `-processWithParameters:completionHandler:` | `process(parameters:completionHandler:)`, also `try await process(parameters:)` returning `any VTFrameProcessorParameters` |
| Process, per output frame | same | `-processWithParameters:frameOutputHandler:` | `process(parameters:)` returning an `AsyncSequence` of `VTFrameProcessorFrame.ReadOnlyFrame` |
| Process inside Metal | same | `-processWithCommandBuffer:parameters:` | `process(with:parameters:)` |
| End | same | `-endSession` | `endSession()` |
| Frame wrapper | `VTFrameProcessorFrame.h` | `-initWithBuffer:presentationTimeStamp:` (nullable) | `VTFrameProcessorFrame(buffer:presentationTimeStamp:)` (failable); `.buffer`, `.presentationTimeStamp` |
| Configuration | `VTFrameProcessor_LowLatencyFrameInterpolation.h` | `-initWithFrameWidth:frameHeight:numberOfInterpolatedFrames:` (nullable) | `VTLowLatencyFrameInterpolationConfiguration(frameWidth:frameHeight:numberOfInterpolatedFrames:)` (failable) |
| Limits (macOS 27.0+) | same | `+maximumDimensionForSpatialScaleFactor:`, `+maximumPixelCountForSpatialScaleFactor:` | `maximumDimension(forSpatialScaleFactor:) -> Int?`, `maximumPixelCount(forSpatialScaleFactor:) -> Int?` |
| Support, formats, buffers | same | `+isSupported`, `frameSupportedPixelFormats`, `sourcePixelBufferAttributes`, `destinationPixelBufferAttributes` | `isSupported`, `supportedPixelFormats: [OSType]`, `sourcePixelBufferAttributes: [String: Any]`, `destinationPixelBufferAttributes` |
| Parameters | same | `-initWithSourceFrame:previousFrame:interpolationPhase:destinationFrames:` (nullable, phases are `NSNumber` floats) | `VTLowLatencyFrameInterpolationParameters(sourceFrame:previousFrame:interpolationPhase:destinationFrames:)` (failable, phases are `[Float]`) |
| Errors | `VTFrameProcessorErrors.h` | `VTFrameProcessorErrorDomain`, `VTFrameProcessorError` | `VTFrameProcessorErrorDomain`, `VTFrameProcessorError.Code` |

Parameter meanings (header):
- `sourceFrame` is the **newer** real frame. `previousFrame` is the older one. Do not swap them.
- `interpolationPhase`: `[0.5]` is the midpoint. With `numberOfInterpolatedFrames: 1` the header says 0.5 is the only available point. Always pass `[0.5]`.
- `destinationFrames`: buffers **you** allocate, one per phase. The processor writes into them.
- Timestamps: pass previous < midpoint < current. The processor did not reject reversed, equal or invalid timestamps (measured), so it will not catch your mistakes.
- After a process call, do not modify the input or output buffers, or their attachments, until the callback runs (header).

Pixel buffers (measured unless marked):
- **Only `420v`** (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`). `420f`, 10-bit `x420` and BGRA inputs, and a BGRA destination, fail in 0.1 ms with code -19740. The session keeps working after that.
- **IOSurface-backed only.** `VTFrameProcessorFrame(buffer:…)` returns nil otherwise.
- At 1920x1080 the configuration asks for: width 1920, height 1080, `420v`, IOSurface, extended pixels right 0, bottom 0. A plain 1920x1080 `420v` IOSurface buffer made without those attributes also works, so a capture buffer of that shape can go in with no copy.
- Build pools the way the header says: `CVPixelBufferCreateResolvedAttributesDictionary` over `[configuration attributes, your attributes]`. Never hard-code the attributes.
- **Size limit:** each side ≤ 1920 and width x height ≤ 2,073,600. 1920x1080 works. 1920x1072 passes that check and still fails. 2560x1440 fails.
- The 2x spatial mode (`spatialScaleFactor: 2`) is useless here: even 640x360 is rejected. Do not use it.

Threads and lifecycle (measured, `probes/out/vt_interp_swift.txt`):
- `startSession` blocks while it loads an ML model: 35 to 650 ms normally (77 to 141 ms at 1080p), 2.4 to 5 s the first time a size is used. Call it at startup, off the main thread.
- `process(parameters:completionHandler:)` returns in 0.01 ms (max 0.15). The handler runs about 14 ms later on VideoToolbox's own serial queue (`vtframeprocessor-queue-…`), never on the main thread (0 of 899).
- Calls run one at a time. Two calls sent together finished after 14.6 ms and 29.0 ms. Keep **one call in flight**.
- All three Swift routes cost the same at 1080p: handler p50 14.38 / p99 15.07, `await` 14.19 / 15.04, command buffer plus `waitUntilCompleted` 14.47 / 15.28 ms. Use the handler form from a synchronous function. The command-buffer form is for chaining with other Metal work, only if PLAN.md asks for it; how it reports errors was not tested. Inside `async` code the compiler warns "consider using asynchronous alternative function", which breaks the zero-warnings rule.
- The first call of the first session in a process is slow (32 to 34 ms). Make one warm-up call at startup.
- `endSession()` waits for the call in flight (15 ms) and its handler still runs with no error.
- There is no cancel call in the header. A late result cannot be stopped; you drop it when it arrives.

Traps (each one measured):
1. **`try startSession` does not throw for a bad size.** Obj-C returns YES with the error set (`com.apple.VideoProcessing` -12910, `probes/out/vt_limits.txt`), so Swift sees success. The next process call then fails with -19730 "Processor is not initialized". Check the limits before, and make a warm-up call after.
2. **A process call after `endSession()` crashes the app** (SIGSEGV in `-[VTFrameProcessor captureTelemetryFromParametersIfNeeded:]`). Calling `startSession` again on the same object does not help: the next process call still crashes. After `endSession()` drop the object and make a new `VTFrameProcessor`.
3. **A processor that was never started reports success and writes nothing.** No error, destination untouched. A nil error does not prove a frame was made.
4. **Wrong format is reported as -19740, not -19737.** Do not branch on -19737 to detect it.
5. **Do not trust the Obj-C `BOOL` alone** in probes: check `error != nil` as well.
6. **The output is not the average of the inputs.** Flat grey 60 and flat grey 180 gave 156. Do not write a test that expects the mean.

Errors (`VTFrameProcessorErrors.h`). On every error: show the real frame, add one to a named counter, log the first occurrence of each code.

| Code | Swift case | When (measured or header) | Action |
|---|---|---|---|
| -19730 | `.unknownError` | measured: session started at a size it rejects | at startup: stop and report the size. While running: rebuild (see below) |
| -19731 | `.unsupportedResolution` | header; not seen (bad sizes gave -12910 then -19730) | same as -19730 |
| -19732 | `.sessionNotStarted` | header; not seen (see trap 3) | bug in your lifecycle: fix it, do not retry |
| -19733 | `.sessionAlreadyActive` | header; a second `startSession` did not throw in Swift | bug: start once per object |
| -19734, -19735 | `.fatalError`, `.sessionLevelError` | header; not seen | rebuild |
| -19736, -19738 | `.initializationFailed`, `.memoryAllocationFailure` | header; not seen | rebuild once, then pass-through |
| -19737, -19741 | `.unsupportedInput`, `.invalidParameterError` | header; not seen | bug in your buffers or parameters: log format and size once |
| -19739 | `.revisionNotSupported` | header; this processor has no revision option | cannot happen here; treat as bug |
| -19740 | `.processingError` | measured: wrong pixel format, either side | real frame, count it. 30 in a row: log the buffer format once and switch to pass-through |
| -19742 | `.invalidFrameTiming` | header; not seen even with reversed or invalid timestamps | count it, real frame |
| -19743 | `.assetDownloadFailed` | header; not seen | pass-through and say so on the HUD. Never trigger a download |

- **Rebuild** = on a queue that is not the frame path: `endSession()`, drop the object, create a new `VTFrameProcessor`, start, warm up (60 to 170 ms measured). Count `interpSessionRestarts`. More than 3 rebuilds in 60 s: stay in pass-through.
- **Pass-through** = the presenter shows each real frame for two 60 Hz slots (30 fps). The HUD must show it.
- These thresholds are defaults. If PLAN.md gives others, PLAN.md wins.

Late or failed frame (never block the presenter):
- The presenter never waits for the interpolator. At each output slot it takes the midpoint only if it is already marked ready. If not, it shows the newest real frame and counts `interpLate`.
- A result that arrives after its slot is released back to the pool and counted `interpDroppedLate`. It is never shown out of order.
- If a new pair arrives while a call is in flight, do not queue it: count `interpSkippedBusy` and show the real frame.
- If the destination pool is empty, do not allocate: count `interpPoolExhausted` and show the real frame.

Measured speed, midpoint, one call per 33.37 ms, pooled buffers (`probes/out/interp_speed_res.txt`, `probes/out/vt_interp_swift.txt`):

| Size | p50 | p95 | p99 | max | Source |
|---|---|---|---|---|---|
| 1920x1080 | 14.51 | 16.35 | 18.28 | 26.00 | Obj-C blocking call, 60 s |
| 1920x1080 | 14.38 | 14.88 | 15.07 | 15.75 | Swift handler, 30 s (second run: p99 15.40, max 55.04) |
| 1600x900 | 12.24 | 13.48 | 15.91 | 35.55 | Obj-C, 60 s |
| 1280x720 | 4.84 | 5.25 | 8.04 | 16.75 | Obj-C, 60 s |
| 1280x720 | 4.95 | 5.25 | 6.70 | 13.10 | Swift handler, 20 s |

- Time moves in steps: about 5 ms up to 1280x720, about 10 ms at 1344x756 to 1600x896 (about 12.5 when the height is not a multiple of 16, as in 1600x900), 14 to 15 ms at 1728x972 to 1920x1080.
- A second GPU user slows it: p50 17.88, p99 41.82, max 61.65 at 1080p while another probe ran.
- The per-call objects the API forces you to create: three `VTFrameProcessorFrame`, one parameters object, two small arrays, one closure. They are the only per-frame allocations allowed here.

Optional upscale with `VTLowLatencySuperResolutionScaler` (`VTFrameProcessor_LowLatencySuperResolutionScaler.h`):
- **Not usable for 1080p to the display.** Input is at most 1280 per side. Factors are 1.5, 2 and 4 only. The largest 16:9 output is 1920x1080. `supportedScaleFactors(frameWidth: 1920, frameHeight: 1080)` returns `[]`. The upscale to 3456x1944 is MetalFX (its own skill).
- Use it only if PLAN.md picks a 720p pipeline. Measured, 4 runs under load: 1280x720 x1.5 to 1920x1080, p50 3.43 to 5.09, p99 5.60 to 7.93, max 7.03 to 9.53 ms (`probes/out/vt_limits.txt`).
- Swift: `VTLowLatencySuperResolutionScalerConfiguration(frameWidth:frameHeight:scaleFactor:)` (not failable; check `supportedScaleFactors(frameWidth:frameHeight:) -> [Float]` first), `VTLowLatencySuperResolutionScalerParameters(sourceFrame:destinationFrame:)`. Same `VTFrameProcessor` class, same session rules, `420v` in and out. A session holds one configuration (header), so the scaler needs its own `VTFrameProcessor` object. The traps above were measured on the interpolator only.

## 3. Verified example
One midpoint interpolation, complete. The class and case names are for this example only: PLAN.md decides the real ones.
Obj-C reference with the blocking call: `probes/interp_speed.m` (lines 16 to 42). Swift probe with every failure case: `probes/vt_interp_swift.swift`.

```swift
import CoreMedia
import CoreVideo
import Foundation
import os
import VideoToolbox

enum InterpolatorError: Error {
    case notSupported
    case sizeNotAllowed(width: Int, height: Int, maxDimension: Int, maxPixels: Int)
    case configurationFailed
    case formatNotSupported([OSType])
    case attributes(CVReturn)
    case pool(CVReturn)
    case frameWrapFailed          // a buffer is not IOSurface-backed, or parameters init returned nil
    case warmUpFailed(Error)      // the session did not really start (a wrong size shows up here, not in startSession)
    case warmUpTimedOut
    case sessionEnded
}

/// Makes one midpoint frame between two real frames.
/// Not thread-safe: call init, interpolate and shutdown from ONE serial queue. Never the main thread.
final class MidpointInterpolator {
    enum Outcome {
        case frame(CVPixelBuffer)   // 420v, IOSurface-backed, from the destination pool
        case busy                   // the previous call has not finished; nothing was submitted
        case poolExhausted          // the presenter still holds every destination buffer
        case failed(Error)
    }

    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // '420v', the only format accepted
    let width: Int
    let height: Int
    private var processor: VTFrameProcessor?      // nil after shutdown(); a process call after endSession crashes
    private let destinationPool: CVPixelBufferPool
    private let poolLimit: CFDictionary
    private let inFlight = OSAllocatedUnfairLock(initialState: false)

    /// Slow (35 ms to 5 s, measured): loads an ML model. Call it at startup, off the main thread.
    init(width: Int, height: Int, destinationBufferCount: Int = 4) throws {
        typealias Config = VTLowLatencyFrameInterpolationConfiguration
        guard Config.isSupported else { throw InterpolatorError.notSupported }
        // startSession does not throw for a size that is too large, so check the limits first.
        let maxDimension = Config.maximumDimension(forSpatialScaleFactor: 1) ?? 0
        let maxPixels = Config.maximumPixelCount(forSpatialScaleFactor: 1) ?? 0
        guard width <= maxDimension, height <= maxDimension, width * height <= maxPixels else {
            throw InterpolatorError.sizeNotAllowed(width: width, height: height, maxDimension: maxDimension, maxPixels: maxPixels)
        }
        guard let config = Config(frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else {
            throw InterpolatorError.configurationFailed
        }
        guard config.supportedPixelFormats.contains(Self.pixelFormat) else {
            throw InterpolatorError.formatNotSupported(config.supportedPixelFormats)
        }
        self.width = width
        self.height = height
        destinationPool = try Self.makePool(required: config.destinationPixelBufferAttributes, count: destinationBufferCount)
        poolLimit = [kCVPixelBufferPoolAllocationThresholdKey as String: destinationBufferCount] as CFDictionary

        let processor = VTFrameProcessor()
        try processor.startSession(configuration: config)
        self.processor = processor

        // Warm-up: proves the session works and pays the slow first call (measured 34 ms against 14 ms).
        let sourcePool = try Self.makePool(required: config.sourcePixelBufferAttributes, count: 2)
        let a = try Self.take(sourcePool, limit: nil), b = try Self.take(sourcePool, limit: nil)
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Outcome?>(uncheckedState: nil)
        interpolate(previous: a, previousTime: CMTime(value: 0, timescale: 60),
                    current: b, currentTime: CMTime(value: 2, timescale: 60)) { outcome in
            result.withLockUnchecked { $0 = outcome }
            done.signal()
        }
        guard done.wait(timeout: .now() + 10) == .success else { throw InterpolatorError.warmUpTimedOut }
        switch result.withLockUnchecked({ $0 }) {
        case .frame?: break
        case .failed(let error)?: throw InterpolatorError.warmUpFailed(error)
        default: throw InterpolatorError.warmUpTimedOut
        }
    }

    /// Returns at once (measured 0.01 ms). `completion` runs later on VideoToolbox's own serial queue
    /// ("vtframeprocessor-queue-…", never the main thread), about 14 ms later at 1080p.
    /// Keep the completion short: store the result for the presenter and return.
    func interpolate(previous: CVPixelBuffer, previousTime: CMTime,
                     current: CVPixelBuffer, currentTime: CMTime,
                     completion: @escaping @Sendable (Outcome) -> Void) {
        guard let processor else { completion(.failed(InterpolatorError.sessionEnded)); return }
        // Calls run one after another inside VideoToolbox. A second call would wait for the first (measured 28 ms).
        let free = inFlight.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard free else { completion(.busy); return }

        let destination: CVPixelBuffer
        do { destination = try Self.take(destinationPool, limit: poolLimit) } catch {
            inFlight.withLock { $0 = false }
            if case InterpolatorError.pool(kCVReturnWouldExceedAllocationThreshold) = error { completion(.poolExhausted) } else { completion(.failed(error)) }
            return
        }
        let middle = CMTimeMultiplyByRatio(CMTimeAdd(previousTime, currentTime), multiplier: 1, divisor: 2)
        guard let previousFrame = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: previousTime),
              let sourceFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: currentTime),
              let destinationFrame = VTFrameProcessorFrame(buffer: destination, presentationTimeStamp: middle),
              let parameters = VTLowLatencyFrameInterpolationParameters(sourceFrame: sourceFrame, previousFrame: previousFrame,
                                                                        interpolationPhase: [0.5], destinationFrames: [destinationFrame])
        else {
            inFlight.withLock { $0 = false }
            completion(.failed(InterpolatorError.frameWrapFailed))
            return
        }
        let inFlight = self.inFlight
        processor.process(parameters: parameters) { finished, error in
            inFlight.withLock { $0 = false }
            if let error {
                completion(.failed(error))
            } else if let buffer = finished.destinationFrames?.first?.buffer {
                completion(.frame(buffer))
            } else {
                completion(.failed(InterpolatorError.frameWrapFailed))
            }
        }
    }

    /// Blocks until the call in flight finishes (measured 15 ms). After this the object is dead: build a new one.
    func shutdown() {
        processor?.endSession()
        processor = nil
    }

    private static func makePool(required: [String: Any], count: Int) throws -> CVPixelBufferPool {
        let mine: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var resolved: CFDictionary?
        var status = CVPixelBufferCreateResolvedAttributesDictionary(kCFAllocatorDefault, [required, mine] as CFArray, &resolved)
        guard status == kCVReturnSuccess, let attributes = resolved else { throw InterpolatorError.attributes(status) }
        var pool: CVPixelBufferPool?
        // Age 0 = never free idle buffers (the default frees them after one second, CVPixelBufferPool.h).
        let poolOptions: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: count,
                                          kCVPixelBufferPoolMaximumBufferAgeKey as String: 0]
        status = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolOptions as CFDictionary, attributes, &pool)
        guard status == kCVReturnSuccess, let pool else { throw InterpolatorError.pool(status) }
        // Fill the pool now, so no IOSurface is allocated while frames are flowing.
        var warm: [CVPixelBuffer] = []
        for _ in 0..<count { warm.append(try take(pool, limit: nil)) }
        return pool
    }

    private static func take(_ pool: CVPixelBufferPool, limit: CFDictionary?) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw InterpolatorError.pool(status) }
        return buffer
    }
}
```

Checks run on this file (saved as `MidpointInterpolator.swift`), with their real results:
```
$ xcrun swiftc -typecheck -swift-version 5 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 MidpointInterpolator.swift
(no output, exit 0)
$ xcrun swiftc -typecheck -swift-version 5 -strict-concurrency=complete -warnings-as-errors -sdk <same> -target arm64-apple-macos27.0 MidpointInterpolator.swift main.swift
(no output, exit 0)
$ ./demo        # the class plus a 50-line main: two flat grey frames in, UNDER LOAD
init + warm-up: 169 ms
call 0: frame 1920x1080, centre luma 156 (inputs 60 and 180), 14.8 ms, main thread no
call 1: frame 1920x1080, centre luma 156 (inputs 60 and 180), 14.1 ms, main thread no
call 2: frame 1920x1080, centre luma 156 (inputs 60 and 180), 14.2 ms, main thread no
call 3: frame 1920x1080, centre luma 156 (inputs 60 and 180), 13.8 ms, main thread no
call 4: frame 1920x1080, centre luma 156 (inputs 60 and 180), 13.8 ms, main thread no
second call while one is in flight: busy (not submitted)
call after shutdown: failed(demo.InterpolatorError.sessionEnded)
2560x1440: sizeNotAllowed(width: 2560, height: 1440, maxDimension: 1920, maxPixels: 2073600)
1920x1072: warmUpFailed(Error Domain=VTFrameProcessorErrorDomain Code=-19730 "Processor is not initialized" UserInfo={NSLocalizedDescription=Processor is not initialized})
```
- Target `arm64-apple-macos27.0` is required. With `macos26.0` the two limit calls fail: "only available in macOS 27.0 or newer".
- Every symbol in the table of section 2, including the scaler, the `await` form, the `AsyncSequence` form and all 14 error cases, type-checks with the same command (exit 0).
- The semaphore in `init` is startup code. Never wait like that on the frame path.

## 4. Project conventions
- App code is Swift (language mode 5), one SwiftPM package at the repo root: library target `FrameGenCore` (pure logic: cadence detector, pacing math, statistics; no hardware, fully unit-tested), executable target `FrameGen` (capture, VideoToolbox, Metal, audio, HUD), tests in `Tests/FrameGenCoreTests`. No third-party dependencies.
- Probes and measurement tools are single files under `probes/` (Obj-C or Swift), each with the build command in its first comment.
- Build: `swift build -c release`. Tests: `swift test`. App bundle: `scripts/make-app.sh` (wraps the binary in build/GTA6FrameGen.app with an Info.plist carrying NSCameraUsageDescription and NSMicrophoneUsageDescription).
- One timebase: host time in seconds (mach / CACurrentMediaTime). Capture timestamps are converted to host time once, at capture.
- Every frame carries a trace record (capture time, unique/duplicate verdict, interpolation start/end, scaler end, target present time, actual present time). The HUD and the CSV logs under `runs/` read only from these records.
- Hot path: no heap allocation per frame (CVPixelBufferPool, preallocated rings), no CPU copy of pixel data (IOSurface-backed buffers, CVMetalTextureCache), no locks held across a VideoToolbox or Metal call, no sleeping for pacing, never block the main thread.

## 5. Banned
placeholders; TODO or FIXME stubs; "simplified version"; functions that return hard-coded or fake data; synthetic numbers presented as measured; skipped error handling; silent fallbacks (every fallback increments a named counter and is logged once); catch-all `try?` on the hot path; claiming something was run without pasting the output; changing a public interface from PLAN.md without saying so; installing anything; touching OBS, ~/Developer/cliprift-studio or the ps5audio helper.

## 6. Interfaces
See PLAN.md, section "Interfaces". Match them exactly.

## 7. How to build and test
```
cd ~/Developer/ps5-framegen
swift build -c release 2>&1 | tee build.log      # must show no warning in the files you touched
swift test
```
Without the Elgato, test on the recording. It is 2560x1440 at 59.94 fps and holds each game frame twice, so keep every second decoded frame and scale it to 1920x1080 `420v` with `VTPixelTransferSession`. Both probes below already do this.
```
cd ~/Developer/ps5-framegen/probes
V="<recording>.mp4"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 vt_interp_swift.swift -o vt_interp_swift
./vt_interp_swift "$V" 1500 30                      # limits, failure cases, 3 call styles, lifecycle. About 2.5 min
./vt_interp_swift "$V" 1500 1 1920 1080 risky1      # shows the crash after endSession (exit 139 is expected)
clang -fobjc-arc -O2 -Wno-deprecated-declarations interp_speed_res.m -o interp_speed_res -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore
./interp_speed_res "$V" 1500 600 1920 1080 33.37 1  # 10-minute Obj-C reference: paced, pooled
```
- For the 10-minute number, run your own code path on the same footage with the same pacing (one call per 33.37 ms) and print p50, p95, p99, max and the failure count. Then run `interp_speed_res` straight after, for comparison.
- Before any timing run: `uptime` and `pgrep -lf ffmpeg`. If ffmpeg jobs are running, do **not** stop them: label the result "under load" and list the idle run under "Not finished".
- The bottom-right corner of the recording (x ≥ 83 %, y ≥ 77 %) is a webcam overlay that changes every frame. Leave it out of any image comparison.
- `AVAssetReader.add`, `startReading` and `copyNextSampleBuffer` are deprecated in macOS 27 (compiler warning). They are fine in probes. In app code open `AVAssetReader.h` and use the replacements it names.
- With the Elgato plugged in: not tested yet. Procedure: run the app's capture path, log the pixel format and size of the first capture buffer, and confirm it is `420v` 1920x1080 and IOSurface-backed before it reaches the interpolator. If it is not, report it. Do not add a silent conversion.

## 8. Definition of done
- Interpolation at 1080p, paced one call per 33.37 ms, 10 minutes (about 17,980 calls), 0 failures. Report p50, p95, p99, max and what the machine was doing (`uptime`, `pmset -g | grep lowpowermode`). The timer starts just before the process call and stops at the first line of the completion handler. The numbers go to `runs/<date-time>/interp.csv`.
  - The original target was p99 ≤ 12 ms. **No run so far is under 12 ms.** Under load, 12 saved 1080p runs (`probes/out/run-10min-during-render.txt`, `interp_speed_res.txt`, `vt_interp_swift.txt`): p50 12.8 to 15.3, p99 14.3 to 21.1; with a second GPU user p50 17.9, p99 41.8. Report the real numbers. A miss of 12 ms is a finding, not a failure of your task. Do not change the size, the pacing or the percentile.
- No per-frame heap allocation on the hot path, apart from the objects the API forces (listed in section 2). Prove it: the number of distinct IOSurface IDs seen in destination buffers over the run is ≤ the pool size, and every counter named in section 2 is printed at the end of the run.
- The interpolator does not decide what is shown. Its contract (PLAN.md section 6): `request(...)` returns `.busy` at once when a call is in flight and does **not** call the completion; every accepted request gets its completion exactly once, on the queue passed in, late or not, with the original `PairRequest` and the start and end times. The Conductor, not the interpolator, counts `interpBusy`, `interpLate` and `interpStale` and discards late or stale results. Tests required, each with a fault-injection hook compiled only into the test target: busy rejection; result delivered late; 2560x1440 rejected by preflight; 1920x1072 rejected by warm-up; call after `shutdown()` returns an error and does not crash; destination pool exhausted; 30 failures in a row turn generation off; rebuild after a failed session uses a new `VTFrameProcessor`.
- The output is a real midpoint: a test feeds two frames with a bright square at x = 400 and x = 480 and checks that the result has a square whose centroid lies between 425 and 455 **and** that the contrast at the two end positions (x = 400 and x = 480 squares) is below 25 % of the input square's. Returning either input fails; a 50/50 blend fails.
- Preflight size check and warm-up call are present. No process call can happen after `endSession()`.
- Builds with zero warnings in the files touched. Tests pass. The output format below is followed.

## 9. Required output format from the implementer
(a) Full contents of every file created, or a unified diff of every file edited.
(b) The exact build and test commands, with their real output pasted.
(c) A measured-numbers table (size, call count, p50, p95, p99, max, failures, counters, load average, "idle" or "under load").
(d) A list titled "Not finished" (write "nothing" only if true).
