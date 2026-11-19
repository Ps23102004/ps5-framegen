# PLAN: GTA6 60 FPS (Mac)

Version 3, 2026-11-19. Lead: Claude Fable 5.2. Second planner and reviewer: GPT 6.2 Astra. Astra reviewed version 1 (`reviews/02-astra-review-plan.md`: 4 blockers, 4 majors, 1 minor) and re-checked version 2 (`reviews/03-astra-recheck-plan.md`: all partly resolved, 10 edits asked for). Section 13 lists every change.

Labels: **M** = measured, raw output saved (file named). **M-report** = reported by a probe run whose raw output was not saved. **E** = estimate or arithmetic. **Target** = a number you set.

Machine state: the afternoon runs were under load (six ffmpeg jobs from another project), with Low Power Mode on and on battery (checked 13:32 and 14:00), so they are probably pessimistic. The morning run (`run-10min-during-render.txt`) was under load; its power source and Low Power Mode state are unknown. Nothing was measured on the Elgato: it is not plugged in.

## 1. Where this stands

1. **The game has no 60 fps mode.** Rockstar confirmed 30 fps only on every console, PS5 Pro included (Engadget, 2026-11-18, relaying Kotaku; the original was not readable by our tools).
2. **Apple's interpolator looks good enough to continue.** 9 hand-picked stills from the lossy OBS recording: 3 clean, 5 minor artifacts, 1 obvious (near-camera foliage). Each is a real motion-compensated midpoint, not a blend (`probes/out/motion_1..9/`). A green fringe appears on the top edge in 7 of 9 (up to about 10 px). Quality in motion is not judged yet.
3. **The 60 ms total target needs a capture-only path of about 26.7 ms (E). Nothing measured so far suggests that is reachable; nothing rules it out.** The frame-generation part costs 33.3 ms by construction (section 3). The two numbers that decide the project are unmeasured: the card's capture latency and the display path's latency in full screen.
4. **The starting design changes** in capture, upscale, presentation and pacing (section 2).

## 2. Verdict on the starting design

| # | Starting design | Verdict | Reason |
|---|---|---|---|
| 1 | Capture 1080p `420v`, PS5 at 1080p, HDR off | **Change: ask for 1080p `420v`, accept what arrives, normalise to ≤ 1920×1080 `420v`** | Your OBS scene captures 2560×1440 with the card's tone mapping off (M: OBS scene file and log). On upstream OBS source, OBS holds the device's configuration lock for the whole session (not checked on your installed 33.0.1). Whether a second app can attach is untested and reports conflict. The native 1080p path is still graded separately when available. |
| 2 | Cadence: timestamps + subsampled luma difference | **Keep, add a phase flywheel and a separate pair-safety rule** | On a static picture new and repeated frames look the same. Whether a pair is safe to interpolate is a stricter question than whether the detector is locked. |
| 3 | VT low-latency interpolation, 1080p, phase 0.5 | **Keep** | M: 1080p p50 12.80–15.32 ms, p99 14.32–21.10 ms across the saved non-contended runs (`run-10min-during-render.txt`, `interp_speed_res.txt`, `vt_interp_swift.txt`; different pacing and APIs). With a second GPU process: p50 17.88, p99 41.82. Time moves in steps: 1280×720 ≈ 5 ms, 1600×896 ≈ 10.3 ms, 1080p ≈ 14.5 ms. |
| 4 | Upscale with MetalFX or VT low-latency super resolution | **Change: bilinear in the conversion pass first; MetalFX compared in phase 4; VT super resolution out** | M: VT low-latency super resolution refuses 1080p input (max 1280 px per side, `vt_limits.txt`). MetalFX 1080p → 3456×1944: 3.44 ms GPU p50 / 4.50 p99 with the GPU otherwise quiet (M-report: copied from the console after a later run overwrote the file); M: 3.46–3.70 p50, 8.0–9.0 p99 with the GPU shared. M-report: convert + final pass 0.63 ms p50. Astra chose the same order independently. |
| 5 | `CAMetalDisplayLink`, 120 Hz slots, drift controller | **Change: slot reservation by ceiling rule; test 120 Hz and 59.94 Hz modes; plain `present()` only** | E: 59.94 Hz input on a fixed 120 Hz grid needs one 25 ms hold every 8.34 s, which fails the "≤ 1 glitch per 15 s" target if counted. M: the panel lists a fixed 59.94 Hz mode (`probes/out/display_modes.txt`). M-report: `present(atTime:)` aborts the process when a display link drives the layer. M: callback to reported presentation 41.56 ms p50 in a small window (`present_probe-60s-hud0-underload.txt`); full screen unmeasured. |
| 6 | Audio, HUD | **Keep** | Audio must not touch BlackHole or the Elgato audio device's sample rate, so `ps5audio` keeps working. |
| 7 | OBS coexistence: test first | **Keep; it is the first hardware test** | Your own `ps5rec` tool assumes the card is exclusive. Two forum reports disagree. |
| 8 | Plan B (own optical flow or RIFE) | **Defer** | Plan B waits for the next frame too, so it cannot fix latency. |

Also: the display is in a scaled mode (M: 4112×2658 backing on the 3456×2234 panel), so output would be resampled. The app must run in the native mode.

## 3. Latency: three separate budgets

