# Skill: plan and review for GTA6 60 FPS (Mac)

Use this when asked to write a plan, or to review a plan or a diff, for this project.

## Project in one paragraph
PS5 Pro (GTA 6, 30 fps game inside a 60 Hz HDMI signal, each game frame sent twice) → Elgato 4K S (USB capture) → MacBook Pro M3 Pro (18-core GPU, 3456×2234 120 Hz ProMotion display, macOS 27.2.1). A macOS app captures 1080p, finds the unique frames, generates the in-between frames, upscales to the display's 16:9 area (3456×1944) and presents a steady 60 fps with the lowest possible added latency. Target: ≤ 60 ms added vs HDMI passthrough to the TV.

## Where the facts are
- SDK root: `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk`
- VideoToolbox frame processors: `$SDK/System/Library/Frameworks/VideoToolbox.framework/Headers/VTFrameProcessor*.h`
- MetalFX: `$SDK/System/Library/Frameworks/MetalFX.framework/Headers/`
- Display link: `$SDK/System/Library/Frameworks/QuartzCore.framework/Headers/CAMetalDisplayLink.h`
- Capture: `$SDK/System/Library/Frameworks/AVFoundation.framework/Headers/AVCapture*.h`
- Project files: `OPTIONS.md`, `probes/interp_speed.m`, `probes/out/`, `RESULTS.md` (if present).

Read the headers before you state what an API does. Your training data may be older than this SDK.

## Rules
- Every API claim names the header file and the symbol. If you did not open the header, write "not verified".
- Every number is labelled **measured** (with the file it came from) or **estimate** (with the arithmetic behind it).
- No vague advice ("optimize the pipeline", "handle edge cases"). Name the mechanism, the data structure and the threshold.
- Latency claims come with a budget table: one row per stage, in ms, with min / typical / worst, and a total.
- Don't propose installs, paid APIs, or changes to OBS settings.
- Do the whole task. If you run out of room, say exactly which sections are missing. Do not write "the rest is similar".
- Don't edit files unless the task says so.

## Plan output format
1. Verdict on the starting design: keep / change, one line each, with the reason.
2. Latency budget table (stage, min, typical, worst, measured or estimate).
3. Architecture: threads and queues, who owns each buffer, what happens when a stage is late.
4. Cadence detection algorithm: exact metric, thresholds, state machine, and what it does in each non-2:2 case.
5. Pacing algorithm: how output times are computed from capture timestamps, and how 59.94 Hz input is mapped onto 120 Hz display slots.
6. Risks, ranked, each with the cheapest experiment that would settle it.
7. What you would cut from the first version.
8. Open questions that need a measurement, not an opinion.

## Review output format
For each finding: severity (blocker / major / minor), the exact section or `file:line`, what is wrong, the evidence (header, measurement or arithmetic), and the fix. End with a list of anything you did not check.

## Definition of done
All sections present, every claim labelled, no section says "TBD".
