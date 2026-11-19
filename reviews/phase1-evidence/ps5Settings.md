# Console + capture-card settings: findings (2026-11-19)

All web facts were read today. "Read" = on the page; "Infer" = my reasoning. Nothing was tested on hardware (Elgato unplugged, OBS not running).

## 3. GTA 6 on PS5 Pro: 30 fps only (answer first, it decides the project)
- **Read:** Rockstar told Kotaku that neither a 60 fps nor a 40 fps mode is coming to any launch console, PS5 Pro included; the CPU is the limit (Engadget, 2026-11-18, quoting Marc Chambers). https://www.engadget.com/2321134/rockstar-just-settled-a-major-question-about-gta-6s-controversial-fps-decision/
- **Read:** Digital Foundry via GTA BOOM (2026-11-19): PS5 Pro renders 1440p, PSSR to near-4K, "near-locked 30 FPS", brief drops to ~24 fps only in stress tests. Engadget paraphrases DF as "perfect frame pacing". https://www.gtaboom.com/digital-foundry-finds-that-gta-6-indeed-runs-best-on-ps5-pro-b72f
- **Read:** DF (Leadbetter) says 40 fps would need "a huge amount of optimization or cutbacks" (GTA BOOM, 2026-11-17). https://www.gtaboom.com/digital-foundry-closes-the-door-on-a-40fps-gta-6-on-ps5-pro-9bac
- Confidence: **high**. Frame generation is not made redundant by a game mode.

## 1. PS5 Pro settings
Sony page (undated, © 2026): https://www.playstation.com/en-us/support/hardware/ps5-4k-resolution-guide/ . All under **Settings > Screen and Video > Video Output** unless noted.

| Setting | Read | Matters for 1080p SDR capture? |
|---|---|---|
| HDCP | **Settings > System > HDMI**, HDCP Off; must be done with the PS5 plugged directly into the TV (Elgato 4K S guide, 2026-10-26). Option is "Enable HDCP"; Netflix-type media apps stop working (PowerPyx, 2020). | **Mandatory**, black image otherwise |
| HDR | Sony lists "Always On" and "On When Supported"; "Off" appears only in an AVerMedia FAQ | **Yes**: 4K S HDR capture is Windows-only |
| VRR | VRR, plus "Apply to Unsupported Games" | **Yes, Off** (PS5 VRR only works above 48 fps, per DF via GTA BOOM) |
| 120 Hz Output | toggle | **Yes, Off** |
| Resolution | Sony lists Automatic, 1440p, 2160p; 1080p not on the page | Optional, the card downscales |
| Video Transfer Rate | Auto, -1, -2 | No; use -1 only if 4K passthrough flickers (infer) |
| ALLM | fully off also needs VRR Off | No (TV only); leave On |
| Deep Color Output, RGB Range | Sony gives no values | No; leave Automatic |

URLs: https://www.elgato.com/us/en/explorer/products/capture/how-to-set-up-game-capture-4k-s-with-playstation-5-and-playstation-5-pro/ , https://www.powerpyx.com/ps5-how-to-disable-hdcp/ , https://www.avermedia.com/support/faq/AY5VY7vg . Confidence: high for HDCP, medium for the rest.

