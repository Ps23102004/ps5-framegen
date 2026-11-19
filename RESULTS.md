# RESULTS

Numbers only. Each row names the file that holds the raw output. Machine state for everything below unless a row says otherwise: MacBook Pro M3 Pro, macOS 27.2.1, **under load** (six ffmpeg jobs from another project, load average 4–18), **Low Power Mode on, on battery** (checked 13:32; power source during the morning run unknown), Elgato not plugged in, OBS not running.

## Phase 1 (2026-11-19)

### Acceptance
| Test | Bar | Result | Status |
|---|---|---|---|
| Models: GPT 6.2 Sol and GPT 6.2 Astra reachable | both | `gpt-6.2-sol`, `gpt-6.2-astra` through `codex exec -m` | **pass** |
| Interpolation speed re-run on an idle machine | p99 ≤ 12 ms at 1080p | not run: machine never idle today | **not done** |
| Same test under load | – | p50 12.8–15.3, p99 14.3–21.1 (12 runs) | above the bar in every run |
| PLAN.md + Astra review | – | see `reviews/` | see MODELS_LOG.md |
| Skill files | – | 4 written, APIs type-checked against the SDK | **pass** |

### Interpolation, `VTLowLatencyFrameInterpolation`, one midpoint (ms per call)
| Size | Mode | p50 | p95 | p99 | max | File |
|---|---|---|---|---|---|---|
| 1920×1080 | back to back, 10 min of footage in 271 s wall, morning, power source and Low Power Mode unknown | 12.80 | 13.54 | 14.32 | 130.82 | `probes/out/run-10min-during-render.txt` |
| 1920×1080 | paced 33.37 ms, pooled buffers, 60 s | 14.51 | 16.35 | 18.28 | 26.00 | `probes/out/interp_speed_res.txt` |
| 1920×1080 | Swift completion handler, paced, 30 s | 14.38 | – | 15.07 | 15.75 | `probes/out/vt_interp_swift.txt` |
| 1920×1080 | paced, second GPU process running | 17.88 | 21.01 | 41.82 | 61.65 | `probes/out/interp_speed_res.txt` |
| 1920×1080 | paced 33.37 ms, pooled buffers, 120 s, **AC power, Low Power Mode off**, 10 ffmpeg jobs running (load average 4–5), 16:09 | 18.13 | 21.01 | 22.31 | 25.47 | `probes/out/interp_speed_ac_lpmoff_underload.txt` |
| 1600×900 | paced | 12.24 | 13.48 | 15.91 | 35.55 | same |
| 1600×896 | back to back, 8 s | 10.28 | 11.09 | 12.32 | 14.33 | same |
| 1280×720 | paced | 4.84 | 5.25 | 8.04 | 16.75 | same |

Session start at 1080p: 63–141 ms across probes; the first session at a size not used before took 2.4–5 s in these runs (observed, not a rule). First call in a process 32–34 ms. 1920×1072 is rejected (`interp_speed_res.txt`).

### Limits (`probes/out/vt_limits.txt`)
| Processor | Limit |
|---|---|
| Low-latency interpolation | 1920 px max side, 2,073,600 px, `420v` only. 1920×1072 rejected, 1920×1080 accepted. Its 2× upscale mode: 640 px max, unusable. |
| Low-latency super resolution | input max 1280 px per side; 1080p input refused. Largest 16:9 result 1920×1080. |
| Super resolution (normal) | 4× only |
| MetalFX spatial scaler | every ratio tested worked (1×, 1.8×, 2.7×, 3.6×, 4×, downscale); 1080p → 3456×1944 works |

### Scalers and render (GPU ms per frame, 3456×1944 output)
| Path | p50 | p99 | File |
|---|---|---|---|
| Convert + bilinear | 0.63 | not recorded | `skills/metal-present/SKILL.md` §2.6 (no saved raw file) |
| MetalFX spatial, GPU otherwise quiet | 3.44 | 4.50 | `probes/out/vt_limits.txt` (copied in from the console after a later run overwrote the file) |
| MetalFX spatial, GPU shared | 3.46–3.70 | 8.01–9.02 | same |
| Convert + MetalFX + HUD in the present probe | 4.60 | 9.15 | `probes/out/present_probe-60s-hud1-underload.txt` |
| Convert + MetalFX, HUD off | 4.77 | 6.10 | `probes/out/present_probe-60s-hud0-underload.txt` |

