# Skill: capture and cadence detection for GTA6 60 FPS (Mac)

## 1. Purpose and scope
Use this for any task that touches (a) video or audio capture from the Elgato 4K S with AVFoundation, or (b) the cadence detector that tells new game frames from repeated ones.
In scope: device discovery, format choice (1920x1080, 420v, 59.94/60), session setup, capture timestamps in host time, dropped-frame accounting, the luma-difference sampler, the cadence state machine, offline replay of recorded footage.
Out of scope: interpolation, scaling, presentation, audio playback. Those have their own skills.
Do the whole task. If you cannot finish, list what is missing under "Not finished". Never report a step you did not run.

## 1a. Decisions from PLAN.md (these win over anything below)
- Names: generation off is called *real-only*; real and generated alternating is *framegen*. Cadence states in code are `locked22`, `native60`, `unknown` (this file's `LOCKED_2_2`, `PASSTHROUGH_60`, `UNKNOWN`). "Passthrough" means only the HDMI cable from the card to the TV.
- Types and signatures: PLAN.md section 6. Example names in this file are for the example only.
- Buffer ownership: PLAN.md section 5 table. In version 1 device buffers never leave the capture stage: every frame is copied into the app's pool by the normaliser, and the device buffer is released before the callback returns.
- Counters: every fallback has a named counter (PLAN.md sections 5 and 5.2). Use those names. Every item and every reservation carries an epoch (PLAN.md section 5, "Epochs").
- Logs: the two ledgers of PLAN.md section 6 (`items.csv`, `slots.csv`) plus `counters.txt` and `run.json` under `runs/<date-time>/`. Acceptance numbers are computed from these files by `tools/stats.py`, never from console prints.
- Capture is format-agnostic. Ask for 1920x1080 `420v` at the highest rate near 60. If `lockForConfiguration` fails with `AVError.deviceLockedForConfigurationByAnotherProcess` (-11817), do not retry and do not fail: take the active format as it is, log it, and normalise. Never hold the device lock after `startRunning()` returns. OBS may own this device.
- The luma sampler runs on the capture buffer as delivered (any size); the row and pixel steps scale so about 15,840 samples are read.
- Never write to BlackHole, never change the sample rate of BlackHole or of the Elgato audio device, never publish a device whose name contains "Elgato". The user's `ps5audio` helper reads the same audio device.
- File replay must use the non-deprecated `AVAssetReader` calls (`outputProvider(for:)`, `start()`, `next()`); the old ones break the zero-warnings rule on this SDK.

## 2. Exact APIs
`$SDK` = `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`, `$F` = `$SDK/System/Library/Frameworks`. Every symbol below was read in its header and compiled (section 3). Open the header before you rely on anything not listed here.

`$F/AVFoundation.framework/Headers/AVCaptureDevice.h`
| Swift | Obj-C | Facts from the header |
|---|---|---|
| `AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices` | `+[AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:mediaType:position:]`, `AVCaptureDeviceTypeExternal` | macOS 14+. `AVCaptureDeviceTypeExternalUnknown` is deprecated. Audio: `.microphone` / `AVCaptureDeviceTypeMicrophone` with `mediaType: .audio`. |
| `uniqueID`, `localizedName`, `linkedDevices`, `isInUseByAnotherApplication` | same names, `inUseByAnotherApplication` | Last two are macOS only. `isInUseByAnotherApplication` is key-value observable. |
| `formats`, `Format.formatDescription`, `Format.videoSupportedFrameRateRanges`, `AVFrameRateRange.maxFrameRate`, `.minFrameDuration` | `AVCaptureDeviceFormat`, same property names | Pixel format = `CMFormatDescriptionGetMediaSubType`, size = `CMVideoFormatDescriptionGetDimensions`. |
| `try lockForConfiguration()`, `unlockForConfiguration()` | `-lockForConfiguration:`, `-unlockForConfiguration` | Exclusive across processes. Fails with `AVError.deviceLockedForConfigurationByAnotherProcess` (-11817). Header: holding it can degrade capture in other apps sharing the device. |
| `activeFormat`, `activeVideoMinFrameDuration`, `activeVideoMaxFrameDuration` | same | Setting without the lock raises `NSGenericException`; a format not in `formats` or an unsupported duration raises `NSInvalidArgumentException`. Swift cannot catch these: the app crashes. Set all three between `beginConfiguration` and `commitConfiguration`; they apply together at commit. |

`$F/AVFoundation.framework/Headers/AVCaptureSession.h`, `AVCaptureInput.h`
| Swift | Obj-C | Facts from the header |
|---|---|---|
| `beginConfiguration()`, `commitConfiguration()`, `canAddInput`, `addInput`, `canAddOutput`, `addOutput` | same | Calling `startRunning` between begin and commit raises `NSGenericException`. |
| `startRunning()`, `stopRunning()` | same | Both block until done. Call on a background serial queue, never main. Start failures arrive as `AVCaptureSession.runtimeErrorNotification` (`AVCaptureSessionRuntimeErrorNotification`). |
| `synchronizationClock` (`CMClock?`) | `synchronizationClock` (`CMClockRef`) | macOS 12.3+. Header: "All capture output sample buffer timestamps are on the synchronizationClock timebase." `masterClock` is deprecated. |
| `AVCaptureDeviceInput(device:)` throws | `+deviceInputWithDevice:error:` | `AVCaptureInput.Port.clock` is the device's own clock. Do not use it for frame times. |
| `AVCaptureSession.Preset.inputPriority` | `AVCaptureSessionPresetInputPriority` | **Unavailable on macOS** (compile error). There is no preset that tells the session to leave `activeFormat` alone. |

`$F/AVFoundation.framework/Headers/AVCaptureVideoDataOutput.h`, `AVCaptureAudioDataOutput.h`
| Swift | Obj-C | Facts from the header |
|---|---|---|
| `videoSettings = [:]` | `videoSettings = @{}` | Empty dictionary = device native format. `nil` = "a default uncompressed format" (may convert). A dictionary with a pixel format = decode or convert to it. |
| `availableVideoPixelFormatTypes` | `availableVideoCVPixelFormatTypes` | The Swift name differs. The Obj-C name does not compile in Swift. |
| `alwaysDiscardsLateVideoFrames` | same | Default `true`. Keep `true`: a frame that arrives while the delegate is busy is dropped, not queued. |
| `setSampleBufferDelegate(_:queue:)` | `-setSampleBufferDelegate:queue:` | The queue must be serial and non-nil. All delegate calls arrive on it. |
| `captureOutput(_:didOutput:from:)` | `-captureOutput:didOutputSampleBuffer:fromConnection:` | Buffers come from a device pool. Holding many of them makes the device drop frames (`OutOfBuffers`). |
| `captureOutput(_:didDrop:from:)` | `-captureOutput:didDropSampleBuffer:fromConnection:` | One call per dropped frame, same queue, timing but no pixels. The reason attachment is promised "On iOS" only: on macOS treat it as optional. |
| `AVCaptureAudioDataOutput`, `audioSettings = nil` | same | `nil` = device native audio format (macOS only property). Delegate has `didOutput` only. |

Other headers
| Swift | Obj-C | Header and facts |
|---|---|---|
| `CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())` | `CMSyncConvertTime(pts, clock, CMClockGetHostTimeClock())` | `$F/CoreMedia.framework/Headers/CMSync.h`. Header: "To convert to or from host time, pass CMClockGetHostTimeClock()". |
| `kCMSampleBufferAttachmentKey_DroppedFrameReason`, values `…Reason_FrameWasLate`, `_OutOfBuffers`, `_Discontinuity` | same | `CMSampleBuffer.h`. Read with `CMGetAttachment`. `AVCaptureOutputDataDroppedReason` (AVCaptureOutputBase.h) is for depth and synchronizer outputs, not this callback. |
| `kCMIOSampleBufferAttachmentKey_SequenceNumber`, `_HostTime`, `_DiscontinuityFlags`, `_RepeatedBufferContents` (each needs `.takeUnretainedValue()`) | same, plain `CFStringRef` | `$F/CoreMediaIO.framework/Headers/CMIOSampleBuffer.h`. Swift needs `import CoreMediaIO.CMIOSampleBuffer`; plain `import CoreMediaIO` does not expose them. Whether AVFoundation buffers carry them is not tested: log them once. |
| `CVPixelBufferLockBaseAddress(pb, .readOnly)`, `CVPixelBufferGetBaseAddressOfPlane`, `CVPixelBufferGetBytesPerRowOfPlane` | same, `kCVPixelBufferLock_ReadOnly` | `$F/CoreVideo.framework/Headers/CVPixelBuffer.h`. Unlock with the same flag. Bytes per row can exceed width. |
| `reader.outputProvider(for:)`, `try reader.start()`, `try await provider.next()`, `ready.withUnsafeSampleBuffer { }` | none (Swift only) | macOS 26+. `AVAssetReader.add(_:)`, `startReading()`, `copyNextSampleBuffer()`, `alwaysCopiesSampleData` are deprecated in the macOS 27 SDK (4 warnings, measured). |

Rules that follow from the above
- **Timestamps.** `host = CMTimeGetSeconds(CMSyncConvertTime(pts, from: session.synchronizationClock, to: CMClockGetHostTimeClock()))`. `synchronizationClock` is optional: read it on the capture queue when the first frame arrives, cache it per queue, and count (do not use) any frame that arrives while it is nil. Host-clock seconds equal `CACurrentMediaTime()`: measured, max difference 17.8 µs over 1000 reads (`hostclock.swift` in the skillcheck folder of section 3). Convert once, in the capture callback.
- **No conversion.** Pick a device format whose native subtype is `420v` at 1920x1080, set `videoSettings = [:]`, then check the first frame: image buffer present, `CVPixelBufferGetPixelFormatType == 420v`, 1920x1080, `CVPixelBufferGetIOSurface != nil`. If any check fails, stop with a named error. Do not add a converter. If the device has no native 1080p 420v format, stop and report the format list.
- **Frame rate.** Use the `minFrameDuration` object of the chosen range. Do not build `CMTime(1001, 60000)` by hand: OBS's saved settings show this card advertises 60.00024 fps (`60000240/1000000`), not 59.94. The PS5 signal is 59.94 Hz, so measure the real period from timestamps.
- **Format survives start.** With no input-priority preset on macOS, the session may replace `activeFormat` at start. Keep the device lock until `startRunning()` returns, then compare `device.activeFormat` with what you set and fail loudly if it differs. Not tested on the Elgato.
- **Sharing with OBS.** A device has one active format for all apps. OBS's scene (read-only look at its config) opens "Elgato 4K S", uniqueID `0x22000000fd900af`, at **2560x1440 420v 60 fps**, not 1080p. Running both apps means one format wins. Which one, and whether OBS holds the configuration lock, is not tested. If the lock fails with -11817 and the active format is already the wanted one, continue and count it; otherwise stop with the error. Never change OBS.
- **Device identity.** The uniqueID is USB location + vendor `0fd9` + product `00af`; the location part changed between ports (seen: `0x2000000…`, `0x12000000…`, `0x22000000…`). Match the suffix `fd900af`, then the name.
- **Audio.** The card's audio is a separate `AVCaptureDevice` (`mediaType: .audio`). Try `video.linkedDevices` first, then the name. Add its input and an `AVCaptureAudioDataOutput` to the same session so audio and video share the synchronization clock. The `ps5audio` helper reads the same audio device; whether both can read at once is not tested.
- **CoreMediaIO direct route** (`CMIODeviceStartStream`, `CMIOStreamCopyBufferQueue` in `CMIOHardwareDevice.h`, `CMIOHardwareStream.h`): it would skip AVFoundation's queue hop only. Estimate: under 1 ms saved, not measured. It needs hand-written format negotiation in C and gives no audio sync. Not worth it. Revisit only if a live run shows `callback time − capture time` p50 above 5 ms.
- **macOS 26 locked frame rate** (`AVCaptureDeviceInput.activeLockedVideoFrameDuration`): do not use. Setting it when `isLockedVideoFrameDurationSupported` is false raises an exception; support on a UVC card is unknown.

## 2b. Required cadence behaviour
The detector lives in `FrameGenCore`. Its only inputs per captured frame are `t` (capture time, host seconds) and `d` (a diff value). It never sees pixels. It answers in the same call: verdict `NEW` or `DUP`, state, flags.
`probes/cadence_ref.py` is the executable reference (selftest passes, measured). The Swift detector must give the same verdict, state and counters for the same input. If this text and the reference disagree, stop and report it.

**Diff value.** Y plane (plane 0) of the 420v buffer, read from the locked base address. Grid: every 32nd row, every 4th pixel, starting at row 16, column 2: 33 x 480 = 15,840 samples at 1920x1080. `d` = mean of `|current − previous|` in 8-bit code units. Keep the previous frame's 15,840 samples in one array allocated once (a signature, not a pixel copy). First frame: no `d`, verdict `NEW`.
Measured cost on decoded 1080p frames of the test recording, 20 to 60 s runs, lock and unlock included (this Mac, load average 3 to 17 from other jobs):
| Grid (rows x pixels) | Samples | p50 | p99 | Verdict |
|---|---|---|---|---|
| every 8th x every 8th | 32,400 | 135–203 µs | 350–478 µs (7 runs) | fails the 0.3 ms budget |
| every 16th x every 4th | 32,160 | 65–109 µs | 223–330 µs (5 runs) | marginal |
| every 32nd x every 4th | 15,840 | 36–58 µs | 100–217 µs (17 runs) | use this |
Cost follows rows touched (cold memory), not sample count. The gap between duplicate and new diffs was the same for all three grids. Not measured on live capture buffers.

**Rules** (parameter names as in `PARAMS` in the reference)
1. Slots. `n = max(1, round(Δt / period))`. `period` starts at 1001/60000 s and follows Δt (1/16 step) when `n = 1`. `n ≥ 2`: `droppedSlots += n − 1`, flag `gap`. Δt > `reset_gap` (0.5 s): state `UNKNOWN`, `timeResets += 1`, `n = 1`. Δt ≤ period/2: `timestampAnomalies += 1`, treat as `n = 1`.
2. Noise floor. Running mean and mean absolute deviation of `d` over frames judged `DUP` in the LOW band with `n = 1`. Step = 1/min(sample count, 32): a plain average for the first 32 samples, then 1/32. The deviation is updated after the mean and uses the new mean. `t_lo = max(t_floor, k_lo × (mean + 4 × deviation))`.
3. Motion level. Running mean of `d` (step = 1/min(sample count, 16)) over `NEW` frames that are not promoted, not a scene cut, `n = 1`. `t_hi = max(2 × t_lo, k_motion × motion)`; the motion term counts only once 4 motion samples exist (before that `t_hi = 2 × t_lo`).
4. Band. `d ≤ t_floor`: LOW. Before 8 noise samples exist: LOW if `d × r_boot ≤ previous d`, else HIGH. After: LOW if `d ≤ t_lo`, HIGH if `d ≥ t_hi`, else MID.
5. Verdict. HIGH is `NEW` at once in every state: a frame that differs from the previous one is never delayed. LOW is `DUP`. MID follows the phase when `LOCKED_2_2` (expect `NEW` when the slot count since the last `NEW` is even) and is `NEW` in the other states.
6. Late promotion, the only delayed path (exactly one captured frame). In `LOCKED_2_2`, if the previous frame was MID and judged `DUP`, and this frame is LOW with `n = 1` where the phase expects `NEW`: verdict `NEW`, `latePromotions += 1`.
7. Scene cut. HIGH, `n = 1`, at least 4 motion samples exist, and `d ≥ max(cut_abs, cut_k × motion)`: flag `sceneCut`, do not feed it into motion. No state change.
8. Static screen. `static_run` (5) `DUP` in a row: flag `static`, the state is frozen and violations are not counted. The first HIGH frame afterwards is `NEW` at once.
9. Dropped frames. `d` always compares with the previous delivered frame, so the frame after a gap is judged by content. Frames with `n > 1` never count as violations or phase flips.
10. Events while `LOCKED_2_2` (`n = 1`, not static): `NEW` where `DUP` was expected: `phaseFlips += 1`, lock kept, phase follows the last `NEW`. `DUP` where `NEW` was expected: `repeatedFrames += 1`.
11. States. Keep the last 32 verdicts; clear them on every state change and on every time reset. A violation is a verdict equal to the previous verdict with `n = 1`.
    - `UNKNOWN → LOCKED_2_2`: 8 frames in a row with alternating verdicts.
    - `UNKNOWN` or `LOCKED_2_2 → PASSTHROUGH_60`: at least 10 `NEW` in the last 12 frames.
    - `LOCKED_2_2 → UNKNOWN`: at least 6 violations in the last 32 frames and at most 8 `NEW` in the last 12.
    - `PASSTHROUGH_60 → UNKNOWN`: at most 8 `NEW` in the last 12 frames. `LOCKED_2_2` is entered only from `UNKNOWN`.
What the pipeline shows in each state is defined in PLAN.md, not here.

**Thresholds are parameters.** Every value in `PARAMS` (`t_floor` 0.02, `k_lo` 2, `k_motion` 0.5, `r_boot` 4, `cut_abs` 20, `cut_k` 4, run lengths and windows above) is a starting estimate. None was fitted on real capture. Fit them on a trace of uncompressed capture and record the trace file used. Do not fit them on the OBS recording.
**The OBS recording is lossy and has an overlay.** Mask the webcam overlay in every offline test: skip samples with `x ≥ 0.80 × width` and `y ≥ 0.74 × height` (overlay measured at x 86.8–100 %, y 76.9–98.7 %). Measured on the recording (`probes/out/cadence/luma_mad_*.csv`): duplicate diffs on foot are p50 0.05, p95 0.10 and never exactly 0 (in the two driving windows 1 % and 33 % of all frames have a diff of exactly 0, so a test must not assume a non-zero duplicate diff), against 11 to 15 for new frames on foot and 1.5 to 5 in a dark slow scene; every 118th frame (a codec keyframe) lifts a duplicate's diff to 1.9–3.3; one of three windows (start 3792 s) is irregular, with only 73 % of new frames two slots apart. Whether that irregularity is in the HDMI signal or was added by OBS is not known.

## 3. Verified example
Minimal and complete. These three blocks were extracted from this file and compiled as shown below. The type, callback and counter names are for this example only: PLAN.md decides the real ones.
```swift
// file: Capture.swift
import AVFoundation
import CoreMediaIO.CMIOSampleBuffer   // explicit submodule, see section 2
import QuartzCore
enum CaptureError: Error {
    case deviceNotFound, cannotAddInput, cannotAddOutput, firstFrameWrong(String), noNative1080p60(formats: [String])
    case lockFailed(NSError, activeFormat: String), formatNotApplied(wanted: String, got: String)
}
final class CaptureCounters {   // written on videoQueue only; hand snapshots to the HUD
    var delivered = 0, droppedLate = 0, droppedOutOfBuffers = 0, droppedDiscontinuity = 0, droppedNoReason = 0
    var noImageBuffer = 0, noSyncClock = 0, lockHeldByOtherProcess = 0, audioMissing = 0
}
func describe(_ f: AVCaptureDevice.Format) -> String {
    let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription), s = CMFormatDescriptionGetMediaSubType(f.formatDescription)
    let cc = String(bytes: [24, 16, 8, 0].map { UInt8((s >> $0) & 0xff) }, encoding: .ascii) ?? "\(s)"
    return "\(d.width)x\(d.height) \(cc) @" + f.videoSupportedFrameRateRanges.map { String(format: "%.3f", $0.maxFrameRate) }.joined(separator: "/")
}
final class CaptureSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput(), audioOutput = AVCaptureAudioDataOutput()
    let videoQueue = DispatchQueue(label: "framegen.capture.video", qos: .userInteractive)   // serial
    let audioQueue = DispatchQueue(label: "framegen.capture.audio", qos: .userInteractive)   // serial
    let counters = CaptureCounters()
    private let hostClock = CMClockGetHostTimeClock()
    private var videoClock: CMClock?, firstFrameOK = false, fatalSent = false   // videoQueue only
    private var audioClock: CMClock?                                             // audioQueue only
    private(set) var audioNoSyncClock = 0                                        // audioQueue only
    var onFrame: ((CVPixelBuffer, _ captureHostSeconds: Double, _ callbackHostSeconds: Double) -> Void)?   // on videoQueue
    var onAudio: ((CMSampleBuffer, _ captureHostSeconds: Double) -> Void)?                                 // on audioQueue
    var onFatal: ((CaptureError) -> Void)?
    static func findVideo() -> AVCaptureDevice? {   // listing devices raises no permission prompt
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        return all.first { $0.uniqueID.lowercased().hasSuffix("fd900af") } ?? all.first { $0.localizedName.contains("Elgato") }
    }
    static func findAudio(for video: AVCaptureDevice) -> AVCaptureDevice? {
        if let linked = video.linkedDevices.first(where: { $0.hasMediaType(.audio) }) { return linked }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        return all.first { $0.localizedName.contains("Elgato") }
    }
    static func pickFormat(_ device: AVCaptureDevice) -> (AVCaptureDevice.Format, AVFrameRateRange)? {
        for f in device.formats {
            let dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            guard CMFormatDescriptionGetMediaSubType(f.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                  dim.width == 1920, dim.height == 1080 else { continue }
            let near60 = f.videoSupportedFrameRateRanges.filter { $0.maxFrameRate > 59.0 && $0.maxFrameRate < 60.5 }
            if let r = near60.min(by: { $0.maxFrameRate < $1.maxFrameRate }) { return (f, r) }
        }
        return nil
    }
    /// Call on a background queue: startRunning() blocks. Opens the device (permission prompt on first use).
    func start() throws {
        guard let device = Self.findVideo() else { throw CaptureError.deviceNotFound }
        guard let (format, range) = Self.pickFormat(device) else { throw CaptureError.noNative1080p60(formats: device.formats.map(describe)) }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CaptureError.cannotAddInput }
        session.addInput(input)
        videoOutput.videoSettings = [:]                      // device native format: no decode, no conversion
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { session.commitConfiguration(); throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)
        var locked = false
        do {
            try device.lockForConfiguration()
            locked = true
            device.activeFormat = format
            device.activeVideoMinFrameDuration = range.minFrameDuration   // the range's own CMTime
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        } catch let e as NSError {
            guard e.code == AVError.deviceLockedForConfigurationByAnotherProcess.rawValue, device.activeFormat == format else {
                session.commitConfiguration()
                throw CaptureError.lockFailed(e, activeFormat: describe(device.activeFormat))
            }
            counters.lockHeldByOtherProcess += 1
            NSLog("capture: another process holds the device lock; its active format is already the wanted one")
        }
        do {
            guard let mic = Self.findAudio(for: device) else { throw CaptureError.deviceNotFound }
            let audioInput = try AVCaptureDeviceInput(device: mic)
            guard session.canAddInput(audioInput), session.canAddOutput(audioOutput) else { throw CaptureError.cannotAddInput }
            session.addInput(audioInput)
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutput(audioOutput)
        } catch { counters.audioMissing += 1; NSLog("capture: running without Elgato audio: \(error)") }
        session.commitConfiguration()
        session.startRunning()
        if locked { device.unlockForConfiguration() }       // held across start so the session cannot replace the format
        guard device.activeFormat == format else { throw CaptureError.formatNotApplied(wanted: describe(format), got: describe(device.activeFormat)) }
    }
    /// Capture PTS to host seconds. `clock` is the calling queue's cache. nil while the session has no synchronization clock.
    private func hostSeconds(_ pts: CMTime, _ clock: inout CMClock?) -> Double? {
        if clock == nil { clock = session.synchronizationClock }
        guard let c = clock else { return nil }
        return CMTimeGetSeconds(CMSyncConvertTime(pts, from: c, to: hostClock))
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime(), pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output === audioOutput {
            guard let t = hostSeconds(pts, &audioClock) else { audioNoSyncClock += 1; return }
            onAudio?(sampleBuffer, t); return
        }
        guard let t = hostSeconds(pts, &videoClock) else { counters.noSyncClock += 1; return }   // frame not used, counted
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { counters.noImageBuffer += 1; return }
        if !firstFrameOK {
            let fmt = CVPixelBufferGetPixelFormatType(pb), w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let surface = CVPixelBufferGetIOSurface(pb) != nil
            guard fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, w == 1920, h == 1080, surface else {
                if !fatalSent { fatalSent = true; onFatal?(.firstFrameWrong("\(w)x\(h) format \(fmt) iosurface \(surface)")) }
                return
            }
            firstFrameOK = true
            let seq = CMGetAttachment(sampleBuffer, key: kCMIOSampleBufferAttachmentKey_SequenceNumber.takeUnretainedValue(), attachmentModeOut: nil)
            let host = CMGetAttachment(sampleBuffer, key: kCMIOSampleBufferAttachmentKey_HostTime.takeUnretainedValue(), attachmentModeOut: nil)
            NSLog("capture: first frame ok; cmio sequence \(String(describing: seq)) hostTime \(String(describing: host))")
        }
        counters.delivered += 1
        onFrame?(pb, t, now)
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let why = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        if why == (kCMSampleBufferDroppedFrameReason_FrameWasLate as String) { counters.droppedLate += 1 }
        else if why == (kCMSampleBufferDroppedFrameReason_OutOfBuffers as String) { counters.droppedOutOfBuffers += 1 }
        else if why == (kCMSampleBufferDroppedFrameReason_Discontinuity as String) { counters.droppedDiscontinuity += 1 }
        else { counters.droppedNoReason += 1 }
    }
}
```
```swift
// file: LumaDiff.swift
import CoreVideo
/// Mean absolute luma difference against the previous frame on a sparse grid. No allocation after init. One queue only.
final class LumaDiff {
    static let rowStep = 32, pxStep = 4
    let cols: Int, rows: Int
    private let previous: UnsafeMutablePointer<UInt8>
    private let maskCol: Int, maskRow: Int      // samples with col >= maskCol and row >= maskRow are skipped
    private var primed = false
    private(set) var lockFailures = 0, geometryMismatches = 0
    /// maskX, maskY: where an overlay starts, as a fraction of width and height. 1.0 = no mask (live capture).
    init(width: Int, height: Int, maskX: Double = 1.0, maskY: Double = 1.0) {
        cols = width / Self.pxStep; rows = height / Self.rowStep
        maskCol = Int(Double(cols) * maskX); maskRow = Int(Double(rows) * maskY)
        previous = .allocate(capacity: cols * rows)
        previous.initialize(repeating: 0, count: cols * rows)
    }
    deinit { previous.deallocate() }
    /// nil for the first frame and when the buffer cannot be read (counted). Otherwise the diff in 8-bit code units.
    func push(_ pixelBuffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { lockFailures += 1; return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) / Self.pxStep == cols,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) / Self.rowStep == rows else { geometryMismatches += 1; return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let y = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, count = 0
        for r in 0..<rows {
            let n = r >= maskRow ? maskCol : cols
            var src = y + (r * Self.rowStep + Self.rowStep / 2) * stride + Self.pxStep / 2
            var old = previous + r * cols
            for _ in 0..<n {
                let v = src.pointee
                sum += abs(Int(v) - Int(old.pointee))
                old.pointee = v
                old += 1; src += Self.pxStep
            }
            count += n
        }
        if !primed { primed = true; return nil }
        return Double(sum) / Double(count)
    }
}
```
```swift
// file: FileReplay.swift
import AVFoundation
enum ReplayError: Error { case noVideoTrack }
/// Recorded footage through the same sampler: frames scaled to 1920x1080 420v, `each(pixelBuffer, ptsSeconds)`.
func replay(url: URL, start: Double, seconds: Double, each: (CVPixelBuffer, Double) -> Void) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ReplayError.noVideoTrack }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000),
                                   duration: CMTime(seconds: seconds, preferredTimescale: 60000))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080])
    let provider = reader.outputProvider(for: output)
    try reader.start()
    while let ready = try await provider.next() {
        ready.withUnsafeSampleBuffer { sampleBuffer in
            guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            each(pb, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
        }
    }
}
```
Type-check command and result. `$S` = `<scratchpad>`:
```
$ xcrun swiftc -typecheck -swift-version 5 -warnings-as-errors -sdk $SDK -target arm64-apple-macos27.0 $S/Capture.swift $S/LumaDiff.swift $S/FileReplay.swift
(no output, exit 0)
$ xcrun clang -fsyntax-only -fobjc-arc -Wall -Werror -isysroot $SDK -target arm64-apple-macos27.0 $S/ObjCSpellings.m     # the Obj-C column
(no output, exit 0)
```
Run result. `LumaDiff` + `replay` were built with `$S/main.swift` and run on the test recording (mask 0.80, 0.74): 30 s at 2280 s: 1799 frames, cost p50 37 µs, p99 101 µs, max 199 µs; 60 s at 2904 s: 3598 frames, p50 39, p99 100, max 228; 30 s at 3792 s: p50 40, p99 115, max 234 (measured, load average about 10). Its diff column is identical to the `probes/luma_mad` trace of the same window. `Capture.swift` was compiled only: the Elgato is not plugged in, so it has never run.

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
Run from `~/Developer/ps5-framegen`. Paste the real output of every command you report.
```
swift build -c release 2>&1 | tail -20                       # zero warnings in the files you touched
swift test 2>&1 | tail -30
python3 probes/cadence_ref.py selftest                       # prints: selftest ok: 6 cases
```
Recorded footage, no Elgato needed (`V="<recording>.mp4"`):
```
mkdir -p runs
xcrun swiftc -O -swift-version 5 probes/luma_mad.swift -o probes/luma_mad         # old reader API: 4 deprecation warnings
probes/luma_mad "$V" 2904 60 runs/trace_2904.csv 0.80 0.74 1920 1080               # frame,pts_s,diff,diff_full,cost_us
python3 probes/cadence_ref.py run runs/trace_2904.csv                              # reference verdicts vs offline two-pass
python3 probes/cadence_ref.py dump runs/trace_2904.csv runs/golden_2904.csv        # golden file for the Swift unit tests
```
- Windows already traced under `probes/out/cadence/` (start s, length): 2280 30 (on foot), 2904 60 (night drive), 3792 30 (day drive, irregular). Reference results (measured): 99.89 %, 100.00 %, 93.10 % agreement with the offline two-pass check. `probes/luma_mad.swift` uses the same 32 x 4 grid as section 2b.
- Swift detector tests: feed the `pts_s,diff` columns of a trace to the detector and compare every row with the golden file (`is_new`, `state`, `flags`). Keep fixtures under `Tests/FrameGenCoreTests/Fixtures/`.
- The Swift replay path must use the reader API of section 3, or the build has warnings.
Live capture (only when the user says the Elgato is plugged in; never start, stop or reconfigure OBS yourself):
```
probes/list_capture                                   # lists devices and formats, opens nothing, no prompt
probes/list_capture --open <uniqueID> 600             # 10 min at 1920x1080 420v; first run raises the camera prompt
probes/list_capture --open <uniqueID> 20 --passive    # next to a running OBS: no lock, no format change
```
Read the first comment of `probes/list_capture.swift` before running it; `--open` without `--passive` changes the format OBS sees. Report the `RESULT`, `delivered buffers` and `timestamp interval` lines. If you cannot run a live step, write "not tested" and the exact command to run later.

## 8. Definition of done
- Live: 10 min capture of a 59.94 Hz signal. For **every** delivered buffer the size, fourcc and IOSurface backing are checked; any change is logged once and counted (`formatChanges`). `videoSettings` is `[:]` so the device delivers its native format. **Every** frame, including one that is already `1920x1080 420v`, is copied into the app's pool by the normaliser (`VTPixelTransferSession`); the device buffer is released before the callback returns; downstream code only ever sees `PoolBuffer`. The copy's cost p50/p99 is reported for the native-1080p case and for the 1440p case. The delivered buffer's transfer-function attachment is logged once and on every change. The active format after start is logged; if it is not the one requested, say so. Drops are reported per reason.
- Every frame lost before the copy (device drop, pool exhausted, unsupported subtype, replay running behind) raises `SourceEvent.framesDropped(firstSequence:count:reason:hostTime:)`; the source's `sequence` counts every frame produced, delivered or not, with no gaps, so the lost frames are `firstSequence ..< firstSequence + count`. A test forces each of the four reasons and checks the sequence has no gap and no repeat across delivered and lost frames.
- Tool: `FrameGen --trace-only <seconds>` writes `runs/<date-time>/cadence.csv` (`frame,pts_s,diff,verdict,state`) from a live capture or with `--replay <file> --start <s>`. This is the trace the offline check reads.
- At least 99.9 % of frames classified the same as the offline two-pass check (`offline_two_pass` in `probes/cadence_ref.py`) on a live uncompressed trace of 10 min or more. On the OBS recording report the percentage per window; there the pass line is: the Swift detector matches the reference golden file on every row.
- Unit tests in `Tests/FrameGenCoreTests` cover, with the expected results of `selftest` in the reference: clean 2:2 (locked at the 9th diff, no phase flip); one dropped frame (lock kept, `droppedSlots` 1, `phaseFlips` 1 when the first copy was lost and 0 when the second was); 60 fps menu (`PASSTHROUGH_60` at the 8th frame, back to `UNKNOWN` at the 7th and `LOCKED_2_2` at the 15th frame of 2:2); static screen (300 identical frames: all `DUP`, state unchanged, 297 `static` flags, first moving frame `NEW`); scene cut (`NEW`, `sceneCut` flag, motion and thresholds unchanged); 3:2-like cadence new-dup-dup-new-dup (verdicts follow content, `UNKNOWN` at the 28th frame, never `PASSTHROUGH_60`).
- Detector cost (sampler plus detector call) p99 below 0.3 ms over at least 10,000 frames, measured inside `FrameGen --trace-only` and written to `counters.txt`. Say what the machine was doing.
- Extra unit tests: a timestamp gap above 0.5 s resets the detector; a gap of at most half a period is **not** filtered out before `ingest`: the detector behaves as `Detector.push` in the reference (counts `timestampAnomalies`, advances one slot, classifies normally), and the fixture asserts the next two verdicts, the state, and that the Conductor keeps the same epoch and pair endpoints; late promotion (the one path with a frame of delay) has its own synthetic case. Rounding matches the Python reference (`round()` there is half-to-even; use `.rounded(.toNearestOrEven)`).
- Builds with zero warnings in the files touched. Tests pass. The output format below is followed.

## 9. Required output format from the implementer
(a) Full contents of every file created, or a unified diff of every file edited.
(b) The exact build and test commands, with their real output pasted.
(c) A measured-numbers table: number, unit, command that produced it, machine load. Estimates go in a separate table labelled "estimate".
(d) A list titled "Not finished". Write "nothing" only if that is true.
