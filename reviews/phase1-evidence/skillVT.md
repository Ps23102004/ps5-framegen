# vt-interpolation skill: written and verified

**File:** `~/Developer/ps5-framegen/skills/vt-interpolation/SKILL.md` (341 lines, all 9 sections in order).

**Type-check (code block extracted back out of the skill file):**
```
xcrun swiftc -typecheck -swift-version 5 -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -target arm64-apple-macos27.0 MidpointInterpolator.swift
→ no output, exit 0
```
- It also passes `-strict-concurrency=complete -warnings-as-errors` (exit 0).
- Target `macos27.0` is required: with `macos26.0` the two limit calls fail ("only available in macOS 27.0 or newer").
- Every other symbol named in the skill (scaler, `await` form, `AsyncSequence` form, all 14 error cases) type-checks in `surface.swift`, exit 0.
- The example was also built and run: init plus warm-up 169 ms, 5 calls at 13.8–14.8 ms, handler off the main thread. 2560x1440 is caught by the preflight, 1920x1072 by the warm-up (-19730).

All timing below is **measured, under load** (load average 3–10, ffmpeg jobs untouched). Raw output: `probes/out/vt_interp_swift.txt`.

## Surprises and contradictions with the starting design

1. **The blocking process call does not exist in Swift.** `processWithParameters:error:` is `NS_SWIFT_UNAVAILABLE`. Swift must use the completion handler, `await`, or the Metal command-buffer form.
   - The handler form returns in 0.01 ms (max 0.15). The handler runs on VideoToolbox's own serial queue, never on main (0 of 899).
   - Cost is the same on all three routes at 1080p, paced 33.37 ms, 899 calls each:

     | Route | p50 | p99 | max |
     |---|---|---|---|
     | Completion handler | 14.38 | 15.07 | 15.75 |
     | `await` | 14.19 | 15.04 | 15.45 |
     | Command buffer plus wait | 14.47 | 15.28 | 16.15 |

   - A second handler run had max 55.04.
   - 720p handler: p50 4.95, p99 6.70.
2. **The DoD "p99 ≤ 12 ms at 1080p" has never been met.** Every run has p50 14.2–15.3 and p99 15.0–20.9, so even the median is above the bar. The skill keeps your number with a warning to report and stop. You need to pick one:
   - relax the bar to about 16–18 ms;
   - drop to 1600x896 (p50 10.3);
   - drop to 1280x720 (p50 5).
3. **`try startSession` does not throw for a bad size.** Obj-C returns YES with the error set, so Swift sees success. The next process call fails with -19730 "Processor is not initialized". The skill mandates a preflight limit check plus a warm-up call.
4. **A process call after `endSession()` crashes with SIGSEGV** in `-[VTFrameProcessor captureTelemetryFromParametersIfNeeded:]`. Calling `startSession` again on the same object does not throw, and the next process call still crashes. Recovery needs a new `VTFrameProcessor` (start 61–75 ms).
5. **A never-started processor reports no error and writes nothing.** A nil error is not proof of a frame.
6. **`420f` (full range) is rejected**, as are 10-bit and BGRA, with -19740 in 0.1 ms. This is `.processingError`, not `.unsupportedInput`. The session survives. The capture path must deliver `420v` or convert.
7. **Plain 1920x1080 `420v` IOSurface buffers work** without the configuration's attributes (extended pixels are 0), so zero-copy from capture is possible.
8. **Timestamps are not validated.** Reversed, equal and `CMTime.invalid` were all accepted. `.invalidFrameTiming` was never seen.
9. **Calls run one at a time.** Two sent together finished at 14.6 and 29.0 ms. The skill mandates one call in flight and a `busy` counter.
10. **`endSession()` blocks for the call in flight** (15.3 ms). There is no cancel call in the header.
11. **The first process call in a process is slow:** 32–34 ms against 14 ms.
12. **"No per-frame heap allocation" cannot be literal.** Each call needs 3 `VTFrameProcessorFrame`, 1 parameters object, 2 arrays and 1 closure. The skill exempts these and defines the proof as distinct IOSurface IDs ≤ pool size.
13. **The command-buffer form works**, with 0.04 ms to encode. Chaining interpolation and MetalFX in one command buffer is possible; I left that as a PLAN decision.
14. **The output is not the average of the inputs.** Flat grey 60 and 180 gave 156.
15. **The handler form inside `async` code triggers a compiler warning**, which breaks zero warnings. Call it from a synchronous function.
16. **`AVAssetReader.add`, `startReading` and `copyNextSampleBuffer` are deprecated in macOS 27.** This affects the offline-footage mode under the zero-warnings rule.
17. **VT low-latency super resolution cannot take 1080p.** It is documented in the skill as optional, for a 720p pipeline only.

Restart and pass-through thresholds in the skill (30 consecutive failures, 3 rebuilds in 60 s) are my defaults; the skill says PLAN.md wins.

## Files created
- `~/Developer/ps5-framegen/skills/vt-interpolation/SKILL.md`
- `~/Developer/ps5-framegen/probes/vt_interp_swift.swift` and its binary `vt_interp_swift`
- `~/Developer/ps5-framegen/probes/out/vt_interp_swift.txt`
- Proof files in `<scratchpad>`: `MidpointInterpolator.swift`, `main.swift`, `surface.swift`, `demo`

## Not verified
- **Idle-machine numbers**, and the 10-minute run. The longest Swift run was 30 s per mode.
- **Real capture buffers.** Whether the Elgato delivers `420v` 1920x1080 IOSurface-backed buffers is not tested.
- **Colour attachments** on the destination buffers (matrix and range) were not checked.
- **Timestamp and phase effects on the picture.** Phase 0.25 on a 1-frame configuration returned no error; I did not look at its output.
- **Image quality**, including scene cuts and flashes, and why flat grey gives 156.
- **Command-buffer error reporting**, and chaining with MetalFX.
- **The `AsyncSequence` form** was type-checked only.
- **The scaler's traps.** The crash and silent-start behaviour were measured on the interpolator only.
- **Error codes** -19731 to -19739 and -19741 to -19743 were never produced; their actions in the skill come from the header text.
- **Whether a second `startSession` on an active session errors in Obj-C.** Swift did not throw.
- **Why 1920x1072 fails** while 1920x1080 passes.
- **GPU or Neural Engine.** The command-buffer path working suggests GPU, but that is an inference.
- **The AVAssetReader replacement calls** were not type-checked.
- **PLAN.md does not exist yet**, so the example's names are illustrative.