### Display path (`probes/present_probe`, small window 432×279 pt, scaled display mode)
| Measure | Value | File |
|---|---|---|
| Callback to reported presentation time (not photons), 120 Hz link, present every 2nd callback | 41.56 ms p50, 41.63 p99 | `probes/out/present_probe-60s-hud0-underload.txt` |
| Presented intervals within 16.67 ± 2 ms, 60 s runs, first 2 s excluded | saved: 99.944 % with 2 glitches (both within 0.03 s, so that 15 s window fails), 99.471 % with 19 glitches. Reported without saved output: 99.72 % / 10 and 99.94 % / 2 | `probes/out/present_probe-60s-hud0-underload.txt`, `…hud1…` |
| `present(atTime:)` with a display link | process aborts (`CAMetalDrawableInvalidOperation`) | observed, no saved file |
| Full screen, Low Power Mode off, 59.94 Hz mode | **not measured** | – |

Display modes available at 3456×2234: 120, 60, 59.94, 50, 48, 47.95 Hz. Current mode: 4112×2658 backing (scaled), 120 Hz. Saved: `probes/out/display_modes.txt`.

### Cadence in the OBS recording (160×90 grey, webcam masked; `probes/out/cadence/*.csv`)
| Window | Frames in 2-frame runs | Breaks |
|---|---|---|
| night drive, 2904 s | 99.05 % (first 49 s: 100 %) | pause menu |
| on foot, 2280 s | 87.6 % (first 50 s: 99.46 %) | OBS stutter |
| day drive, 6480 s | 96.99 % | 27 "3 then 1" slips in 60 s, origin unknown |
| day drive, 3792 s | 19.4 % (first 9 s: 100 %) | OBS stall |

Duplicate difference p50 0.014–0.026, new-frame difference p50 3.0–7.6 (0–255 scale). The recording is lossy and cannot carry the 99.9 % classification test; that needs a live uncompressed trace. Reference detector against the offline two-pass check: 99.89 %, 100.00 %, 93.10 % on three windows. Luma sampler cost (every 32nd row × 4th pixel): p50 38.8–40.8 µs, p99 111.4–127.2 µs on the three saved traces (`probes/out/cadence/luma_mad_*.csv`); a wider range of 36–58 / 100–217 µs was reported from runs that were not saved. The window names give start times in seconds; each window is 60 s. These percentages use the 160×90 grey metric; the sampler traces use a different grid and mask.

### Motion quality (`probes/out/motion_1..9/`, stills)
Nine hand-picked timestamps, warm pairs only: 3 clean, 5 minor artifacts, 1 obvious (near-camera foliage). All are real midpoints, none is a blend. Green fringe on the top edge in 7 of 9 (up to about 10 px) and 1–2 px at the bottom. The earlier sample in `probes/out/a_prev.jpg` etc. is a static pause menu and shows nothing.

### Not measured in phase 1
Anything on the Elgato. Capture latency. OBS coexistence. Idle timings. Full-screen display latency.

## Phase 1b (2026-11-19, afternoon)

### Pacer rule (PLAN.md 5.2), simulation: `python3 probes/pacer_sim.py`
10 simulated minutes, every starting phase, no jitter / ± 1 ms alternating / ± 1 ms random.
| Grid | Corrections | Positions dropped | Slot before its target | Shared slot |
|---|---|---|---|---|
| 120.000 Hz | ≤ 73 (arithmetic: 72) | 0 | never | never |
| 59.94 Hz at −50, 0, +50 ppm | ≤ 3 | ≤ 2 | never | never |

The Swift port in `probes/present_probe --pacer-selftest` gives identical slot sequences (same hash) on six cases.

### G1 probe, preliminary only (small window, scaled 120 Hz mode, on battery, Low Power Mode on, load average 7–8). **Not a gate result.**
`probes/present_probe --seconds 20 --link-hz 120 --source counter --display-mode keep --window small …`; rows saved in `probes/out/g1_small_window_underload.csv`.
| Measure | Value |
|---|---|
| Reported presentation − callback entry | p50 49.91 ms, p99 49.97 ms |
| Content intervals at 16.683 ± 2 ms (first 2 s excluded) | 1073 of 1076 = 99.72 % |
| Out-of-band intervals | 3 in 20 s (8.33, 25.00, 33.33 ms); worst rolling 15 s window: 3 |
| Shown frames presented on their target slot / one slot (8.33 ms) late | 505 / 689 |
| Pacer | 7 corrections (most at startup), 3 positions dropped |

