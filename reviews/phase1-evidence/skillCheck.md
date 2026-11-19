# Skill check: vt-interpolation, capture-cadence, metal-present

All three files exist. Every API symbol is correct; I fixed 12 small factual errors. All three still need lead decisions on definition of done and cross-module rules before hand-off.

## Verdicts
| File | Verdict | Why |
|---|---|---|
| `skills/vt-interpolation/SKILL.md` | ready after my fixes for API content; **needs lead attention** | 12 ms target contradicts every measurement; defines presenter behaviour |
| `skills/capture-cadence/SKILL.md` | ready after my fixes; **needs lead attention** | cadence rule text disagreed with `cadence_ref.py` (fixed); some rule branches have no required test |
| `skills/metal-present/SKILL.md` | ready after my fixes; **needs lead attention** | example breaks its own allocation rule; GPU target looks unreachable; no bound on dropped frames |

## Type-check results (measured, Swift 6.4.2, `-target arm64-apple-macos27.0`, after my edits)
Blocks were extracted to `<scratchpad>/skillverify/<skill>/`, where `<scratchpad>` is `<scratchpad>`.

- **Your exact command** (`xcrun swiftc -typecheck -sdk $SDK -target arm64-apple-macos27.0`): exit 0 for `vt-interpolation/block01.swift`, for `capture-cadence/{Capture,LumaDiff,FileReplay}.swift` together, and for `metal-present/block02.swift`.
- **Stricter:** all three also exit 0 with `-swift-version 5 -warnings-as-errors` (vt also with `-strict-concurrency=complete`).
- **Table symbols:** my own `symbols.swift` per skill covers every Swift name in the tables, all 14 error cases with raw values, the HUD symbols and `.mainMenu + 1`. All exit 0 with `-warnings-as-errors`.
- **Obj-C column:** `xcrun clang -fsyntax-only -fobjc-arc -Wall -Werror -isysroot $SDK -target arm64-apple-macos27.0 symbols.m` exits 0 for all three.
- **Negative claims confirmed:**
  - `.inputPriority` is "unavailable in macOS".
  - `availableVideoCVPixelFormatTypes` has no Swift member.
  - Plain `import CoreMediaIO` hides the CMIO keys.
  - The limit calls fail at `macos26.0`.
  - The blocking `process` is absent in Swift.
  - The async warning text matches.
  - The four `AVAssetReader` deprecations appear.
- No wrong spelling or header path found. The non-Swift blocks are shell commands; their arguments match the probes' usage comments.
- `python3 probes/cadence_ref.py selftest` prints `selftest ok: 6 cases`.
- Agreement numbers reproduced: 99.89 %, 100.00 %, 93.10 %.

## Edits made
**vt-interpolation**
1. DoD warning range: was "p50 14.2 to 15.3, p99 15.0 to 20.9"; now p50 12.8 to 15.3, p99 14.3 to 21.1 over 12 saved runs, plus the contended run. `run-10min-during-render.txt` (12.80 / 14.32) had been left out.
2. Scaler timing was the best of 4 runs; now p50 3.43 to 5.09, p99 5.60 to 7.93, max 7.03 to 9.53 ms.
3. `startSession` "60 to 650 ms" is now "35 to 650 ms (77 to 141 at 1080p)", in the text and in the code comment.

**capture-cadence**

4. Rule 1: a time reset uses `n = 1`.
5. Rule 2: step is 1/min(count, 32), and the deviation uses the updated mean. The text said a fixed 1/32, which gives different thresholds from the reference.
6. Rule 3: step is 1/min(count, 16); the motion term counts only after 4 samples.
7. Rule 6: requires `n = 1`.
8. Rule 7: requires `n = 1` and 4 motion samples.
9. Rule 11: the window is also cleared on a time reset.
10. "Duplicate diffs never exactly 0" is true only on foot. The cited driving traces have 1 % and 33 % exact zeros.
11. Added "names are for this example only: PLAN.md decides", as the other two files have.

**metal-present**

12. 2.3: the "must be created with `kCVPixelBufferMetalCompatibilityKey`" rule was wrong and conflicted with capture's `videoSettings = [:]`. Measured with `skillverify/metal-present/metalkey.swift`: an IOSurface 420v buffer without the key gives both plane textures; without an IOSurface the call returns -6660.
13. 2.6: callback CPU time "0.21 / 0.39 ms" matched no saved file; now 0.18 to 0.40 p50, 0.61 to 0.68 p99.