`H` = 16.683 ms (one frame at 60000/1001 Hz). `S` = one display slot: 8.333 ms at 120 Hz, 16.683 ms at 59.94 Hz.

### 3.1 What frame generation adds: fixed by the schedule

Real-only mode gives a real frame the earliest slot it can make. Framegen mode gives the same frame that slot plus `N` slots. So **D = N × S exactly, for every on-time real frame**. The display link's lead time and slot rounding apply to both modes and cancel.

| Display | N | D |
|---|---|---|
| 120 Hz | 4 | 33.33 ms |
| 120 Hz | 5 | 41.67 ms |
| 59.94 Hz | 2 | 33.37 ms |
| 59.94 Hz | 3 | 50.05 ms |

**D = 33.3 ms meets the ≤ 35 ms target by construction. The open question is how often the midpoint is ready in time.**

### 3.2 Midpoint readiness: the real risk

The midpoint's slot is one frame (H) before B's. In the worst clock phase the time available from B's arrival to the midpoint's pick deadline is `D − H`. Costs besides interpolation (cadence verdict, normalise copy, dispatch, texture setup) are taken as 1.1 ms (E; sampler alone is M 0.04–0.13 ms; the rest is unmeasured).

**The table is nominal.** It assumes B's first copy arrives exactly 2H after A's. Any later arrival of B (capture jitter, unmeasured) comes off every cell one for one, and so does a normalise copy slower than assumed. The pacer's tolerance band is late-only (section 5.2), so it never shortens this window. The deadline check in the app uses the real arrival time and the real reserved slot, not this table.

| Display, N | Window `D − H` | Margin at 14.51 (M p50, paced) | at 18.28 (M p99, paced) | at 41.82 (M p99, second GPU user) |
|---|---|---|---|---|
| 120 Hz, 4 | 16.65 | **+1.04** | **−2.73** | −26.27 |
| 59.94 Hz, 2 | 16.68 | +1.07 | −2.70 | −26.24 |
| 120 Hz, 5 | 24.98 | +9.37 | +5.60 | −17.94 |
| 59.94 Hz, 3 | 33.37 | +17.76 | +13.99 | −9.55 |

Reading: at N = 4 the median midpoint just makes it in the worst phase and the slow tail does not. The phase drifts through all values on a 120 Hz display, so only part of the time is worst-case. A missed midpoint shows as a held real frame (one 33 ms interval) and is counted. The miss rate must be measured; it cannot be computed from these percentiles.

Ways to gain margin: a machine that is plugged in, idle and out of Low Power Mode (unmeasured); 1600×896 interpolation (M p50 10.28, p99 12.32 over 8 s: about +4 ms); 1280×720 (M p50 4.84, p99 8.04: about +10 ms, generated frames clearly softer). 720p does **not** make N = 3 safe at 120 Hz (margin −0.8 ms at its p99).

### 3.3 Total against the TV: unknown

| Stage | Low | High | Label |
|---|---|---|---|
| Card + USB + delivery to the app | 30 | 66 | E. No Elgato figure exists; the low value is from a search summary. |
| Ready → next usable slot | 0 | < 8.3 (120 Hz), < 16.7 (59.94 Hz) | E |
| Display callback → reported presentation | ≈ 8 (hypothesis for full screen) | 41.6 | high value is M p50, small composited window |
| **Capture-only, Mac side** | **≈ 38** | **≈ 116–124** | E, illustrative sums |
| Framegen at N = 4 / 2 | +33.3 | +33.4 | section 3.1 |
| **With generation** | **≈ 71** | **≈ 149–158** | E |

The TV's own processing is subtracted in the real measurement, and the Mac panel's scan-out and pixel response are not in this table. So the true number comes only from filming both screens (G5).

**Your two targets together:** total ≤ 60 ms requires capture-only ≤ 26.7 ms. A capture-only result at the phase 2 bar of 50 ms would give about 83 ms total.

## 4. Gates

### Probe-only (no app code)
| ID | Question | Needs | Method | Outcome recorded |
|---|---|---|---|---|
| G1 | Display path in full screen: callback-to-presentation time and pacing in 120 Hz and 59.94 Hz modes | plugged in, Low Power Mode off, other jobs finished, the screen for about 5 min | `probes/present_probe`, **display-link backend** (the one section 5.2 is written for), after these changes: content is a counter at positions H apart (60000/1001 Hz), reserved by the section 5.2 rule with `base` = 0 and N = 0; log the display mode actually applied, every slot's content id, skipped callbacks and zero presentation times. A plain `nextDrawable` loop is run too, timer started before `nextDrawable()`, as a diagnostic only: it cannot pass the gate, because it has no slot grid to reserve on. | per display mode: reported-presentation minus callback-entry time, p50 and p99; % of content intervals at 16.68 ± 2 ms; glitches in every rolling 15 s. **Pass = in at least one display mode, with the display link: p99 latency ≤ 20 ms, ≥ 99.5 % of intervals in band, and ≤ 1 glitch in every rolling 15 s window, over 5 minutes.** |
| G2 | What does the card offer and deliver? | Elgato on USB, 1 min | `probes/list_capture` (list), then `--open` after its fixes | negotiated USB speed, advertised formats and rates, active format, delivered subtype and IOSurface backing. "Uncompressed" is marked verified only with transport evidence. |
| G3 | Can OBS and a second app capture together? | Elgato, PS5, OBS already recording to disk in its existing configuration; no helper restart, no scene edit | `probes/list_capture --open` after fixes: `canAddInput`/`canAddOutput` checks; distinct results for permission denied, lock denied (-11817), device in use (-11815), preset renegotiation, zero frames | both clients' frame counts, audio meter and OBS drop counters before / during / after. If sharing fails: "simultaneous mode blocked in the current setup" and the fallback list in `reviews/phase1-evidence/coexistence.md` applies. |
| G4 | Idle interpolation speed | plugged in, Low Power Mode off, no other jobs | `probes/interp_speed_res "<recording>" 1500 600 1920 1080 33.37 1` | p50/p95/p99/max against the target p99 ≤ 12 ms. Pass or fail is recorded; the target stays until you change it. |