Reading: in these conditions the display takes a new image only on every second 120 Hz slot. A frame reserved on the other slot appears 8.33 ms late, and each drift correction (one per 8.34 s) changes which case applies. Whether this holds in full screen with Low Power Mode off is exactly what gate G1 measures.

### Later on 2026-11-19 (16:00–16:25)

- **Interpolation on AC power with Low Power Mode off, still under load** (row added to the table above): p50 18.13 ms, p99 22.31 ms, 3,596 frames, 0 failures. That is slower than the battery / Low Power Mode run earlier the same day (p50 14.51, p99 18.28). So power state is not what limits it here: the other jobs are. At N = 4 the midpoint has 16.65 ms (D − H); at this speed the median midpoint misses it. **The idle number (gate G4) is still unmeasured**: the ffmpeg jobs have not finished.
- **Gate G1 not run.** The first full-screen attempt (16:05) is invalid: the screen was locked and the display asleep, so the display link stopped after 6 callbacks and the mode switch returned error 1014 (`probes/out/g1/invalid_screen_locked_smoke.csv`). The probe now refuses to run in that state. Full screen and both native modes remain unmeasured.
- **Pacer simulation extended** for PLAN.md version 4 (`python3 probes/pacer_sim.py`, passes): framegen slots = real-only slots + N in every case; 5 % of real frames 5–40 ms late; 2 % of positions missing; ± 2.5 ms random jitter; all-real stream; epoch reset with owned slots. No early slot and no shared slot in any case.

## Gate G1, first full-screen runs (2026-11-19, 16:17–16:27). **Not passed.**

Conditions: built-in display, full screen, `CAMetalDisplayLink` backend, mains power, Low Power Mode off, **10 ffmpeg jobs from another project still running** (load average 1.3–4.9), so the gate's "other jobs finished" condition is not met. Probe: `probes/present_probe --source counter --window full`. Raw files: `probes/out/g1/`.

### Short runs, 15 s each
| Display mode | `preferredFrameLatency` | Callback → glass p50 / p99 | Content intervals in 16.683 ± 2 ms | Glitches in 15 s | File |
|---|---|---|---|---|---|
| 3456×2234, 120 Hz | 2 | 41.57 / 41.62 ms | 768 / 771 = 99.61 % | 3 | `smoke_full_120.csv` |
| 3456×2234, 120 Hz | 1 | 41.55 / 41.60 ms | 769 / 772 = 99.61 % | 3 | `smoke_native120_lat1.csv` |
| 3456×2234, 59.94 Hz | 2 | 49.90 ms p50 | 772 / 772 = 100 % | 0 | `smoke_native5994_lat2.csv` |
| 3456×2234, 59.94 Hz | 1 | 49.85 ms p50 | 776 / 776 = 100 % | 0 | `smoke_native5994_lat1.csv` |

- The app-scoped display-mode switch works: requested mode read back in every run, and the previous mode (4112×2658 scaled, 120 Hz) returned on exit.
- `preferredFrameLatency` 1 is accepted (read back 1.0) and changes nothing. `targetPresentationTimestamp − targetTimestamp` is 33.33 ms at 120 Hz and 33.37 ms at 59.94 Hz: the display link hands out drawables two 60 Hz frames ahead of the glass in both modes.
- In full screen, frames land on their target slot (presented − target: p50 −0.016 ms at 120 Hz). The "every second slot" effect seen in the small window (Phase 1b above) does not occur in full screen.
- 120 Hz: of the 3 out-of-band intervals in the traced run, one is the expected drift correction (25 ms) and two come from one frame presented 8.32 ms late. A drift correction every 8.34 s is 2 in some 15 s windows, so **fixed 120 Hz cannot meet "≤ 1 glitch per 15 s" by arithmetic**, whatever the load.
- The p99 latency printed by the probe for the 59.94 Hz short runs (66.6 ms) includes start-up frames; steady state is 49.9 ms. The report is being changed to exclude the first 2 s.

### 5-minute run, 59.94 Hz (`g1_native5994_300s.txt`, `.csv`)
| Measure | Result | Bar | |
|---|---|---|---|
| Callback → glass, first 2 s excluded | p50 49.85 ms, p99 66.60 ms, max 66.67 ms (n = 17,731) | p99 ≤ 20 ms | **fail** |
| Content intervals in 16.683 ± 2 ms | 17,707 / 17,731 = 99.865 % | ≥ 99.5 % | pass |
| Out-of-band intervals in the worst rolling 15 s | 13 | ≤ 1 | **fail** |
| Frames presented one slot (16.68 ms) after their target | 2,040 = 11.5 % | – | – |
| Callbacks missing | 5 gaps, the longest 1.42 s (at 173 s) | – | – |
| GPU time per frame | p50 4.55 ms, p99 14.04 ms, max 38.92 ms | – | – |

