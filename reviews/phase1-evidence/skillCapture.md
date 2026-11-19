## Result
- Skill file: `~/Developer/ps5-framegen/skills/capture-cadence/SKILL.md` (356 lines, all 9 sections in order, plus "2b. Required cadence behaviour").
- New probes: `~/Developer/ps5-framegen/probes/cadence_ref.py` (executable reference detector, offline two-pass check, golden-file dump, selftest of the 6 required cases) and `~/Developer/ps5-framegen/probes/luma_mad.swift` (the in-app sampler on recorded footage: trace CSV + cost). Traces and one golden file are in `~/Developer/ps5-framegen/probes/out/cadence/` (`luma_mad_*.csv`, `golden_night_drive_2904_60s.csv`).
- The skill also points at two sibling probes I did not write: `probes/list_capture.swift` and `probes/cadence_trace.py`.

## Type-check (code blocks extracted from the SKILL.md itself)
`S=<scratchpad>`
```
xcrun swiftc -typecheck -swift-version 5 -warnings-as-errors -sdk $SDK -target arm64-apple-macos27.0 $S/Capture.swift $S/LumaDiff.swift $S/FileReplay.swift   -> no output, exit 0
xcrun clang -fsyntax-only -fobjc-arc -Wall -Werror -isysroot $SDK -target arm64-apple-macos27.0 $S/ObjCSpellings.m                                          -> no output, exit 0
```
Target macos27.0 worked; no need to drop. `LumaDiff` + `replay` were also built and run on the recording (output identical to the `luma_mad` trace). `Capture.swift` is compile-only: never run.

## Surprises and contradictions with the starting design
1. **OBS uses the card at 2560x1440, not 1080p.** OBS scene config (read-only): source "PS5", `macos-avcapture-fast`, "Elgato 4K S", uniqueID `0x22000000fd900af`, format 2560x1440 `420v`, fps `60000240/1000000`. One device has one active format, so FrameGen at 1080p and OBS at 1440p cannot both get their format. PLAN.md must decide. Not tested which side wins.
2. **`AVCaptureSession.Preset.inputPriority` is unavailable on macOS** (measured: compile error). The session may replace `activeFormat` at start. The example holds the device lock across `startRunning()` and checks afterwards. Not tested.
3. **The card advertises 60.00024 fps, not 59.94.** A hand-built `CMTime(1001,60000)` would raise an Obj-C exception Swift cannot catch. Use the range's own `minFrameDuration`; measure the real period from timestamps.
4. **uniqueID changes with the USB port** (three values in OBS backups). Match suffix `fd900af`.
5. **The suggested 8x8 luma grid misses the 0.3 ms budget.** Measured on decoded 1080p frames, load average 3–17: 8x8 p99 350–478 µs (7 runs); every 16th row x 4th pixel p99 223–330 µs (5 runs); every 32nd row x 4th pixel p50 36–58 µs, p99 100–217 µs (17 runs). Cost follows rows touched, not samples. The skill specifies 32x4 (15,840 samples).
6. **The recording cannot carry the 99.9 % number.** Measured (32x4 grid, masked): duplicate diffs p50 0.05, never 0; a codec keyframe every 118 frames lifts a duplicate's diff to 1.9–3.3, above new-frame diffs in a dark scene (p5 1.5); the window at 3792 s has only 73 % of new frames two slots apart. Reference detector vs offline two-pass: 99.89 % (2280 s, 30 s), 100.00 % (2904 s, 60 s), 93.10 % (3792 s, 30 s). **I changed the DoD wording**: 99.9 % applies to a live uncompressed trace; on the recording the pass line is "Swift detector matches the reference golden file on every row". Revert if you disagree.
7. **macOS 27 SDK deprecates `AVAssetReader.add`, `startReading`, `copyNextSampleBuffer`** (4 warnings, measured). Zero-warning replay needs the Swift-only `outputProvider(for:)` / `start()` / `provider.next()`; verified working.
8. Swift gotchas: buffer attachment keys need `import CoreMediaIO.CMIOSampleBuffer`; `availableVideoCVPixelFormatTypes` is `availableVideoPixelFormatTypes` in Swift.
9. Dropped-frame reason attachment is promised "On iOS" only in the header; the example counts `droppedNoReason`.
10. Timestamps: header says all output PTS are on `session.synchronizationClock`; correct conversion is `CMSyncConvertTime(pts, from: syncClock, to: CMClockGetHostTimeClock())`. Host clock equals `CACurrentMediaTime()` (measured: max 17.8 µs apart over 1000 reads). `masterClock` deprecated; `AVCaptureInput.Port.clock` is the wrong clock.
11. CoreMediaIO direct route exists (`CMIODeviceStartStream`, `CMIOStreamCopyBufferQueue`); judged not worth it (estimate < 1 ms saved, not measured).

## Decisions I made beyond the brief
- Full detector rule set (bands LOW/MID/HIGH, noise-floor and motion EMAs, phase prediction, "late promotion" as the only 1-frame-delayed path, static freeze, state transitions). Selftest timings (measured): lock at 9th diff (150 ms); 60 fps → `PASSTHROUGH_60` at 8th frame; back to `LOCKED_2_2` at 15th frame (250 ms); 3:2-like → `UNKNOWN` at 28th frame.
- All thresholds are unfitted starting values, stated as such.

## Not verified
- Anything live: `Capture.swift` never ran; Elgato not plugged in, OBS not running.
- Whether the Elgato lists 1920x1080 `420v` at ~60 fps.
- Whether `videoSettings = [:]` delivers IOSurface-backed `420v` buffers without conversion.
- Whether the session replaces `activeFormat` at start, and whether holding the lock prevents it.
- OBS + FrameGen on the device together; whether OBS holds the configuration lock (-11817 path).
- Whether macOS attaches drop reasons, and CMIO sequence/host-time attachments, to AVFoundation buffers.
- Whether `synchronizationClock` is the host clock; callback-minus-PTS latency.
- Audio: `linkedDevices` finding the Elgato audio device; reading it while `ps5audio` runs (I did not open that helper's source).
- Sampler cost on live capture buffers; all cost numbers are from decoder output under varying load.
- Noise floor of uncompressed duplicate frames (possibly exactly 0); every threshold.
- Cause of the irregular cadence at 3792 s (HDMI signal or OBS).
- `probes/list_capture` commands in the skill are quoted from its header comment; I did not run its `--open` mode.