## Cross-file agreement
- Sections 4, 5 and 6 are byte-identical in all three (md5 equal, apart from one capital letter). All defer to PLAN.md, which does not exist yet.
- **Presenter rules in the wrong file.** vt-interpolation says the presenter "takes the midpoint only if ready" and counts `interpLate`. metal-present has a push ring with `duplicate` / `dropped` / `late`. The same event gets two names and two models.
- **"Pass-through" means two things.** In vt it is interpolation off at 30 fps; in cadence `PASSTHROUGH_60` is 60 fps content.
- **Capture buffer ownership is undefined.** capture-cadence warns that holding device buffers causes drops. vt holds the previous frame; the metal example's 8-slot ring never clears shown frames and holds 4 texture pairs. No file gives a limit.
- **metal-present example breaks its own rule.** It creates two `MTLRenderPassDescriptor` per frame, while 2.5 says only the two handler blocks may allocate.

## Claims with no header text and no file under `probes/out`
- **vt:** the grey 60/180 → 156 result and "init + warm-up 169 ms" exist only in the scratch demo. Height not a multiple of 16 as the cause of 12.5 ms is doubtful: 1344x756 ran at 9.58 ms.
- **capture:**
  - The sampler cost table (7, 5 and 17 runs), `hostclock` (I re-ran it: 25.6 µs) and the replay timings live only in scratch `skillcheck/`. That is a temp directory implementers cannot reach, and a reboot clears it.
  - "Hold the lock until `startRunning` returns" is not in the SDK header; the header's sample unlocks before commit.
  - "73 % two slots apart": I get 67.5 % from the cited file.
  - The OBS uniqueIDs and 60000240 are confirmed by a read-only grep of the OBS scenes.
- **metal:** none of these has a saved output file:
  - `preferredFrameLatency` values 0, 0.5 and 3 staying at 2.0;
  - the 60 Hz link landing 8.34 ms late;
  - the parity statistics;
  - half the drawables with `presentedTime == 0` at 120 presents per second;
  - 40.2 / 56.8 ms for 2 / 3 drawables;
  - 0.63 ms convert-only GPU time;
  - the 99.72 % run;
  - the 1728x1117 display mode.

  Crash reports exist for SIGSEGV inside `invalidate()` and for SIGABRT, but "second call" as the cause and the exception text are not in them. Which thread may call `stop()` is unstated.

## Definition-of-done loopholes
**vt-interpolation**
- p99 ≤ 12 ms is failed by all 12 runs, and "idle" has no threshold while ffmpeg jobs always run, so this item can never close.
- The timer's start and stop points and the output file are not named.
- "No heap allocation" is proved only by IOSurface IDs.
- "Preflight and warm-up are present" is inspection, not evidence.
- No required test for 2560x1440, 1920x1072, call after shutdown, busy, pool exhausted, or the rebuild and 30-in-a-row rules (there is no fault-injection hook).
- Nothing checks the output is a real midpoint; returning `previous` passes.

**capture-cadence**
- The DoD says "every delivered buffer", but the example checks only the first.
- No tool is named that writes a live `pts_s,diff` trace.
- No command is given for the 10,000-frame cost run; `luma_mad` times the sampler only.
- Δt > 0.5 s and Δt ≤ period/2 have no required test; late promotion is covered only by the 3792 golden file.
- Python `round()` is half-to-even; Swift `rounded()` is not.
- `offline_two_pass` is itself only 93 % on one window.

**metal-present**
- GPU p99 ≤ 4 ms: MetalFX alone measured p99 4.5 ms in the cleanest run.
- No limit on `dropped`, `late` or `early`, and no `shown + dropped == enqueued` check, so a presenter that discards frames passes.
- Re-presenting an old frame hides `duplicate`.
- The 10-minute run's input and the app's log file are not named.
- The 99.5 % line is redundant: ≤ 40 glitches is stricter.
- Colour match and callback-to-glass latency are not in the DoD.

## Not verified
- Anything on the Elgato: format list, lock behaviour next to OBS, live buffer format, capture pool depth, CMIO attachments.
- OBS running, and the ps5audio helper.
- I did not re-run `present_probe`, `vt_interp_swift` or the timing probes; the numbers above come from saved files, under load (5 to 17 load average, 7 ffmpeg processes at 13:26).
- Full-screen, Low Power Mode off, and the pixel-exact display mode.
- Idle-machine timings of any kind.
- The Metal-key test used a buffer I created, not a capture buffer.
- The line range "16 to 42" in `interp_speed.m` was checked only by eye.
