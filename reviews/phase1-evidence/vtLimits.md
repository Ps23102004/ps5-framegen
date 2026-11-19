# VT + MetalFX limits and scaler timing (M3 Pro, macOS 27.2.1, SDK 27.2)

All numbers **measured** unless marked estimate. All timing is **under load** (cliprift ffmpeg jobs: load avg 13–18 at the start, 4–8 by the end; another agent's `present_probe` overlapped some runs).

## Limits (measured by `vt_limits`)

| Processor | Supported | Size limits | Scale factors | Pixel formats | 1920x1080 |
|---|---|---|---|---|---|
| VTLowLatencyFrameInterpolation | yes | temporal: max dim 1920, max 2,073,600 px. With 2x spatial: max dim 640, max 230,400 px | spatial 2 only (3, 4 return 0) | 420v in, 420v out | config ok, session ok |
| VTLowLatencySuperResolutionScaler | yes | min 96x96, max 1280x1280. 1.5x: dim ≤1280, ≤1,638,400 px. 2x: ≤960, ≤921,600 px. 4x: ≤480, ≤230,400 px | class: 1.5, 2, 4. 1920x1080, 1728x972, 1600x900: none. 1280x720: 1.5. 960x540: 1.5, 2 | 420v in, 420v out | **not possible** |
| VTSuperResolutionScaler | yes | not exposed; config nil at width ≥2560 | 4 only (1080p gives 7680x4320) | RGhA | config ok, model status 2 (ready, 1.00), session ok in 1.0 s |
| VTFrameRateConversion | yes | not exposed | – | RGhA | ok (session start 0.9–5.2 s) |
| VTOpticalFlow | yes | not exposed | – | RGhA in, 2C0h out at 240x135 | ok |
| VTMotionBlur | yes | not exposed | – | RGhA | ok |
| VTTemporalNoiseFilter | yes | min 160x64, max 16384x8192 | – | 16 compressed biplanar formats (`&8v0 &8f0 &xv0 &xf0`, and the `-`, `/`, `\|` variants); needs 1 previous and 2 next frames | ok |
| MetalFX spatial scaler | supportsDevice 1, supportsMetal4FX 1 | every ratio tried was created (1x, 1.8x, 2.7x, 3.6x, 4x, downscale) | free | modes perceptual, linear, HDR. 10 formats work in all three; `*_sRGB` formats only in perceptual | ok |

Traps found:
- **Check the error, not the BOOL.** For an unsupported size, config init returns non-nil and `startSessionWithConfiguration:error:` **returns YES with the error set** (code -12910, "must not exceed 2073600").
- **1920x1072 is rejected, 1920x1080 is accepted.** The error for 1072 reports 1920x1088; other error messages also show padded heights (972→976, 540→544).
- **The interpolator's 2x spatial mode is useless here.** Even 640x360 is rejected (reported as 640x368 > 230,400).
- **First session at a new size costs 2.4–5 s**, then 40–140 ms, also in later processes.

## 3a. VTLowLatencySuperResolutionScaler (ms per call, 300 frames)

1080p input is not allowed: the largest 16:9 output is 1920x1080.

| In → out | p50 | p95 | p99 | max |
|---|---|---|---|---|
| 1280x720 x1.5 → 1920x1080 | 3.43 | 4.20 | 5.60 | 7.03 |
| 960x540 x2 → 1920x1080 | 2.92 | 4.53 | 7.34 | 11.84 |
| 960x540 x1.5 → 1440x810 | 2.79 | 3.42 | 5.40 | 9.07 |

Later runs with GPU contention: p50 2.8–5.1, max 9.5.

## 3b. MetalFX spatial 1920x1080 → 3456x1944 (BGRA8, 300 frames)

| Run | GPU p50 | p95 | p99 | max | Wall p50 / p99 |
|---|---|---|---|---|---|
| 1, no other GPU user | 3.44 | 3.60 | 4.50 | 4.58 | 4.79 / 13.52 |
| 3, mostly quiet | 3.43 | 5.35 | 6.18 | 7.04 | 4.21 / 7.05 |
| 2, `present_probe` running | 3.70 | 7.37 | 9.02 | 9.36 | 4.74 / 9.87 |
| 4, 1080p interpolation at 30 Hz running | 3.46 | 6.80 | 8.01 | 8.48 | 4.28 / 8.82 |

- **Input size does not matter:** 1728x972, 1600x900 and 1280x720 inputs give the same 3.44 ms p50, so cost follows output size.
- **Bimodal under contention:** clusters at about 1.5, 3.44 and 5–8 ms. Estimate: these are GPU clock states plus queueing.

## 3c. VTLowLatencyFrameInterpolation midpoint (60 s from 1500 s, 1798 frames each)

| Size | Back to back, fresh buffers: p50 / p95 / p99 / max | Paced 33.37 ms, pooled buffers: p50 / p95 / p99 / max |
|---|---|---|
| 1920x1080 | 15.32 / 18.36 / 20.94 / 33.77 | 14.51 / 16.35 / 18.28 / 26.00 |
| 1600x900 | 12.55 / 15.60 / 18.69 / 28.62 | 12.24 / 13.48 / 15.91 / 35.55 |
| 1280x720 | 5.24 / 7.68 / 9.52 / 18.62 | 4.84 / 5.25 / 8.04 / 16.75 |

- **Extra sizes, p50 (20 s runs):** 1024x576 3.36, 960x540 4.68, 1280x720 5.1–5.3, 1344x756 9.58, 1536x864 9.73, 1600x896 10.28, 1440x816 10.57, 1600x900 12.35, 1440x810 12.59, 1728x972 13.92, 1792x1008 14.35, 1920x1080 14.5–15.2.
- **Not bimodal:** each run has a single hump; 720p has a 4.6% tail above 1.5x p50.
- **Pacing does not slow it down.** One call per 33 ms is no slower than back to back.
- **Contention slows it.** 1080p paced, with `vt_limits` running in a second process: p50 17.88, p95 21.01, p99 41.82, max 61.65. Quiet stretches sat at 14.4, contended ones at 18–19.
- **Slower than this morning.** The earlier 1080p baseline was p50 12.80; today it is 14.5–15.3.

## Read

1. **VT low-latency super resolution is not usable for 1080p → display.** Input is capped at 1280 px per side and output at 1920x1080 for 16:9. Use the MetalFX spatial scaler: about 3.4 ms GPU (up to 9 ms contended) for any input size to 3456x1944.
2. **Interpolation time moves in steps, not with pixel count.**
   - Up to 720p (0.92 MP): about 5 ms.
   - 1.0–1.45 MP: about 10 ms, or about 12.5 ms when the height is not a multiple of 16.
   - 1.7–2.07 MP: 14–15 ms.
   - So 1080p → 900p saves only 2–3 ms (4.5 ms at 1600x896), while 1080p → 720p saves about 10 ms (65%).
3. **Budget at 1080p (estimate):** interpolation p99 18 ms plus MetalFX p99 up to 9 ms is about 27 ms, inside the 35 ms target. Expect about 18 ms p50 for interpolation once the app's own scaling and presenting share the GPU.

## Commands

```
cd ~/Developer/ps5-framegen/probes
clang -fobjc-arc -O2 -Wno-deprecated-declarations vt_limits.m -o vt_limits -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreGraphics -framework Metal -framework MetalFX -framework QuartzCore -framework AVFoundation -framework CoreImage -framework IOSurface
./vt_limits "<recording>.mp4" 1500 out > out/vt_limits.txt 2> out/vt_limits.stderr.txt
clang -fobjc-arc -O2 -Wno-deprecated-declarations interp_speed_res.m -o interp_speed_res -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework QuartzCore
./interp_speed_res <video> 1500 60 <W> <H> [pace_ms=0] [reuse=0]     # e.g. 1920 1080 33.37 1
```

`vt_limits` with no arguments prints limits only.

## Files (all under ~/Developer/ps5-framegen/probes)
- vt_limits.m, vt_limits
- interp_speed_res.m, interp_speed_res
- out/vt_limits.txt (runs 2–4 raw; run 1 timing lines were copied in from the console after run 2 overwrote the file)
- out/vt_limits.stderr.txt
- out/interp_speed_res.txt (sections A–G)
- out/llsr_*.jpg, out/metalfx_*_to_3456x1944.jpg, out/scaler_source_*.jpg (frame 160 of each scaler run)

## Not verified
- **Image quality.** I viewed one MetalFX crop to confirm it is a real picture; the LLSR JPEGs were not inspected and no scalers were compared.
- **Idle-machine numbers.** Every figure is under load, and the load changed during the session.
- **Height-multiple-of-16 gain (about 2 ms).** It is confounded by load dropping about 3% between those runs.
- **Why 1920x1080 passes while 1920x1072 fails,** and the exact padding rule.
- **The 1.5 ms MetalFX cluster as a GPU clock state** is an inference.
- **Whether VT interpolation runs on the GPU or the Neural Engine.**
- **The contention p99 of 41.8 and max of 61.7 ms** include time when the other process was loading models, not only scaling.
- **Costs outside the timers:** the NV12 → BGRA conversion MetalFX needs, and MetalFX writing straight into a CAMetalLayer drawable.
- **Untested API paths:** `processWithCommandBuffer:` and the async calls.
- **10-bit or HDR input.** The interpolator lists only 420v.
- **Maximum sizes for FrameRateConversion, OpticalFlow, MotionBlur and SuperResolution height.** No API exposes them and no session sweep was run.
- **Anything with the Elgato or OBS.** Not tested.