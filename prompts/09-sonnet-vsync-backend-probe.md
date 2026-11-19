# Task: add a second present backend (`--mode vsync`) to `probes/present_probe.swift`

You are the implementer for one bounded task on a macOS project. You cannot see the lead's conversation; everything you need is here and in the files named.

## Read first
1. `~/Developer/ps5-framegen/skills/metal-present/SKILL.md`: section 1a, section 4 (conventions), section 5 (banned). Section 1a wins over anything below it.
2. `~/Developer/ps5-framegen/probes/present_probe.swift`: the file you edit. Its first comment has the build command and every flag. Read all of it before changing anything; the counter source, the slot reservation (`SlotGrid`, `Pacer`), the per-slot CSV and the G1 report already exist and you reuse them.
3. SDK headers, to confirm every API you call instead of trusting memory:
   `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/QuartzCore.framework/Headers/CADisplayLink.h`, `CAMetalLayer.h`, and `AppKit.framework/Headers/NSScreen.h` (`displayLink(target:selector:)`).

## Context: what was measured and why this task exists
The project shows 30 fps console gameplay at 60 fps on a MacBook Pro (M3 Pro, built-in 3456×2234 panel). The display path must add as little delay as possible. Gate G1 measured the existing backend (`CAMetalDisplayLink`, `--mode link`) in full screen, on mains power, Low Power Mode off, 2026-11-19:

| Display mode | callback → reported presentation, p50 | `targetTimestamp` − callback | `targetPresentationTimestamp` − `targetTimestamp` |
|---|---|---|---|
| 3456×2234 at 120 Hz | 41.6 ms | about 8.3 ms | 33.33 ms |
| 3456×2234 at 59.94 Hz | 49.9 ms | about 16.5 ms | 33.37 ms |

`preferredFrameLatency = 1` was applied (read back as 1.0) and changed nothing. The bar is 20 ms at p99. So the display link hands out drawables about 33 ms ahead of the glass in both modes, and no setting found so far shortens that.

Hypothesis to test, not a known fact: a plain `CAMetalLayer` (no `CAMetalDisplayLink`), driven by a vsync clock, that takes a drawable with `nextDrawable()` as late as it safely can and presents it with `present(_:)` or `present(_:atTime:)`, reaches the glass sooner. The existing `--mode next` cannot answer this because it free-runs and fills the drawable queue (measured 47.9 ms).

## What to add (edit only `probes/present_probe.swift`)
1. **`--mode vsync`.** No `CAMetalDisplayLink` is created in this mode.
   - Clock: a `CADisplayLink` made with the chosen `NSScreen`'s `displayLink(target:selector:)`, `preferredFrameRateRange` = `--link-hz` (min = max = preferred), added to the run loop selected by the existing `--runloop thread|main` flag in `.common` mode.
   - One tick = one slot. Slot time = the link's `targetTimestamp` (the next vsync). The slot index advances by `max(1, round(gap / S))` between ticks, exactly as the display-link mode does now, so a missed tick still advances the index. `S` and the grid are fitted the same way as now (median of the last 120 differences), from `targetTimestamp`.
   - `--source counter` must work in this mode with the same reservation code and the same rule (do not copy or fork the `Pacer`).
   - In each tick, in this order: (a) if `--render-delay-ms D` > 0 (default 0), wait until tick time + D with `mach_wait_until`; (b) record the **pick time** and choose the position reserved for this slot; if none, record `held` and return without taking a drawable; (c) call `layer.nextDrawable()` and record how long it blocked (`layer.allowsNextDrawableTimeout = true`; `nil` → outcome `skipped`); (d) encode the same pipeline as the display-link path (video texture → BT.709 → MetalFX → drawable, HUD if on); (e) present according to `--present plain|at-slot`: `plain` = `commandBuffer.present(drawable)`, `at-slot` = `commandBuffer.present(drawable, atTime: slotTime)`; (f) commit. `presentedTime` is read in `addPresentedHandler` as now.
   - `present(_:atTime:)` is allowed here because there is no `CAMetalDisplayLink` on this layer. It stays banned in `--mode link`.
   - The per-slot CSV keeps its 8 columns. In this mode `callback_time` holds the pick time (after the delay). Say so in the usage comment.
2. **`--colorspace srgb|p3|none`** (default `srgb`, today's behaviour): sets `layer.colorspace` to sRGB, Display P3, or `nil`. Works in every mode. Print the value in the `config:` line.
3. **Report**, for `--source counter` in any mode:
   - latency = `presented_time − callback_time` now **excludes the first 2.0 s**, like the content intervals already do (today it includes start-up, which put p99 at 66.6 ms on a run whose steady state is 49.9 ms). Keep printing n, p50, p99, max.
   - new line: `presented_time − slot time` (target of the slot the row belongs to): p50, p99, max, and the count of rows more than half a slot late.
   - in `--mode vsync` only: `nextDrawable()` wait: p50, p99, max, and the count of `nil` drawables.
   - the final `G1 RESULT:` line gains ` mode=<link|vsync> present=<n/a|plain|at-slot> render_delay_ms=<D>` at the end. Its existing three fields stay first and unchanged in format.
4. Update the usage comment at the top of the file.

## Constraints
- Edit only `~/Developer/ps5-framegen/probes/present_probe.swift`. Rebuild `probes/present_probe` with the build command in its first comment. Scratch files only under `$TMPDIR`.
- Existing flags and behaviour must keep working, in particular `--mode link --source counter`, `--source index`, `--pacer-selftest`, the locked-screen guard and the display-awake activity near `applyDisplayMode`.
- No heap allocation in the tick beyond what the display-link path already does; no file I/O and no `print` in the tick.
- **Do not run `--window full`. Do not run `--display-mode native120` or `native5994`.** They take over the user's screen; the lead runs them. You run small-window runs with `--display-mode keep` only.
- Do not start, stop or change OBS. Do not touch `~/Developer/cliprift-studio`. ffmpeg processes from that project are running: never kill or renice them. No installs. Do not open any capture device. Do not change any system setting.
- Banned: placeholders, TODO stubs, "simplified version", hard-coded or fake results, skipped error handling, claiming a run you did not paste.

## How to verify (do all of it, paste real output)
`V="<recording>.mp4"`
1. Build. Zero errors. Report warnings in lines you touched.
2. `probes/present_probe --pacer-selftest`: paste it. The six `fnv=` values must be the same as before your change (run it once before you edit and keep the output).
3. Four small-window runs, 20 s each, `--link-hz 120 --source counter --display-mode keep --window small --video "$V" --start 2904 --mode vsync` with: `--present plain`; `--present at-slot`; `--present plain --render-delay-ms 4`; `--present at-slot --render-delay-ms 4`. Paste each report from the `---- G1 report` line to the end.
4. One unchanged-behaviour run: the same flags with `--mode link` (no `--present`). Paste its report. Latency p50 should be near 49.9 ms in a small window; say if it is not.
5. `--colorspace none` and `--colorspace p3` once each with `--mode link`, 8 s: paste the `config:` line and the latency line.

## Output format (required)
(a) A unified diff of `probes/present_probe.swift`.
(b) Each command from "How to verify" with its real output.
(c) One table: mode, present, render delay, latency p50 / p99, presented − slot p50 / p99, in-band %, max glitches per 15 s, `nextDrawable` wait p99, for the runs in step 3 and 4. Head it "small window, composited: not the gate condition".
(d) A list titled "Not finished". Write "nothing" only if that is true. Full-screen and native-mode runs belong here as "not run by instruction".
(e) Anything in the SDK headers that contradicts this brief.
