# Cadence + motion-quality report (all timings measured under load: load avg ~12, six foreign ffmpeg jobs running)

## Headline
- The recording is 2:2 where OBS behaved, but it is **not a clean fixture**: it has OBS-side stalls, 3:1 slips and HEVC keyframe pops.
- Apple's interpolator produced a real motion-compensated midpoint in 9/9 samples (never a blend). No broken frames. One systematic defect: a **green fringe on the top/bottom border**.

## Part 1: cadence (160x90 gray, area scale, webcam masked)
Overlay measured at x 86.8-100 %, y 76.9-98.7 % (mask x>=136, y>=68). ~4.2 min decoded in total.

| window (60 s) | frames in 2-frame runs | run-length histogram | what breaks it |
|---|---|---|---|
| night_drive_2904 | 99.05 % | {2:1780, 4:1, 14:1, 16:1} | first 49.2 s perfect (1474/1474); breaks at 2953.6-2956 s are the pause menu/map (static picture) |
| onfoot_2280 | 87.6 % | {2:1574, 3:56, 1:15, 4-10:49} | first 49.9 s 99.46 % ({2:1486, 3:4, 1:4}); from ~2330 s OBS stutter during gameplay |
| day_drive_6480 | 96.99 % | {2:1743, 3:27, 1:27} | 27 "3 then 1" slips in 60 s, always paired, no net drop |
| day_drive_3792 | 19.4 % | long tail up to 98 | first 9.3 s perfect (279/279); from 3801.4 s decays to ~1 unique frame/s until window end |

- **Stall is OBS, not PS5**: at 3825-3833 s the webcam overlay freezes with the game (cam diff 0 except when the game frame changes).
- **Keyframe pop**: every 118 frames (1.9686 s) a duplicate landing on an I-frame reads 0.43-0.82. Lossy-source artifact only.
- **3:1 slips**: third repeat reads 0.07-0.19. Origin unknown (game frame pacing or OBS sampling jitter).
- No unpaired single-frame events in clean ranges, so source and 59.94 recording stayed phase-locked for at least 49 s.
- Whole-file proxy from packet sizes (ffprobe, no decode): 47 % of 10 s bins clean 2:2, 7 % mostly, 35 % mixed, 10 % every-frame-different (first 300 s etc.). The proxy is unreliable inside stalls.

Diff distributions (mean abs luma, 0-255):

| window | duplicate p5/p50/p95 | new p5/p50/p95 | new min |
|---|---|---|---|
| night_drive_2904 | 0.002/0.014/0.099 (max 0.17) | 0.78/3.01/8.32 | 0.08 |
| onfoot_2280 | 0.004/0.026/0.078 | 3.98/7.03/20.3 | 2.0 (clean part) |
| day_drive_6480 | 0.011/0.026/0.092 | 4.08/7.59/17.4 | 1.53 |

**Thresholds (this lossy footage)**
- Absolute 1.0 separates everything in daytime motion (dup max 0.82 incl. pops vs new min 1.5).
- Absolute 0.3 is wrong twice: 2 false breaks per keyframe, and it misses slow night frames (0.1-0.3).
- Night/slow motion has no absolute gap (dup max 0.17 vs new min 0.08). Rule used: new if diff > 1.0, or (diff > 0.04 and > 3x previous and next < diff/3). It needs one frame of lookahead, so offline only.
- Static picture: new and duplicate are indistinguishable; the live detector needs a phase flywheel.

Fixtures: `~/Developer/ps5-framegen/probes/out/cadence/{night_drive_2904,onfoot_2280,day_drive_6480,day_drive_3792}.csv` (frame, pts_s, diff). The `luma_mad_*.csv` files there are another agent's.

Tool: `~/Developer/ps5-framegen/probes/cadence_trace.py`
```
python3 cadence_trace.py trace <video> <start> <secs> <out.csv>
python3 cadence_trace.py stats <csv> [abs threshold] [-v]
python3 cadence_trace.py selftest
```

## Part 2: motion samples (1920x1080 420v, 3 warm-up pairs, fresh session each)
Folders: `~/Developer/ps5-framegen/probes/out/motion_<n>/` with a_prev, b_generated, c_next, ab_blend, info.txt.

| n | t (s) | scene | verdict |
|---|---|---|---|
| 1 | 6505.6 | truck, fast lateral pan | **clean**: pillars, "WRONG WAY" sign, power lines, wheel, minimap |
| 2 | 6499.2 | truck passing a tree | **obvious artifacts**: foreground foliage turns to mush, brown smudge over truck bed, ~10 px green blob top-left; stickers, plate, road sign, posts sharp |
| 3 | 6530.3 | toll booth at speed | **minor**: overhead sign at top edge loses a text line; dark blob beside guard rail; STOP sign, other truck, lane line, road surface fine |
| 4 | 3793.2 | car turning, fast pan | **minor**: HUD distance changing 451→448 ft becomes a garbled digit; palms, wires, fence, wheels clean |
| 5 | 2326.2 | on foot, dense vegetation | **minor**: slight frond warping |
| 6 | 2308.5 | on foot, subtitle + minimap | **minor**: moving foot fades to a ghost, subtitle slightly soft; minimap and wire mesh fine |
| 7 | 2928.7 | night, STOP sign | **clean**: thin pole, chain-link, tail lights, HUD |
| 8 | 2165.0 | boat | **clean**: hull text, water, wake |
| 9 | 962.0 | interior + subtitle | **minor**: subtitle letters wobble over moving background |

- **Green fringe**: visible on the top edge in 7/9 (up to ~10 px), plus a 1-2 px line on the bottom in most. Prefilling the destination did not remove it (`QT_PREFILL=1`), so the processor writes it. Plan an overscan/crop of ~12 px or patch from a source frame.
- Static HUD and minimap are untouched; text that changes between frames morphs.
- The game's own motion blur on the near road helps.
- Interpolate call: 14.3-19.5 ms (n=9); startSession 66-78 ms.

Probe: `~/Developer/ps5-framegen/probes/quality_trio.m`
```
clang -fobjc-arc -O2 quality_trio.m -o quality_trio -framework Foundation -framework AVFoundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreImage -framework QuartzCore -framework CoreGraphics -framework ImageIO
./quality_trio "<video>" out 6505.6 6499.2 6530.3 3793.2 2326.2 2308.5 2928.7 2165.0 962.0
```
Distinct-frame threshold is 1.5 (`QT_THR`); measured duplicates 0.06-0.12, new 9-32.

**Overall read**: good enough for driving at 30→60 on this evidence. Rigid scenery, signs, poles, wires, the car and HUD hold up; weak spots are near-camera foliage occlusion, independently moving limbs, text over moving background, and the border fringe.

## Not verified
- Anything on live uncompressed capture: Elgato not plugged in. Procedure: capture 60 s driving, run `trace`/`stats`, expect duplicate diff ~0 and no pops, then set the live threshold.
- Quality in motion (flicker across consecutive generated frames): stills only.
- Whether 3:1 slips come from the game or OBS.
- PS5 output rate (59.94 vs 60.00).
- Cause of the green fringe, and whether cropping fully hides it.
- Rain: no sample found.
- Source limits: lossy 1440p HEVC downscaled to 1080p, webcam overlay in 6 of 9 samples.
- Packet-size proxy inside the "mixed" 35 %.
