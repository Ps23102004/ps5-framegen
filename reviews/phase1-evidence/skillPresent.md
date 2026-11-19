# metal-present skill: written, type-checked, run

**Skill file:** `~/Developer/ps5-framegen/skills/metal-present/SKILL.md` (353 lines, all 9 sections in the required order)
**Probe added:** `~/Developer/ps5-framegen/probes/present_probe.swift` (+ binary `probes/present_probe`; build command in its first comment)
**Logs:** `~/Developer/ps5-framegen/probes/out/present_probe-60s-hud1-underload.txt`, `...-hud0-underload.txt`

## Type-check
The Swift block was extracted back out of SKILL.md and checked as printed:
```
xcrun swiftc -typecheck -swift-version 5 -warnings-as-errors -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 from_skill.swift
```
Result: exit 0, no output, zero warnings (Swift 6.4.2, target macos27.0, no need to lower it).
- The same code also ran for 8 s with a 60 fps producer: `callbacks=957 shown=466 duplicate=8 dropped=1 late=10 early=1 skippedByDisplay=4 renderFailures=0 parityFlips=1`.
- HUD symbols (CoreText to texture, `Atomic`, key monitor) are proven by the probe, which builds and runs.
- Check files are in `<scratchpad>` (`example.swift`, `from_skill.swift`, `main.swift`).

## Conditions for every number below
All measured with `probes/present_probe` on 2026-11-19: under load (6-15 ffmpeg, load average 4-18), **Low Power Mode ON** (`pmset -g`: `lowpowermode 1`), small composited window (432x279 pt), drawable 4112x2658. No full-screen run.

## Surprises that contradict the starting design
1. **`present(atTime:)` and `present(afterMinimumDuration:)` abort the process with a display link.** Exception `CAMetalDrawableInvalidOperation`: "-presentAtTime should not be called when using CAMetalDisplayLink." Scope item 5 cannot be done as written; timing is set only by which callback you present in.
2. **Display-link latency floor is high.** Callback to glass is 41.6 ms (120 Hz link, present every 2nd callback) or 58.2 ms (60 Hz link: 49.9 ms lead + 8.34 ms late, 3 of 3 runs). A plain `nextDrawable()` loop is no better: 40.2 ms with 2 drawables, 56.8 ms with 3. This eats most of the 60 ms budget unless full screen with Low Power Mode off is faster.
3. **`preferredFrameLatency` did nothing.** Default is 2.0; 1 is accepted; 0, 0.5 and 3 silently read back 2.0; 1 vs 2 gave identical timing. The header has no comments at all.
4. **A 60 Hz link is on the wrong phase.** A 120 Hz link presenting every 2nd callback lands 0.01 ms from target on the right parity and 8.33 ms late on the wrong one (3 of 4 runs started wrong). The skill prescribes a phase lock (flip after 8 late presents); with it, 6 of 6 runs ended at 0.00 ms error.
5. **The display path accepted only 60 presents/s.** Presenting in every 120 Hz callback gave `presentedTime == 0` for half the drawables. Cause not isolated: Low Power Mode, the small window, or load.
6. **The Mac is in a scaled display mode.** It runs 2056x1329 pt @2x (4112x2658 backing) on the 3456x2234 panel, so 3456x1944 is not pixel-exact now. The mode 1728x1117 pt (3456x2234 px, 120 Hz) exists. Someone must decide: the user switches to "Default", or the app switches mode.
7. **The GPU limit is not met in these conditions.**

   | Stage | p50 | p99 |
   |---|---|---|
   | Convert + final pass | 0.63 ms | not recorded |
   | + MetalFX scaler | 3.9-4.8 ms | 4.1-6.1 ms |
   | + HUD | 4.5-4.7 ms | 4.9-9.2 ms |

   The limit is p99 <= 4 ms.
8. **The glitch limit is not reliably met.** Four 60 s runs on the GTA recording gave 99.94 / 99.72 / 99.47 / 99.94 % of intervals within 16.67 +- 2 ms, with 2 / 10 / 19 / 2 glitches. The limit is 4 per 60 s.
9. **Scaler usage bits force an extra pass.** Output needs `[.shaderRead, .renderTarget]`, so it cannot write into a `framebufferOnly` drawable. The skill scales into a private texture and draws that with letterbox bars.
10. **A second `invalidate()` crashes** (SIGSEGV in `CAMetalLayerSetMetalLinkToken`).
11. **For the capture skill:** macOS 27 deprecates `AVAssetReader.add`, `startReading`, `copyNextSampleBuffer` and `alwaysCopiesSampleData`. File-replay code using them will fail the zero-warnings rule.

## Confirmed as designed
- The callback arrives on the run-loop thread it was added to (0 of 7437 elsewhere).
- Skipping a callback's drawable is harmless.
- `maximumDrawableCount = 2` works with the link.
- The BT.709 video-range matrix matches vImage with 0 difference on 8 colour bars.
- The recording decodes to IOSurface-backed 420v tagged `ITU_R_709_2`.
- Callback CPU time is 0.21 ms p50, 0.39 ms p99.

## Choices I made that you may want to change
- HUD on/off test is defined as alternating 60 s blocks inside one run, both meeting the pacing limits.
- Counter definitions (`late` = more than 16.67 + 2 ms after target, `early` = more than 2 ms before) apply "unless PLAN.md says otherwise".
- A duplicate slot does not re-present, so it shows up as a 33 ms interval.
- `layer.colorspace` is sRGB, kept as a named setting.
- The example's `ExampleFrame` is marked example-only and defers to PLAN.md.

## Not verified
- Full-screen borderless window: latency, pacing, direct-to-display. `--window full` compiles but was not run because it takes over the screen. Command: `probes/present_probe --seconds 600 --link-hz 120 --present-every 2 --window full --video "<recording>" --start 600`.
- Anything with Low Power Mode off, without the ffmpeg load, or in the 1728x1117 display mode.
- Whether the 60 presents/s cap comes from Low Power Mode.
- The 10 min definition-of-done run; the longest run was 62 s.
- Why the HUD costs about 0.6 ms of GPU time.
- The single `dropped=1` and `early=1` in the example run. The 60 s probe logs also show occasional presents 8.33 ms before target.
- sRGB vs `itur_709` layer colour space against the TV.
- Chroma siting (the shader samples chroma bilinearly as if centred).
- Mixing `nextDrawable()` with the link; native full screen; external displays; sleep/wake; display reconfiguration.
- The `CVMetalTextureCacheFlush` cadence (header says "periodically"; once per second is my estimate).
- Elgato live input: not plugged in, not tested.
- The app's file-replay command: the skill defers to PLAN.md, which I did not see.