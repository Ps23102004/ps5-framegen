# ps5-framegen

Research and test tools for one question: can a MacBook Pro show a 30 fps console game at 60 fps, live, by capturing it with a capture card and generating the in-between frames with Apple's own frame interpolator?

**Status: stopped on 2026-11-19, before any app code was written.** The measurements showed that the added delay would land near 58 ms plus the capture card's own delay, against a target of 60 ms in total, and the owner chose to stop there. Everything learned up to that point is here so someone else can continue.

What is in this repository is a plan, measurements, and single-file probes. There is no app.

## Setup that was measured

- PS5 Pro, game locked to 30 fps, sent as 60 Hz HDMI with every frame doubled
- Elgato 4K S capture card (never opened by these tools: no live capture was run)
- MacBook Pro, M3 Pro, built-in 3456×2234 display (120 Hz ProMotion), macOS 27.2.1
- All timing runs were made with other heavy jobs running on the same machine (ffmpeg encodes), so they are pessimistic. No idle-machine number exists.

## What was found

| Question | Answer | Where |
|---|---|---|
| Can Apple's `VTLowLatencyFrameInterpolation` make the midpoint frames? | Yes, up to 1920×1080, `420v` only, one call in flight. 9 hand-picked stills: 3 clean, 5 minor artifacts, 1 obvious. Quality in motion was not judged. | `RESULTS.md`, `skills/vt-interpolation/SKILL.md` |
| How fast is it at 1080p? | p50 12.8–18.1 ms, p99 14.3–22.3 ms across runs, all under load. The original bar (p99 ≤ 12 ms) was never met. 1600×900 is about 10–12 ms, 720p about 5 ms. | `RESULTS.md` |
| Can VideoToolbox super resolution do the upscale? | No: it refuses 1080p input (1280 px per side at most). MetalFX spatial scaling 1080p → 3456×1944 costs about 3.4–4.7 ms of GPU time. | `probes/out/vt_limits.txt` |
| Display path with `CAMetalDisplayLink`, full screen | 41.6 ms (120 Hz) and 49.9 ms (59.94 Hz) from callback to reported presentation. `preferredFrameLatency` 1 changes nothing. | `RESULTS.md`, gate G1 |
| Display path with a vsync clock, `nextDrawable()` and plain `present()` | About 24.2–24.7 ms at 59.94 Hz when rendering starts 8 ms after the vsync tick. p99 25.2 ms in a run without GPU spikes, 40–42 ms in runs with them. | `RESULTS.md`, gate G1, second method |
| Why that path flips between 24 and 40 ms | One frame gets queued ahead (at start-up, or after one late frame) and stays queued, because frames are produced and shown at the same rate. More drawables means a longer queue. Giving one drawable back when `nextDrawable()` blocks drains it. | `RESULTS.md`, `probes/present_probe.swift` (`--drain-ms`) |
| 120 Hz or 59.94 Hz display mode? | 59.94 Hz. A fixed 120 Hz mode must hold one frame for 25 ms every 8.34 s, and its latency is no better. | `PLAN.md` 5.2, `RESULTS.md` |
| What does frame generation itself add? | The real frames must be held back so the midpoint can be shown first: 33.4 ms (2 slots at 59.94 Hz). | `PLAN.md` 3 |
| Total added delay | About 33 ms + 24 ms = 58 ms before the capture card's delay. The card was never measured. | `RESULTS.md` |

## What was not done

- No live capture. The capture card, its latency, its pixel formats and whether it can be shared with OBS are all untested.
- No clean 5-minute run of either display method. The only 5-minute run was disturbed (see `RESULTS.md`).
- No idle-machine interpolation timing.
- No app: no capture stage, cadence detector, pacer, presenter or audio path in Swift. `PLAN.md` section 6 has the interfaces that were going to be written first.
- The plan's last version (5) was **not** confirmed by the reviewing model; see below.
- The `--drain-ms` option in the display probe was added last and reviewed by nobody.

## How to continue

1. Read `PLAN.md` (version 5). Section 4 lists the gates, section 5 the design, section 6 the frozen interfaces, section 7 the tasks with pass lines, section 12 the first live-session run sheet.
2. Read `RESULTS.md` top to bottom: every number has its conditions and the file holding the raw output.
3. Rebuild the probes you need. Each source file's first comment has its build command and usage. Example:
   ```sh
   xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 probes/present_probe.swift -o probes/present_probe
   python3 probes/pacer_sim.py            # checks the slot rule in PLAN.md 5.2
   probes/present_probe --pacer-selftest  # Swift port, same sequences
   ```
4. The probes that read a video expect your own recording of 30 fps gameplay inside a 60 fps file. No footage is included.
5. Open decisions are in `PLAN.md` section 9. The first thing worth measuring is the capture card's own delay, because it decides whether the whole idea is acceptable.

## Layout

| Path | Contents |
|---|---|
| `PLAN.md` | The plan, version 5, with a change table per version |
| `RESULTS.md` | All measurements |
| `MODELS_LOG.md` | Which model did which task, and what was accepted or rejected |
| `OPTIONS.md`, `SESSION_PROMPT.md` | The original brief |
| `probes/` | Single-file test programs (Swift, Objective-C, Python) |
| `probes/out/` | Raw probe output: text reports and per-slot CSV logs. Images and videos are left out |
| `skills/` | Briefing files for the implementing models: exact APIs, conventions, definitions of done |
| `prompts/` | Every task prompt that was sent to a model |
| `reviews/` | What the models returned: independent plan, plan reviews, evidence reports, code reviews. Earlier plan versions are in `reviews/plan-versions/` |

## Caveats on the numbers

- "Presentation time" is `MTLDrawable.presentedTime` as reported by the system. It was never checked against a camera.
- Several files refer to stills (`motion_1` … `motion_9`, scaler comparisons) and to test videos. Those are not published because they are frames of a commercial game. The written verdicts on them remain.
- The read-only study of how the owner's existing OBS and audio setup uses the capture card (`reviews/phase1-evidence/coexistence.md`, `coexistenceRefutation.md`) is not published: it describes a private setup. Its conclusion is in `PLAN.md` (gate G3): whether OBS and a second app can capture from the card together was never tested. Other files still cite those two reports.
- Device ids, the recording's file name, time zone and a few private tool names were replaced with placeholders.
- Paths were shortened to `~`, `<scratchpad>` and `$TMPDIR` before publishing, and the raw model run logs (`reviews/*.log`) were left out. Line numbers quoted from those logs in `MODELS_LOG.md` refer to files that are not here.

## How this was made

Written in one working session by AI models under a human owner's direction. Claude Fable 5.2 led (plan, review, measurements, fixes). GPT 6.2 Astra wrote an independent plan and reviewed the plan four times; it answered "not OK to start" each time with a shorter list, and its check of version 5 never ran because of a usage limit. Claude Sonnet 5.5 extended the display probe twice. `MODELS_LOG.md` has the details, including what each model got wrong.

## License

MIT, see `LICENSE`.
