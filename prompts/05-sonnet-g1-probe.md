# Task: extend `probes/present_probe.swift` so it can run gate G1

You are the implementer for one bounded task on a macOS project. You cannot see the lead's conversation; everything you need is here and in the files named.

## Read first
1. `~/Developer/ps5-framegen/skills/metal-present/SKILL.md` — the skill file. Follow its API facts, section 4 (conventions) and section 5 (banned). Section 1a wins over anything below it.
2. `~/Developer/ps5-framegen/PLAN.md` — section 4 (gate G1 row), section 5.2 (the pacer rule) and section 5.3 (display mode).
3. `~/Developer/ps5-framegen/probes/pacer_sim.py` — the executable reference for the slot rule. Your Swift must produce the same slot sequence for the same inputs.
4. `~/Developer/ps5-framegen/probes/present_probe.swift` — the file you edit. Its first comment has the build command.

## Context
The project shows 30 fps console gameplay at 60 fps on a MacBook Pro (M3 Pro, built-in 3456×2234 panel, 120 Hz ProMotion; fixed modes 120, 60, 59.94, 50, 48, 47.95 Hz exist at 3456×2234; the display is currently in a scaled mode, 4112×2658 backing). Gate G1 measures the display path alone, before any app code: how long from the display-link callback to the reported presentation time, and how evenly 59.94 Hz content can be shown, in two display modes. The existing probe measures a 60.000 Hz frame index (`floor((target − t0) × 60)`), which is the wrong content clock, and it cannot switch display mode or log per slot.

## What to add (edit only `probes/present_probe.swift`)
1. **`--source counter`** (keep the existing behaviour as `--source index`, the default).
   - Content is a sequence of positions `i = 0, 1, 2, …` with content time `c_i = t0 + i × H`, `H = 1001/60000` s, on the host clock (`CACurrentMediaTime()`), `t0` = the time of the first callback.
   - Each position is reserved a slot by the rule in PLAN.md section 5.2 with `base = 0`, `N = 0`, `ε = 1.5 ms`, step = 2 slots when the link runs at 120 Hz and 1 when it runs near 59.94 Hz. Port `run()` from `probes/pacer_sim.py` exactly: first position by ceiling; later positions try `previous + step` and keep it only when its time lies in `[g, g + S + 2ε)`, else recompute the ceiling; a reservation never moves; odd positions are droppable (count `collision`), even positions are pushed to `last + 1` (count `pushedLate`) and the next odd position is skipped (count `catchUpSkip`).
   - The slot grid is not a constant: slot index = a counter of display-link callbacks; slot time = that callback's `targetPresentationTimestamp`; the period `S` = median of the last 120 differences between consecutive `targetPresentationTimestamp` values; time of a future slot `k` = latest observed slot time + `(k − latest index) × S`. Positions are reserved as soon as their content time is within 100 ms of now (so reservations exist before their slot comes up).
   - In each callback: if a position is reserved for this slot, draw it (use the cached video frame `id % frameCount` as the picture so GPU load is realistic, plus a vertical bar whose x position is `id % 240` steps across the picture so a camera can see content change) and record `shown id`; otherwise re-present nothing new: skip presenting for this callback and record `held` with the previous id.