### App-dependent
| G5 | Capture-only latency against the TV | phase 2 build, PS5, TV, phone at 240 fps | section 12 | distribution (median, worst), camera uncertainty ± 4.2 ms, TV picture mode, go / no-go from you |

## 5. Architecture

One process, Swift, one SwiftPM package, no third-party code.

```
Elgato ─► Capture ─► Sample luma ─► Normalise ─► Conductor ─────────► Presenter ─► CAMetalLayer
           (AVCapture)  (as delivered)  (≤1080p 420v)   │   ▲   (reserved items)      │
                                                        ▼   │                         └─ slot observations ─► Conductor
                                                   Interpolator (VT, one in flight)
Elgato audio ─► Audio ring ─► delay ─► chosen output device
```

**The Conductor is the single owner of scheduling.** It runs on one serial queue (the capture queue). It owns the `CadenceDetector`, the `Pacer`, the epoch counter, slot reservations and cancellation. Only the Conductor creates a `FrameID`: a source delivers a sequence number and the Conductor stamps the current epoch on it. Capture frames, interpolator completions and source events are all delivered to it on that queue. The presenter never decides timing: it publishes each slot's time through a lock-free single-writer snapshot and consumes reserved items.

| Stage | Thread | Owns | When late or failing |
|---|---|---|---|
| Capture | capture queue | the device buffer, until the callback returns | drop callback → `SourceEvent.framesDropped`, one ledger row per dropped frame (`dropped:preCopy:<reason>`), and the next frame carries `droppedBefore` |
| Sample | capture queue | – | plane-0 luma of 8-bit bi-planar input only. Any other subtype → `unsupportedInput` + 1, generation off, real-only through the normaliser |
| Normalise | capture queue | pool of 6 IOSurface `420v` buffers at the working size | **Device buffers never leave this stage: every frame is copied into the app pool, with no exception for input that is already 1080p `420v`** (`VTPixelTransferSession`; cost measured in task 2.2). The type system enforces it: downstream code accepts only `PoolBuffer`, which only the pool can create. Pool empty → frame dropped, `poolExhausted` + 1, ledger row `dropped:preCopy:poolExhausted` |
| Conductor | capture queue | detector, pacer, epoch, reservations | never blocks |
| Interpolator | VideoToolbox's queue; completion hops to the capture queue | one `VTFrameProcessor`, destination pool of 4 | one call in flight. Busy → that midpoint is not requested, `interpBusy` + 1. Completion with a stale epoch or after its pick deadline → discarded, `interpStale` / `interpLate` + 1. 30 failures in a row → generation off |
| Presenter | display-link thread | drawable, textures (released in the command buffer's completion handler), HUD | each slot: show the item reserved for it; none → hold the last image, `held` + 1 |
| Audio | audio I/O thread | ring buffer | underrun → silence, `audioUnderrun` + 1, re-anchor |

**Epochs.** The Conductor increments the epoch on: cadence contradiction, capture format or size change, device disconnect or runtime error, timestamp jump (> 0.5 s or backwards), display mode or slot-grid change, sleep/wake, a change of N, mode switch. Every reservation and every interpolation request carries its epoch. On an epoch change: pending generated items are cancelled, no new pair is accepted until section 5.1's pair-safety rule holds again, the pacer re-anchors on the next slot observation, and real frames keep flowing.

**Commit boundary.** An item is committed when the presenter has encoded it into a command buffer for a slot. Cancellation works only before that. The trace records whether a cancelled item was already committed (`cancelTooLate` + 1).

**Words.** *Real-only*: generation off, each unique frame shown once (content changes every 2H on a 30 fps game). *Framegen*: real and generated alternate (content changes every H). *HDMI passthrough*: only the cable from the card to the TV. Cadence states: `locked22`, `native60`, `unknown`.

### 5.1 Cadence: verdict, state and pair safety are three things

**Verdict and state: `probes/cadence_ref.py` is the specification.** The Swift detector matches it row for row on the golden files (verdict, state, flags). In short: mean absolute luma difference on a sparse grid (every 32nd row, every 4th pixel, scaled to the delivered size; M: p50 39–41 µs, p99 111–127 µs on three saved traces); adaptive bands from a running noise floor and motion level; phase prediction in `locked22` so a changed frame in the expected slot is `new` at once; lock is kept through one lost copy; `native60` when at least 10 of the last 12 verdicts are `new`; static picture keeps the phase. Thresholds are starting values, fitted on the first live trace and scored on a second, separately labelled one. The plan no longer states its own transition rules. Nothing is filtered before `ingest`: a frame whose timestamp is at most half a period after the previous one is passed in like any other, and the detector does what the reference does (counts `timestampAnomalies`, advances one slot, classifies normally).

**Pair safety is decided by the Conductor, not the detector.** A midpoint between unique frames A and B is requested only if all hold:
- state is `locked22` and has been for at least 4 unique frames in this epoch;
- A and B are consecutive unique frames; their first-copy timestamps are 2H ± 0.25H apart;
- no capture drop was reported between them and neither verdict came through late promotion;
- B is not flagged `sceneCut`;
- the interpolator is idle, and the midpoint's pick deadline has not passed.

Otherwise B is shown as a real frame at its reserved slot and nothing else happens. A contradiction (a `new` frame where a repeat was predicted, or a repeat where a change was predicted while the picture was moving) starts a new epoch.

**Known limits, stated plainly.**
- `A, A, B` is the same prefix for `A, A, B, B` and `A, A, B, C`. The break is seen one frame later. If the midpoint was already committed, it is shown.
- A change confined to chroma or to pixels between the sampled positions is not seen. A scalar luma metric cannot detect it, and the offline check uses the same metric, so it cannot catch it either. An independent audit (full-plane compare on a recorded live trace, offline) is part of task 2.4.
- A reported drop can make a verdict take longer than one frame of wall time.

### 5.2 Pacer: one position timeline for both modes

**Positions.** While the state is `locked22`, the output timeline has a position every H: one at each unique frame's first-copy capture time, and one halfway between consecutive unique frames. In `native60` and `unknown` there is a position at each `new` frame. **Both modes reserve every position, in time order.** In framegen mode a midpoint position holds the generated frame. In real-only mode the same position is reserved and left empty, so the presenter holds the previous real frame there. This makes a real frame's slot identical in both modes apart from the N-slot delay, so the measured difference is exactly N slots.

Earliest glass time of a position at content time `c`: `g = c + base + N × S`. `base` is the calibrated minimum from capture timestamp to pickable (0 in the G1 probe; measured in real-only mode at G5). `N = 0` in real-only mode.

- **Grid.** The Conductor keeps the slot grid as (origin, period), fitted to the last 120 observed `targetPresentationTimestamp` values (median period, latest origin). It never uses a constant.
- **First position of an epoch.** `slot = max(ceil((g − origin) / S), nextPickable)`.
- **Every later position.** Try `predicted = previous slot + step` (step = 2 at 120 Hz, 1 at 59.94 Hz). Keep it when its time lies in `[g, g + S + 2ε)`, ε = 1.5 ms. Otherwise recompute `ceil((g − origin) / S)`. **The band is late-only: no position is ever assigned a slot earlier than its `g`.** The price is up to 2ε = 3 ms of extra delay just before a correction. Sustained flapping would need timestamp jitter above 2ε peak to peak.
- **A reservation never moves.** If a recomputed slot is not later than the last reserved slot: a midpoint position is dropped (`collision` + 1, the previous real frame is held one more slot); a real frame takes `last reserved + 1` (`pushedLate` + 1) and the following midpoint position is skipped (`catchUpSkip` + 1), which removes one position and brings the timeline back.
- **Order of work.** When B's first copy arrives, the Conductor reserves the midpoint position and then B's position, and only then, if the pair is safe (section 5.1) and the mode is framegen, dispatches to VideoToolbox. A missing or late midpoint leaves B's slot unchanged.
- **Expected behaviour (E).** 120 Hz: H is 2.002 slots, so with step 2 the slot time falls behind `g` by 1/60 ms per position and one extra slot (a 25 ms interval) is inserted every 500 positions = 8.34 s, about 72 in 10 minutes. 59.94 Hz: only the true offset between the PS5's clock and the panel's; at 50 ppm one correction per 334 s. Counted separately: `driftSlip`, `startupAlign`, `epochReanchor`, `midpointMiss`, `collision`, `pushedLate`.
- **Parity.** At 120 Hz the presenter's even/odd alignment follows from the reservations; the presenter has no controller of its own.
- **Checked.** `probes/pacer_sim.py` simulates this rule for 10 minutes at every starting phase, with no jitter, ± 1 ms alternating jitter and ± 1 ms random jitter. Result (M, simulation): 120 Hz: at most 73 corrections, nothing dropped; 59.94 Hz at −50, 0 and +50 ppm: at most 3 corrections and 2 dropped midpoint positions; no slot before its `g` and no shared slot in any case. The first version of the rule failed this check on a display slower than the source (it pushed every frame); the collision rule above is the fix. The Swift `Pacer` must reproduce this script's slot sequences (task 3.2).

### 5.3 Display mode

On start the app enumerates modes, switches the built-in display to 3456×2234 at the chosen rate with `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(config, .forAppOnly)`, then reads back and logs the mode actually applied. If the switch fails, the app says so and runs in the current mode with a warning in the HUD. Restoration after a crash is tested once in task 2.3 before anyone relies on it. Window: borderless at the screen frame; the picture is 3456×1944 with 145-pixel bars.

### 5.4 Generated-frame edge fix (provisional)

Rows 0–11 and the last 2 rows of a generated frame are drawn from a 50/50 mix of its two real frames. Unverified in motion, and the fringe may not exist with a true 1080p source. Checked on the first live capture; removed if not needed.

## 6. Interfaces

Frozen for phase 2. The lead writes these into `Sources/FrameGenCore/Types.swift` and `Sources/FrameGen/Contracts.swift` in task 2.0, so every implementer compiles against the same file.

```swift
// ── FrameGenCore (no AppKit, AVFoundation, Metal or VideoToolbox) ──
public enum CadenceState: String, Sendable { case unknown, locked22, native60 }
public enum FrameVerdict: String, Sendable { case new, duplicate }
public struct CadenceFlags: OptionSet, Sendable { public let rawValue: UInt8
    public init(rawValue: UInt8)
    public static let sceneCut = CadenceFlags(rawValue: 1), staticPicture = CadenceFlags(rawValue: 2), phaseFlip = CadenceFlags(rawValue: 4),
        timeGap = CadenceFlags(rawValue: 8), latePromotion = CadenceFlags(rawValue: 16), first = CadenceFlags(rawValue: 32), timeReset = CadenceFlags(rawValue: 64) }
public struct CadenceConfig: Sendable { /* every threshold in cadence_ref.py: same names in camelCase, same defaults, all `public var` */ public init() }
public struct CadenceInput: Sendable {
    public var hostTime: Double        // seconds
    public var lumaDiff: Double?       // nil for the first frame after init or reset (the reference's `first`), or an unsupported buffer
    public var droppedBefore: Int
    public init(hostTime: Double, lumaDiff: Double?, droppedBefore: Int)
}
public struct CadenceOutput: Sendable { public var verdict: FrameVerdict; public var state: CadenceState; public var previousState: CadenceState
    public var flags: CadenceFlags
    public var promotedFirstCopyTime: Double?     // set with .latePromotion: the earlier frame's timestamp
    public init(verdict: FrameVerdict, state: CadenceState, previousState: CadenceState, flags: CadenceFlags, promotedFirstCopyTime: Double?) }
public struct CadenceDetector: Sendable { public init(config: CadenceConfig); public mutating func ingest(_ i: CadenceInput) -> CadenceOutput; public mutating func reset() }

public struct SlotGrid: Sendable { public var origin: Double; public var period: Double; public var nextPickable: Int64 }
public struct PacerConfig: Sendable { public var stepSlots: Int /* 2 or 1 */; public var base: Double; public var delaySlots: Int /* N */; public var epsilon: Double }
public enum SlotDecision: Sendable { case slot(Int64), pushedLate(Int64), collision, gridNotReady }
public struct Pacer: Sendable {                   // owned and mutated only by the Conductor
    public init(config: PacerConfig)
    public mutating func reset()                  // on every epoch change
    public mutating func reserve(positionTime: Double, isRealFrame: Bool, grid: SlotGrid) -> SlotDecision   // call for every position, in time order
}
// Every public struct above has a public memberwise init; they are omitted here for space except where shown.

// ── FrameGen ──
struct FrameID: Hashable { let epoch: UInt32; let sequence: UInt64 }   // created only by the Conductor
struct PoolBuffer { let pixelBuffer: CVPixelBuffer; fileprivate init(_ b: CVPixelBuffer) }   // only BufferPool (same file) can make one
final class BufferPool { init(width: Int, height: Int, count: Int) throws; func take() -> PoolBuffer? /* nil = exhausted */ }
struct SourceFrame { let sequence: UInt64; let buffer: PoolBuffer /* 420v, working size */
    let hostTime: Double; let arrivalTime: Double; let lumaDiff: Double?; let droppedBefore: Int
    let transferFunction: String? /* the delivered buffer's kCVImageBufferTransferFunctionKey, nil if absent */ }
final class CapturedFrame { let id: FrameID; let frame: SourceFrame }      // made by the Conductor
enum SourceEvent { case formatChanged(width: Int, height: Int, fourcc: UInt32), disconnected, runtimeError(Error), permissionDenied, noSignal
    case framesDropped(count: Int, reason: String, hostTime: Double) }   // every frame lost before the copy: device drop, pool exhausted, unsupported subtype, replay behind
protocol FrameSource: AnyObject {                 // LiveCapture, FileReplay (paced on the host clock from a start anchor; drops frames when behind, counted)
    func start(queue: DispatchQueue, pool: BufferPool, onFrame: @escaping (SourceFrame) -> Void, onEvent: @escaping (SourceEvent) -> Void) throws
    func stop()
}
struct PairRequest { let previous: CapturedFrame; let next: CapturedFrame; let midpointID: FrameID; let contentTime: Double; let pickDeadline: Double }
enum InterpError: Error { case busy, notReady, unsupportedSize, processing(Int), shutDown }
final class Interpolator {
    init(width: Int, height: Int) throws          // limit preflight + warm-up call
    /// Returns .busy at once without calling completion. Otherwise completion is called exactly once, on `queue`.
    func request(_ r: PairRequest, queue: DispatchQueue, completion: @escaping (PairRequest, Result<PoolBuffer, InterpError>, _ start: Double, _ end: Double) -> Void) -> InterpError?
    func shutdown()                               // waits for the call in flight; later requests return .shutDown
}
struct PresentItem { let id: FrameID; let generated: Bool; let buffer: PoolBuffer; let slot: Int64
    let edgeSources: (PoolBuffer, PoolBuffer)? }
enum SlotOutcome { case shown(FrameID), held(FrameID?) /* previous image again */, skipped /* no drawable, or the callback was not delivered */ }
struct SlotReport { let slot: Int64; let targetTime: Double; let pickTime: Double; let outcome: SlotOutcome
    let gpuStart: Double; let gpuEnd: Double; let presentedTime: Double /* 0 = not presented */ }
final class Presenter {
    init(layer: CAMetalLayer, stepSlots: Int) throws
    func start(); func stop()                     // main thread, once each
    func enqueue(_ item: PresentItem)             // Conductor queue only
    func cancel(epochBefore: UInt32) -> [FrameID] // drops uncommitted items of older epochs; returns the ones already committed (they will be shown)
    var slotGrid: SlotGrid? { get }               // lock-free snapshot, written on the display thread
    var onSlotReport: ((SlotReport) -> Void)?     // called on a utility queue, never on the display thread
}
```

**Two ledgers, written under `runs/<date-time>/`.**
- `items.csv`: one row per frame the device or file produced (including frames lost before the copy) and per midpoint position, whatever became of it: id, generated, capture PTS (host), arrival time, luma diff, verdict, state, flags, pair id, reserved slot, interpolation start/end, **one** terminal disposition (`shown`, `dropped:preCopy:<reason>`, `dropped:<reason>`, `emptyPosition` (real-only), `notRequested:<reason>`, `late`, `stale`, `cancelled`, `collision`, `unpresentedAtExit`), and a separate yes/no column `cancelTooLate` (a cancelled item that was already committed: its disposition is `shown`, so it is counted once).
- `slots.csv`: one row per slot of the grid from first to last callback: slot, target time, pick time, outcome (`shown` id, `held` id, `skipped`), GPU start/end, presented time (0 kept). A slot with no callback gets a `skipped` row written by the Conductor when the next slot is observed.

**Golden-file mapping for task 2.1.** The golden CSV columns are `frame,is_new,state,flags,offline_is_new`. `is_new` 1/0 = `.new`/`.duplicate`. `state`: `UNKNOWN`, `LOCKED_2_2`, `PASSTHROUGH_60` = `.unknown`, `.locked22`, `.native60`. `flags` (space-separated): `first`, `timeReset`, `gap` = `.timeGap`, `latePromotion`, `sceneCut`, `static` = `.staticPicture`, `phaseFlip`; an entry `X->Y` means `previousState` = X and `state` = Y on that row. `offline_is_new` is not produced by the detector.
- `counters.txt` and `run.json` (mode, display mode applied, N, working size, power state, load average).

`tools/stats.py` computes every acceptance number from these, including rolling 15 s glitch windows and generated yield (midpoints shown ÷ midpoint opportunities). A hand-audited fixture with known skipped slots and wrong ids is part of its tests.

## 7. Phases and tasks

One bounded call per task, each with a skill file and an engineered prompt written to `prompts/` before the call. Sol's code is reviewed by Sonnet, Sonnet's by Sol; Astra reviews each phase's diff with the numbers. The lead builds, runs and measures everything before it counts.

| Phase | Task | Owner | Skill | Pass line |
|---|---|---|---|---|
| 1b | G1, G4 (no hardware); G2, G3 (with the card) | Lead for probes, you for hardware | metal-present | each gate's outcome recorded as pass / fail / unavailable with machine state; the branch taken is written in RESULTS.md |
| 2 | 2.0 Package skeleton, shared types (section 6), `scripts/make-app.sh` with permission strings, `run.json` writer | Lead | – | `swift build` and `swift test` green on an empty implementation |
| 2 | 2.1 `CadenceDetector` | Sol | capture-cadence | equals `cadence_ref.py` on every row of every golden file; the 6 self-test cases plus time-reset, duplicate-delivery and late-promotion cases pass |
| 2 | 2.2 `LiveCapture`, `FileReplay`, `BufferPool`, luma sampler, normaliser | Sol | capture-cadence | replay of 3 windows paced on the host clock: delivered count and rate within 0.1 % of the file's; sampler + detector p99 < 0.3 ms inside the app; normalise cost p50/p99 reported; BT.709 colour-bar check within 1 code value; the delivered buffer's transfer-function attachment is logged and carried in `SourceFrame`; every `SourceEvent` case, including `framesDropped`, has a test |
| 2 | 2.3 App shell, display-mode switch, `Pacer` (N = 0), `Presenter`, both ledgers | Sonnet | metal-present | **(a)** native 60 counter source, 10 min: ≥ 99.5 % of *content* intervals at 16.68 ± 2 ms, ≤ 1 glitch in every rolling 15 s; **(b)** real-only on doubled input: content intervals at 33.37 ± 2 ms to the same percentages; ledger equations hold (`captured = shown + dropped + …`, `slots = shown + held + skipped`); display mode restored after a forced kill |
| 2 | 2.4 `tools/stats.py`, offline two-pass check, full-plane audit of the luma metric, HDMI-origin event detector for the phone test | Sonnet | capture-cadence | reproduces the saved probe numbers; fails the hand-made bad fixture |
| 2 | **G5** capture-only latency against the TV | you + lead | – | section 12; go / no-go from you |
| 3 | 3.1 `Interpolator` | Sol | vt-interpolation | 10 min paced, 0 failures; moving-square test: square found at the midpoint position **and** no square at either end position above 25 % contrast; busy, late, pool-exhausted, shutdown-race and rebuild tests pass |
| 3 | 3.2 `Pacer` with N > 0, Conductor pair logic, epochs | Sol | metal-present §pacing | simulated clocks: exact slot and content id sequences for 59.94 vs 120.000, 59.94 vs 59.94 ± 50 ppm, every starting phase in 0.1 S steps, ± 1 ms jitter at a boundary, missing B, busy interpolator, epoch reset, N change. No two items in one slot, no slot before its target minus ε |
| 3 | 3.3 Framegen wiring, cancellation, edge fix | Sonnet | all three | 10 min: ≥ 99.5 % content intervals at 16.68 ± 2 ms; ≤ 1 glitch in every rolling 15 s; matched real frames exactly N slots later than real-only; generated yield ≥ 99.5 %; every midpoint opportunity has a disposition |
| 4 | 4.1 MetalFX against bilinear on identical moving scenes | Sonnet | metal-present | GPU p50/p99, deadline misses, and a sharpness-alternation measure (high-frequency energy of real vs generated frames) for both; the choice is yours from side-by-side clips |
| 4 | 4.2 HUD | Sonnet | metal-present | both HUD states pass 3.3's pacing lines in one run; HUD numbers equal the ledgers' |
| 4 | 4.3 Audio: Elgato audio → ring → delay (video delay − output device latency) → chosen output | Sol | capture-cadence §audio | flash-and-click test within ± 20 ms in real-only, framegen and across a switch; refuses BlackHole as the output; OBS "PS5 Audio" meter still moving with `ps5audio` running |
| 5 | OBS at the same time, 30 min while actually streaming | Lead | – | achieved content rate equals the measured input rate; OBS dropped/missed counters compared over equal-length windows before and during; deadline-miss and temperature trends flat |
| 6 | You drive; tune N, working size, thresholds | you + lead | – | your verdict saved; every changed setting re-runs the phase 3 lines |

Phase 2 exists to produce G5 as early as possible.

## 8. Risks, ranked

| # | Risk | Evidence | Cheapest test |
|---|---|---|---|
| 1 | Capture + display latency exceed the budget before generation is added | E 30–66 ms and M 41.6 ms (small window) | G1 now; G5 at the end of phase 2 |
| 2 | Midpoints miss their slot at N = 4 | margin +1.0 ms at median, −2.7 ms at p99 | G4, then phase 3 yield; fallback 1600×896 |
| 3 | The card cannot be shared with OBS | conflicting reports | G3 |
| 4 | Input cadence is not clean 2:2 | M: 27 three-frame + 27 one-frame runs in one minute of the recording, origin unknown; M-report: OBS config says 60.00024 fps | first live trace through `probes/cadence_trace.py stats` |
| 5 | Pacing on a 120 Hz grid fails the glitch target | E: 25 ms hold per 8.34 s | G1 in 59.94 Hz mode |
| 6 | PQ-coded input when sharing OBS's setup | inferred from the `ps5` helper's comments | first live frame; tone-map step in the shader if needed |
| 7 | Artifacts in motion; changing HUD digits morph | stills only | phase 6 |
| 8 | Heat over 30 min with OBS encoding | unmeasured | phase 5 |

## 9. Decisions needed from you

1. **Go / no-go rule.** Total ≤ 60 ms requires capture-only ≤ 26.7 ms. Recommendation: keep "framegen adds ≤ 35 ms" as the hard bar, measure capture-only at G5, and decide then what total you accept.
2. **Interpolation speed target.** p99 ≤ 12 ms has not been met in any saved run (best p50 12.80), all under load. Recommendation: run G4 properly first. If it still fails, add "generated yield ≥ 99.5 % at N = 4" as the bar that matters, and keep the glitch target beside it.
3. **Display mode.** May the app switch the built-in display to native 3456×2234 while it runs, restored on quit? 120 Hz or 59.94 Hz is chosen from G1.
4. **HDR and your stream setup.** (a) PS5 in SDR with a 1080p capture for frame-generation sessions, or (b) keep your current HDR / 1440p / LUT setup and have the app scale down and tone-map. Recommendation: decide after G3.
5. **Your TV.** If it is a Samsung, try Game Motion Plus first. It is the only brand RTINGS lists with interpolation inside Game Mode. The added lag for your model is unverified, and reports for 30 fps input are mixed.

## 10. Cut from the first version

MetalFX (until phase 4), HDR output on the XDR panel, any relay to OBS (until G3 says one is needed), a user-facing low-resolution interpolation mode (the `Interpolator` takes a size parameter; nothing more), zero-copy capture, multi-display, Plan B.

## 11. Not verified

Everything on the Elgato (formats, transport, latency, sharing, timestamps, buffer type, duplicate noise floor, PQ content). Full-screen display latency and whether reported presentation time equals photons. Idle and plugged-in timings. Low Power Mode's effect. Display restoration after a crash. The green fringe on a true 1080p source. Quality in motion. PS5 menu labels on current firmware. Audio. That installed OBS 33.0.1 behaves like upstream source.

## 12. First live session: run sheet

**Before.** PS5 directly on the TV once: Settings → System → HDMI → HDCP off. Then Settings → Screen and Video → Video Output: VRR off, 120 Hz Output off, HDR as decided in 9.4 (labels unverified on current firmware). Cable PS5 → card IN, card OUT → TV, USB-C to a port on the Mac itself. Elgato Studio: Input EDID "Merged", then quit it. No headset in the controller. Mac plugged in, Low Power Mode off.

**If something is wrong, the app shows which:** camera or microphone permission denied; card not found (matched by the id suffix `fd900af`, since the full id changes with the USB port); no signal or black frames (HDCP, cable order); frozen content; unsupported pixel format; USB negotiated below 5 Gbps.

**HDR check on the first live frame (needed when your stream setup is active, decision 9.4).** The app logs the buffer's transfer-function attachment. The `ps5` helper's comments say the card then sends PQ-coded 8-bit video labelled Rec.709, so the label cannot be trusted: compare the PS5 home screen's black and white on the Mac against the TV. Washed-out greys and dim highlights on the Mac = PQ content. Then either the tone-map step is added to the shader and checked against the TV (a small phase 4 task), or PQ input is marked unsupported and frame-generation sessions run with the PS5 in SDR. Until that check is done, PQ input is unsupported.

**Recovery rules.** Unplug, timestamp jump, sleep/wake, display change or format change → new epoch, generation off, real-only resumes on fresh timestamps, a new `VTFrameProcessor` is built if the old one failed. Every step is a counter.

**G5 procedure.** The event must come from the HDMI signal, so the TV and the Mac show the same thing: use the game's pause menu opening (an abrupt full-screen change). Phone on a tripod, 240 fps, both screens in frame, the same height on each screen compared (top third). 20 events. Per event: frames between the change appearing on the TV and on the Mac × 4.17 ms. Report median, worst, and the TV's picture mode (Game Mode on).

## 13. Changes from version 1 after Astra's review

| Astra finding | Change |
|---|---|
| Pacer could assign before the target and oscillate; slip claims held only in ideal steady state | Section 5.2 replaced: ceiling rule on a measured grid, reservations in content order, ε anti-chatter, separate counters. Astra's rule adopted. |
| Budget mixed readiness, schedule and total | Section 3 split into three; margin table by display mode added; "five slots is safe" and "720p allows 25 ms" removed |
| Plan and reference detector disagreed; goldens cannot check pairs | Section 5.1: the reference is the spec for verdict and state; pair safety is a separate Conductor rule with its own tests |
| Interfaces could not enforce ownership, deadlines, accounting | Section 6 rewritten: epochs, timed pair requests, single owner (Conductor), source events, two ledgers; device buffers never leave the capture stage in version 1 |
| "Done when" lines could pass wrong work (task 2.3 most clearly) | Section 7 pass lines rewritten on content intervals, ledgers, rolling windows, yield |
| Gates answered different questions | Section 4 rewritten; G5 moved out of "before app code" |
| No live-session recovery procedure | Section 12 added; epoch rules in section 5 |
| Evidence scope and provenance | Labels M / M-report / E throughout; RESULTS.md corrected |
| "Cannot both hold" was wrong | Reworded in 3.3 and 9.1 |

**Version 3, after Astra's re-check of version 2:**

| Re-check finding | Change |
|---|---|
| Real-only and framegen reserved slots differently, so the difference came out as N − 1 slots | 5.2: one position timeline; both modes reserve every position, real-only leaves midpoint positions empty |
| The ε-early pick removed the median margin | 5.2: the band is late-only, `[g, g + S + 2ε)`; 3.2 table labelled nominal |
| Two items could land in one slot | 5.2: a reservation never moves; midpoint dropped, real frame pushed one slot and the next midpoint skipped |
| The source stamped the epoch; device buffers could pass through | 5 and 6: the Conductor creates `FrameID`; `PoolBuffer` can only come from the pool; identity path deleted from the plan and the capture skill |
| Duplicate-delivery rule differed between skill and reference | 5.1 and capture skill: nothing is filtered before `ingest`; fixture required |
| Metal skill still graded drawable intervals and `frames.csv` | metal-present section 8 rewritten on content intervals from `slots.csv` |
| G1 could pass on a backend the pacer cannot use; no pass statistic | 4: display link is the gated backend, `base` = 0, p99 ≤ 20 ms |
| PQ input deferred with no test | 7 task 2.2 and 12: transfer function logged, black/white check, unsupported until verified |
| Provenance of three numbers | header, section 2 and RESULTS.md corrected; display modes saved to `probes/out/display_modes.txt` |
| Ledgers could not show frames lost before the copy or slots without a callback | 6: `framesDropped` event, `dropped:preCopy` rows, `skipped` slot outcome; `cancelTooLate` is a separate column |
| Task 2.1 lacked initialisers and a golden-flag mapping | 6: public initialisers, `previousState`, mapping table |

Not adopted: Astra's exact-equality duplicate test as the primary rule (kept as the zero-noise-floor case of the adaptive bands, plus the offline full-plane audit), because no live buffer has been seen yet.
