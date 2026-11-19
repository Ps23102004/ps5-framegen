You are the second planner on a macOS real-time video project. Another engineer is writing their own plan separately; you have not seen it and must not guess at it. Your plan will be compared against theirs, so commit to specific choices.

First read `skills/plan-review/SKILL.md` in the working directory and follow it exactly, including the plan output format. Then read `OPTIONS.md`, `probes/interp_speed.m` and `probes/out/run-10min-during-render.txt`. You have read-only access to the macOS SDK headers listed in the skill file: open them before stating what an API does.

## Goal
A macOS app that shows PS5 gameplay full screen at a steady 60 fps with generated in-between frames and the lowest possible added latency. The game (GTA 6 on PS5 Pro) renders 30 fps inside a 60 Hz HDMI signal, so each game frame arrives twice.

Chain: PS5 Pro → Elgato 4K S (USB capture with HDMI passthrough to a TV) → MacBook Pro M3 Pro, 18-core GPU, built-in 3456×2234 120 Hz ProMotion display, macOS 27.2.1.

## Measured so far on this Mac
- `VTLowLatencyFrameInterpolation` (VTFrameProcessor) is supported. Without upscaling: max dimension 1920, max 2,073,600 pixels, so 1080p input at most. With its built-in 2× upscale: max 640 px wide input, which is too small to use. Pixel format: `420v` only.
- Speed (`probes/interp_speed.m`, 1080p, one midpoint frame, phase 0.5, 17,982 frames, run while six ffmpeg encodes were loading the CPU): p50 12.8 ms, p95 13.5 ms, p99 14.3 ms, max 131 ms (one spike), no drift, 0 failures. An idle-machine run has not been done yet.
- `VTFrameRateConversion`, `VTLowLatencySuperResolutionScaler`, `VTSuperResolutionScaler`, `VTOpticalFlow` and `VTMotionBlur` are reported as supported. Their limits have not been queried yet.
- `MTLFXFrameInterpolator` needs depth and motion-vector textures from the game, so it cannot be used on captured video.
- The only test footage is an OBS recording (2560×1440, HEVC, 59.94 fps) that has a webcam overlay in the bottom-right corner. It is lossy, so repeated frames are not bit-identical, and the webcam region changes on every frame.
- The Elgato is not plugged in right now, so its capture formats have not been listed.

## Starting design (challenge it where the evidence says so)
1. Capture: Elgato via AVFoundation at 1080p, uncompressed NV12 (`420v`), not MJPEG. PS5 set to 1080p output, HDR off.
2. Cadence detector: timestamps plus a subsampled luma difference find the unique frames. Pass-through mode for drops, 60 fps menus and other non-2:2 cadence. Start interpolating as soon as the next unique frame arrives.
3. Interpolation: `VTLowLatencyFrameInterpolation` at 1080p, phase 0.5.
4. Upscale 1080p to 3456×1944 with the MetalFX spatial scaler or the VT low-latency super-resolution scaler. Real and generated frames go through the same scaler.
5. Present with `CAMetalDisplayLink`, paced from capture timestamps, quantized to 120 Hz slots (each output frame shown for two refreshes), with a small drift controller for 59.94 Hz input against the 120 Hz display.
6. Game audio delayed to match the video.
7. On-screen HUD: input fps, output fps, frame-time graph, added-latency estimate, dropped and late counters.
8. OBS streams from the same Elgato at the same time. It is unknown whether two apps can open the card at once.
9. Plan B if quality or latency fails: own optical flow plus a Metal warp, or a Core ML RIFE-class model.

## Acceptance numbers
- Interpolation: p99 ≤ 12 ms at 1080p on an idle machine.
- Capture to screen without frame generation: ≤ 50 ms behind the TV.
- Frame generation and pacing: 10 minutes with ≥ 99.5% of output intervals at 16.7 ms ± 2 ms, ≤ 1 pacing glitch per 15 s, ≤ 35 ms added over capture-only.
- Overall: ≤ 60 ms added vs HDMI passthrough. Over 80–100 ms is too laggy for driving.
- Audio in sync within ±20 ms.

## What I want from you
Write your own plan in the skill file's plan format. Three questions I care most about, answer them with arithmetic:
1. What is the minimum added latency of midpoint interpolation here, stage by stage, given a new game frame every 33.37 ms, about 13 ms of interpolation compute, and a 120 Hz display? Is ≤ 35 ms added over capture-only reachable, and what exactly has to be true for it to hold?
2. How should output frames be scheduled on the 120 Hz display so that real and generated frames alternate at even 16.7 ms spacing when the input clock (59.94 Hz) and the display clock are not locked?
3. How do you detect the 2:2 cadence on a clean uncompressed capture with at most one frame of decision delay, and what do you do in the first frames after the cadence changes?

## Constraints
- Read-only task. Do not create or edit files. Do not run builds.
- No installs, no paid APIs, no OBS changes.
- Label every number measured or estimate. Name the header and symbol for every API claim.

## Output
The full plan as markdown, all eight sections, then a final list titled "Not verified" of every claim you did not check against a header or a measurement.