## 2. Elgato 4K S
- **Read (2026-10-26):** HDMI 2.0 in/out, USB 3.0 Type-C. Passthrough up to 2160p60, 1440p144, 1080p240, with VRR and HDR10 (to 4K60). "No drivers needed… plug-and-play on Windows, macOS, and iPadOS." https://www.elgato.com/us/en/explorer/products/capture/elgato-game-capture-4k-s-technical-specifications/
- **Read:** capture maximums on USB 5 Gbps (https://www.elgato.com/us/en/explorer/products/capture/4k-s-supported-resolutions-and-frame-rates):

| Format | 1080p | 1440p | 2160p |
|---|---|---|---|
| YUY2 8-bit 4:2:2 | 60 | not listed | not listed |
| NV12 8-bit 4:2:0 | 120 | 60 | 30 |
| MJPG | 240 | 144 | 60 |
| P010 10-bit (HDR, Windows) | 60 | not listed | not listed |

  On USB 2.0 only MJPG 1080p60 survives. The card can capture below the console's output resolution while passthrough stays full.
- **Measured locally** (python3 read of `~/Library/Application Support/obs-studio/basic/scenes/Untitled.json`): the OBS source "Elgato 4K S" stores format `2560x1440 25/30/50/60 fps`, pixel format `420v` (NV12 video range), frame rate 60000240/1000000 = 60.00024 fps.
- **Infer:** the card advertises 60.00024 while the PS5 sends 59.94, so the app should use sample-buffer timestamps and not assume 60.000.
- **EDID, read:** Merged (recommended) "selects the best settings for both your capture device and display"; Display uses the TV's; Internal uses the card's; custom presets or .bin upload. https://www.elgato.com/us/en/explorer/products/capture/elgato-studio-software-overview/
- **Measured locally** (plutil on `/Applications/Elgato Studio.app/Contents/Resources/en.lproj/Localizable.strings`, v2.0.0): the macOS build has "Input EDID mode" (Merged/Display/Internal), "Custom EDID", "VRR Mode", "HDMI color range" (Auto/Expand/Shrink) and "HDR tone mapping" ("On: Play in HDR and capture in SDR format").
- **Infer:** in Merged the PS5 sees a blend of the TV and the card. The TV can get 4K60 HDR while the Mac captures 1080p SDR only if HDR tone mapping works on the 4K S and persists for third-party apps (the page says "if supported by that device"). PS5 in SDR is the safe route; 4K SDR passthrough with a 1080p capture should work.
- **Latency:** no ms figure on any Elgato page I read. A search summary cites a press-release claim of "as little as 30 milliseconds" in-app; I could not open it. Confidence: low.
- Confidence: high for specs, medium for EDID behaviour.

## 4. Is 30 fps always sent as 60 Hz 2:2?
- **Read:** no Sony document says so. Supporting evidence: 120 Hz output is only for games that support it; the user's recording is 59.94; DF reports near-perfect pacing on Pro.
- **Infer, cases that break "every second frame is new":**
  - drops below 30 (DF saw ~24 in stress tests) give 3-refresh holds;
  - games with bad pacing alternate 1 and 3 refreshes; Push Square (2016) reports this for Bloodborne and FFXV: https://www.pushsquare.com/news/2016/11/how_well_does_final_fantasy_xv_run_on_ps4_and_ps4_pro
  - menus or the map may render at 60;
  - the 60.00024 vs 59.94 clock mismatch can drop or repeat a frame and flip the phase.
- The detector should diff every frame and track phase. Confidence: medium.

## 5. TV interpolation in Game Mode
- **Read (RTINGS, 2025-03-26):** "only Samsung offers motion interpolation in Game Mode"; other TVs must leave Game Mode, so "most TVs will have a high input lag". Good value with interpolation: < 25 ms, measured at maximum settings. https://www.rtings.com/tv/tests/inputs/input-lag
- **Read (RTINGS S90D settings, via search summary):** Game Motion Plus is low-latency interpolation; the Judder Reduction slider covers 30 fps content. https://www.rtings.com/tv/reviews/samsung/s90d-s90dd-oled-qd-oled/settings
- **Secondhand numbers (low confidence):** an X post says RTINGS found lag roughly doubles to ~20 ms; a Blur Busters post quotes 11.7 ms rising to 25.3 ms with interpolation and 78.6 ms outside Game Mode, model not identified. That suggests roughly +10 to +14 ms on Samsung (estimate).
- **Read (ResetEra, 2026-08-28):** users split between "zero artifacts" and "utterly unusable" at 30 fps. A 2021 Samsung thread reports it failing on 30-fps-in-60-Hz input on QN90A. https://www.resetera.com/threads/tv-motion-interpolation-for-games-is-amazing.1618141/
- LG and Sony: no Game Mode interpolation per RTINGS; no ms figure found.

## Checklist before a capture session
1. PS5 directly on TV: Settings > System > HDMI, HDCP Off.
2. Video Output: HDR Off; VRR Off; 120 Hz Output Off; ALLM On; Deep Color, RGB Range and Video Transfer Rate Automatic.
3. Resolution: start at 2160p with the card downscaling; if capture is soft or laggy, set 1080p (the TV then gets 1080p too).
4. Cable PS5 > 4K S IN, OUT > TV, USB-C into a 5 Gbps or faster port (not a USB 2 hub).
5. Elgato Studio: Input EDID mode Merged (Display if no signal), VRR Mode Off, HDMI color range Auto, then quit Studio.
6. App format: 1080p60 NV12 (`420v`), or YUY2 for 4:2:2.
7. No analog headset in the controller (Elgato says it reroutes audio away from HDMI).

## Not verified
- PS5 "1080p" Resolution value, HDR "Off" label, and the Deep Color / RGB Range values on current firmware.
- Whether the Elgato Studio EDID, VRR and tone-mapping controls appear for the 4K S on macOS (strings exist; device absent).
- Formats and frame rates macOS offers at 1080p (only 1440p NV12 is in the OBS config); YUY2 on macOS unconfirmed.
- Any capture latency figure. Test: film the TV and the Mac preview together at 240 fps with an on-screen flash and count frames.
- RTINGS per-model interpolation lag (review tables would not load); the user's TV brand is unknown.
- The original Kotaku and Digital Foundry articles (blocked to my tools; relayed by Engadget and GTA BOOM).
- GTA 6's actual cadence on HDMI; not measured on the test footage here.