What the per-slot log shows:
- 10–30 s into the run: 214 frames took more than 12 ms of GPU time (normal 4.5 ms); the 13 doubled intervals at 19–23 s fall in that stretch. Cause not identified (other GPU work on the machine).
- 81.9–113.9 s: every frame was presented exactly one slot late for 32 s, then it went back. Intervals stayed even, latency was 66.6 ms.
- 135.8 s, 169–173 s: doubled intervals and a 1.42 s gap with no callbacks.
- **This run was disturbed and cannot be read as the display path's clean behaviour.** The user was at the Mac during it, and the lead ran shell commands during it: a status check at about 87 s, `system_profiler SPDisplaysDataType` at about 136 s (a display query, next to the 135.8 s glitches), and a file search at about 170 s. A repeat with nothing else touched is needed before the pacing numbers mean anything. The latency result (49.9 ms at best) does not depend on that.

### Reading
- The display-link backend misses the 20 ms latency bar by 22–30 ms in both modes, with no setting found that changes it. A different present method (vsync-clocked plain layer, late drawable) is being added to the probe to measure whether it is shorter (`prompts/09-sonnet-vsync-backend-probe.md`).
- 59.94 Hz is the only fixed mode that can meet the glitch bar. 120 Hz is out for pacing.
- All of this is the built-in display. The user confirmed on 2026-11-19 (after first mentioning an external display at home) that **play is on the built-in screen**, so these are the right measurements. An external display is out of scope unless asked for; it would need its own G1.

## Gate G1, second present method (2026-11-19, 16:46–16:58). **Not passed; best path found so far.**

`--mode vsync`: no `CAMetalDisplayLink`. A `CADisplayLink` from `NSScreen` gives the vsync clock; each tick waits `--render-delay-ms`, takes a drawable with `nextDrawable()`, renders, presents with plain `present()`. Same conditions as above (built-in display, full screen, mains, Low Power Mode off, 10 ffmpeg jobs running). 15 s per run, one run each unless noted. Latency = pick time → reported presentation, first 2 s excluded. Raw: `probes/out/g1/matrix_1646.txt`, `matrix_1651.txt`, `matrix_1655.txt`, `m_*.csv`.

### First set (`matrix_1646.txt`)
| Display | Method | Render delay | Latency p50 / p99 | Glass after slot time | In band | Glitches / 15 s |
|---|---|---|---|---|---|---|
| 59.94 Hz | vsync, plain | 0 ms | 48.18 / 48.91 ms | 33.35 ms | 100 % | 0 |
| 59.94 Hz | vsync, plain | 4 ms | 28.31 / 44.12 ms | 16.66 ms (p99 33.36) | 99.74 % | 2 |
| 59.94 Hz | vsync, plain | **8 ms** | **24.18 / 25.21 ms** | 16.66 ms | **100 %** | **0** |
| 59.94 Hz | vsync, plain | 12 ms | 34.57 / 36.49 ms | 33.35 ms | 100 % | 0 |
| 59.94 Hz | vsync, `present(atTime:)` | 0 ms | 33.28 / 33.33 ms | 16.66 ms | 100 % | 0 |
| 59.94 Hz | display link, colour space none | – | 49.87 / 49.97 ms | 0 | 100 % | 0 |
| 59.94 Hz | display link, colour space P3 | – | 49.88 / 49.97 ms | 0 | 100 % | 0 |
| 120 Hz | vsync, plain | 0 ms | 24.93 / 24.96 ms | 16.65 ms | 99.87 % | 1 |
| 120 Hz | vsync, plain | 3 ms | 21.18 / 30.05 ms | 16.66 ms (p99 25.00) | 57.4 % | 330 |
| 120 Hz | vsync, plain | 6 ms | 25.77 / 27.20 ms | 24.98 ms | 99.87 % | 1 |