2. **`--display-mode keep|native120|native5994`** (default `keep`). For the two `native…` values: find the built-in display's mode with pixel size 3456×2234 and refresh 120 or 59.94 (match within 0.01 Hz) via `CGDisplayCopyAllDisplayModes` (pass `kCGDisplayShowDuplicateLowResolutionModes: true`), apply it with `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(config, .forAppOnly)`, then read back `CGDisplayCopyDisplayMode` and print the mode actually applied. On any failure print `DISPLAY MODE NOT APPLIED: <reason>` and continue in the current mode. Create the window after the switch so it takes the new screen frame. Never use `.permanently` or `.forSession`.
3. **`--slots-csv <path>`**: one row per display-link callback: `slot,target_time,callback_time,outcome,content_id,gpu_start,gpu_end,presented_time`. `outcome` is `shown`, `held` or `skipped` (no drawable). Times in seconds, 6 decimals. `presented_time` 0 is kept as 0. Rows are buffered in a preallocated array and written at exit, not from the callback.
4. **End-of-run report for `--source counter`**, computed from the same rows:
   - display mode applied; link rate; step; `S` median; `pmset -g batt` first line; `pmset -g | grep lowpowermode`; load average (`getloadavg`).
   - latency = `presented_time − callback_time` over shown rows with non-zero presented time: p50, p99, max.
   - **content intervals** = difference of `presented_time` between consecutive shown rows whose content ids differ (non-zero times only, first 2 s excluded): count, % within 16.683 ± 2 ms, list of out-of-band intervals (cap the printed list at 40), and the **largest number of out-of-band intervals in any rolling 15 s window**.
   - counts: shown, held, skipped, `presented_time == 0`, corrections, `collision`, `pushedLate`, `catchUpSkip`, positions reserved, positions never shown.
   - a final line `G1 RESULT: latency_p99_ms=<x> in_band_pct=<y> max_glitches_per_15s=<z>`.
5. **`--mode next`** (the loop without a display link): start the latency timer before `nextDrawable()` is called, not after it returns. Print `DIAGNOSTIC ONLY: no slot grid` at the top of its report. `--source counter` is not required to work in this mode; if both are given, exit with a clear message.
6. Update the usage comment at the top of the file with the new flags.

## Constraints
- Edit only `~/Developer/ps5-framegen/probes/present_probe.swift`. Rebuild `probes/present_probe` with the build command in its first comment. Do not create other files except a scratch CSV under your temp directory.
- Existing flags and the existing `--source index` behaviour must keep working.
- No `present(atTime:)` and no `present(afterMinimumDuration:)` in display-link mode (they abort the process).
- No heap allocation in the callback beyond what the existing code already does; no file I/O or `print` in the callback.
- **Do not run `--window full`. Do not run `--display-mode native120` or `native5994`.** Those take over or reconfigure the user's screen; the lead runs them. You run only small-window runs with `--display-mode keep`.
- Do not start, stop or change OBS. Do not touch `~/Developer/cliprift-studio`. ffmpeg processes from that project are running: never kill or renice them. No installs. Do not open any capture device.
- Banned: placeholders, TODO stubs, "simplified version", hard-coded or fake results, skipped error handling, claiming a run you did not paste.

## How to verify (do all of it, paste real output)
1. Build with the command in the file's first comment. Zero errors. Report warnings in lines you touched.
2. `probes/present_probe --seconds 20 --link-hz 120 --present-every 1 --source counter --display-mode keep --window small --video "<recording>.mp4" --start 2904 --slots-csv "$TMPDIR/g1_small.csv"` — paste the full report.
3. Check the slot rule against the reference: add a hidden flag `--pacer-selftest` that runs your Swift reservation function on a synthetic grid (S = 1000/120 ms and S = H × (1 + 50e-6)) for 10 simulated minutes at starting phases 0.0, 0.3 and 0.8 of a slot with ± 1 ms alternating jitter, and prints for each case: corrections, dropped, pushed, any slot before `g`, any shared slot. Expected from `python3 probes/pacer_sim.py`: at 120 Hz about 72 corrections and none dropped; on the matched grid at most 3 corrections and 2 dropped; never early, never shared. Paste both outputs.
4. One existing-behaviour run: `probes/present_probe --seconds 8 --link-hz 120 --present-every 2 --window small` — paste the last 6 lines.
5. `head -5 "$TMPDIR/g1_small.csv"` and the row count.

## Output format (required)
(a) A unified diff of `probes/present_probe.swift` (or the full file if the diff is larger than the file).
(b) Each command from "How to verify" with its real output.
(c) A table of the measured numbers from step 2, with the machine state lines.
(d) A list titled "Not finished". Write "nothing" only if that is true. Full-screen and native-mode runs belong here as "not run by instruction".
