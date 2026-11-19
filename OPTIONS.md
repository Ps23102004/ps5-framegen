# PS5 30 fps to 60 fps on the MacBook: options (2026-11-19)

Research only, nothing built. Sources: probe run on this Mac (M3 Pro, macOS 27.2.1), GPT-6 Astra survey, Fable 5.2 review. Numbers marked *est.* are the models' estimates, not measurements.

## Measured on this Mac
| Apple feature | Supported | Limit |
|---|---|---|
| VideoToolbox low-latency frame interpolation | yes | input max 1920 px wide, max 1080p (2,073,600 px) |
| same, with its built-in 2x upscale | yes | input max 640 px (≈360p in, 720p out): too small to use |
| VideoToolbox frame-rate conversion | yes | aimed at offline video, likely too slow live *(est.)* |
| VideoToolbox super resolution (low-latency + normal) | yes | limits not queried yet |
| MetalFX frame interpolator | exists | needs the game's depth + motion vectors: not usable on captured video |

So "4K60 frame gen" on the Mac = interpolate at 1080p, then upscale to the screen.

## Options, best first
1. **Check the game first.** If GTA 6 on PS5 Pro has a Performance / 60 fps mode, use it: real 60, no added lag. Unknown to both models; check the in-game graphics menu.
2. **TV motion smoothing** (PS5 → Elgato passthrough → TV). Zero build effort. Many TVs turn it off in Game Mode; where it works, about 10–40 ms extra lag *(est.)*, more on slower modes. Try it first.
3. **Custom Mac player app** (the Lossless Scaling equivalent). Pipeline:
   1. Elgato capture at 1080p (set the PS5 to 1080p output, HDR off).
   2. Drop the repeated frames (30 real frames in a 60 Hz signal).
   3. Apple's frame interpolator makes 60.
   4. Upscale with MetalFX to the Mac screen.
   5. Show full screen, paced to the capture timestamps.
   - Added lag: about 25–35 ms for the frame generation itself, on top of the capture card's own 40–70 ms. That's roughly 70–100 ms behind the TV *(est.)*.
   - Smoother, but steering will feel heavier, and the HUD, text and particles will smear.
   - Effort: medium to high.
4. **Plan B if Apple's interpolator is too slow or looks bad:** own optical flow (custom Metal code, or a RIFE-style AI model) to warp the full-resolution frame. Better quality, much more work.
5. **Not worth it:** Lossless Scaling in a Windows VM or CrossOver (no working GPU path); SVP / mpv / IINA (built for movies, 100 ms+ buffering *(est.)*); MetalFX with fake depth.

## Risks
- **OBS and the player both need the Elgato.** Unverified whether two apps can open the card at once. Safest: one app captures and sends a copy to OBS.
- **Cadence breaks:** menus, dropped frames and 40/60 fps modes. Needs a pass-through mode.
- **Clock drift:** PS5 59.94 Hz vs Mac 120 Hz *(est.)*. Pace by capture timestamps, not a free-running timer.
- **HDR:** turn it off or handle it carefully.
- **Battery and heat:** sustained load on the M3 Pro.

## Experiments before building (pass/fail)
1. **Interpolator speed:** recorded 1080p GTA frame pairs through Apple's interpolator for 20 min. Pass: p99 ≤ 8 ms per frame with no drift. Fail: > 12 ms.
2. **Capture lag baseline:** Mac preview vs TV, filmed with a 240 fps phone camera. Pass: ≤ 50 ms behind the TV. Fail: > 80 ms.
3. **Full pipeline pacing:** ≥ 99.5% of frames at 16.7 ms ± 2 ms, and ≤ 35 ms added over experiment 2.

Overall bar: ≤ 60 ms added vs passthrough is good. Over 80–100 ms is likely too laggy for driving.