### Second set (`matrix_1651.txt`): the same method landed one refresh later
Every 59.94 Hz run in this set reached the glass 33.35 ms after its slot time, not 16.66: render delay 8 ms with colour space none (39.4 ms p50) and P3 (39.0), delay 10 ms (36.7), delay 6 ms (41.6), delay 8 ms with HUD off (39.5), delay 12 ms without MetalFX (35.1). In all of them `nextDrawable()` blocked for 3–10 ms (0.08 ms in the good run of the first set). With 3 drawables instead of 2 it was 50.03 ms after the slot (latency 55.7 ms).

Reading: frames wait in a queue between `present()` and the glass, one per drawable beyond the first. If one frame is queued at start-up, or one frame finishes late, every later frame is one refresh later and it stays that way, because frames are produced and shown at the same rate. More drawables means a longer queue. Colour space and HUD make no visible difference; neither removes the remaining 16.7 ms.

### Third set (`matrix_1655.txt`): `--drain-ms 2` (give back one drawable when `nextDrawable()` blocks more than 2 ms, at most once a second)
| Display | Render delay | Latency p50 / p99 | In band | Glitches / 15 s | Drains | GPU time p99 / max |
|---|---|---|---|---|---|---|
| 59.94 Hz | 0 ms | 33.28 / 48.86 ms | 96.97 % | 23 | 6 | 10.13 / 22.11 ms |
| 59.94 Hz | 4 ms | 28.76 / 44.26 ms | 99.58 % | 3 | 6 | 8.70 / 28.71 ms |
| 59.94 Hz | 6 ms | 26.53 / 43.79 ms | 99.35 % | 5 | 7 | 8.41 / 25.17 ms |
| 59.94 Hz | 8 ms (run a) | 24.50 / 41.69 ms | 99.31 % | 5 | 7 | 7.68 / 24.41 ms |
| 59.94 Hz | 8 ms (run b) | 24.68 / 40.30 ms | 99.48 % | 4 | 5 | 9.41 / 31.49 ms |
| 59.94 Hz | 10 ms | 36.87 / 54.44 ms | 98.83 % | 9 | 11 | 8.66 / 18.56 ms |
| 59.94 Hz | 12 ms, no MetalFX | 20.28 / 35.98 ms | 99.48 % | 4 | 6 | 4.74 / 10.31 ms |
| 120 Hz | 0 ms | 24.93 / 33.27 ms | 96.90 % | 24 | 3 | 9.38 / 20.39 ms |

Reading:
- The drain brings the median back to 24.5 ms at 8 ms delay in both repeats, so the stuck-queue state is curable. It costs one dropped frame per drain.
- During this set GPU time per frame had spikes (p99 8–10 ms, max 18–31 ms) that the first set did not have (p99 under 5 ms). Each spike makes a frame late, which queues it, which needs a drain: 5–7 drains in 15 s, so 4–5 glitches and a p99 of 40 ms. **The method is only as steady as the GPU is free.** Other GPU work was running (10 ffmpeg jobs); in real use OBS will be that other GPU work.

### Where G1 stands
| | Display link | Vsync clock, plain present, 8 ms delay, 59.94 Hz |
|---|---|---|
| Latency p50 | 49.9 ms | 24.2–24.7 ms (3 runs) |
| Latency p99 | 50.0 ms (66.6 in the disturbed 5 min run) | 25.2 ms in the one run without GPU spikes; 40–42 ms in two runs with spikes |
| Bar: p99 ≤ 20 ms | fail | fail |
| Pacing | 100 % in 15 s runs | 100 % without spikes; 4–5 glitches per 15 s with spikes |

- Lowest possible with this method (E): one refresh (16.68 ms) plus GPU time (4.5 ms p50) plus a safety margin: about 23–25 ms. The 20 ms bar is not reachable at 59.94 Hz unless the remaining compositor refresh is removed, and no setting tried removes it.
- 120 Hz gives the same 24.9 ms (two 8.33 ms refreshes instead of one 16.68 ms) and worse pacing. No reason to use it.
- No 5-minute run of the new method yet, and no clean one of any method: the ffmpeg jobs are still running.
- Consequence for the total (E): frame generation 33.4 ms + display 24–25 ms = about 58 ms before the capture card's own delay is counted. **The 60 ms total target cannot be met unless the card delivers frames in about 2 ms, which is not plausible.** The card's delay is still unmeasured.

## Final state (2026-11-19)

The project was stopped by its owner after the G1 results above. Nothing after this point was measured. Not done: capture-card tests (G2, G3, G5), an idle interpolation run (G4), a clean 5-minute display run, any app code, and the reviewing model's check of plan version 5.

