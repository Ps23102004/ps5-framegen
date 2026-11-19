You are the independent reviewer on a macOS project (PS5 30 fps gameplay captured by an Elgato card, shown at 60 fps on a MacBook Pro with generated frames). Your confirmation pass on version 3 of `PLAN.md` ended "OK to start task 2.0 and the gates: no", with three blockers and one minor point. The lead has made version 4. Confirm or refute that each of those four points is now closed. Do not re-open rows you marked Closed, and do not raise new points unless they block task 2.0 (package skeleton and shared types) or gates G1 to G4.

**Everything you need is pasted below, between the `=====` markers. Do not run any command and do not open any file: answer from this prompt alone.**

For each of your four open points (shared position timeline / startup clamp; shared-slot collision at epoch reset and grid refit; ledger coverage and `SlotDecision`; provenance): **Closed / Not closed**, the section you checked, and if not closed the smallest edit that closes it.

Then, with your own arithmetic:
1. Re-work your failing example (start on-grid, 120.000 Hz, startup `nextPickable = 1`, N = 4) under the version 4 rule. What slots do real-only and framegen reserve for the first real frame, and do they differ by exactly N?
2. Read the new `run()` in `probes/pacer_sim.py`. Does it implement section 5.2 as now written (baseline without N, floor on real frames only, `first_free`, never-moves)? Name any way the floor or `first_free` can produce a shared slot or a slot before `g` that the asserts would not catch.
3. One specific check: a midpoint position is reserved when frame B arrives, so its baseline slot is usually already in the past. Version 4 never floors a midpoint. Is that consistent in both modes, and does it leave the midpoint's pick deadline well defined?

Format: findings first, each with severity (blocker / major / minor), the section, and the smallest fix. Label every number "measured" (you can point at the line below it came from) or "estimate". Under 600 words.

End with one line: **"OK to start task 2.0 and the gates: yes / no"**. If no, list only the edits that would make it yes.


===== YOUR CONFIRMATION PASS ON VERSION 3 =====
**Blocker — §§3.1, 5.2 and 6.** The shared timeline fixes the original on-grid example. The startup clamp still breaks the unconditional exact-N claim. A second gap appears at epoch reset, when the pacer forgets its last reservation but the presenter can still own a committed slot.

**Blocker — §6.** The frozen interface cannot distinguish a midpoint skipped after a pushed real frame from a midpoint dropped by collision. The pre-copy drop event also lacks a sequence convention for creating the required per-frame ledger IDs.

Arithmetic and hypothetical inputs below are labelled **estimate**. Section, task and gate numbers are references.

| Version 3 row | Verdict | Section checked and smallest remaining edit |
|---|---|---|
| Shared position timeline | **Not closed — blocker** | §§3.1, 5.2. Reserve on a common zero-delay baseline, including its pickability clamp, then add N to the selected index. Claim exact N for **reserved** slots under matching inputs. Actual presentation is measured separately. |
| Early pick and margin | **Closed** | §§3.2, 5.2. The lower bound is inclusive at `g`. The table is nominal and the deadline uses actual arrival and reservation. Align task 3.2’s weaker `target minus ε` assertion with `g`. |
| Shared-slot collision | **Not closed — blocker** | §§5–6. The within-epoch rule works. On reset, seed the new grid’s pickable floor beyond surviving reservations, including committed items. Define how that floor maps across a grid refit. |
| Epoch and buffer ownership | **Closed** | §§5–6 and capture skill §§1a, 8. The source supplies a sequence and a pool buffer. The Conductor stamps the epoch. Native-format input also takes the copy path. |
| Duplicate delivery | **Closed** | §5.1 and capture skill §8 agree on ingestion and require the subsequent verdicts, state, epoch and pair endpoints in the fixture. |
| Presentation acceptance | **Closed** | §7 and metal-present §8 grade successive content changes using `slots.csv`, mode-specific intervals and rolling windows. Holds between changes must be traversed. |
| Gate backend and statistic | **Closed** | §4 specifies display link, provisional zero base, a latency percentile and pacing criteria in the same passing mode. |
| PQ handling | **Closed** | §§6, 7, 12 carry the attachment and require a TV comparison, with SDR operation until PQ handling is verified. |
| Provenance | **Not closed — minor** | PLAN header, §2 and RESULTS. The scaler transcription and saved mode listing are identified. Qualify morning **Low Power Mode** as unknown in RESULTS too. Its exception currently names only the power source. |
| Ledger coverage | **Not closed — blocker** | §6 represents skipped slots and separates `cancelTooLate`. Add `firstSequence` to `framesDropped` and define the reported range as consecutive, or specify an equivalent shared sequence-allocation rule. |
| Initializers and golden mapping | **Closed** | §6 requires public initializers and maps verdicts, flags and state transitions. The remaining pacer interface edit is to add `.catchUpSkip` to `SlotDecision` and its ledger mapping. |

**Arithmetic check — §5.2.** On-grid with no jitter at **120.000 Hz (estimate, specified input)**, the position targets in slot units are **0, 2.002, 4.004 (estimate)**. A takes **0**, the midpoint rejects **2** as early and ceilings to **3**, and B keeps **5** (all **estimate**). Both modes reserve the midpoint even when empty. B therefore takes **5** and **5 + N** respectively (**estimate**). But with startup `nextPickable = 1` and `N = 4`, the written first-position formula gives **1** and **4**, a difference of **3** (all **estimate**).

**Simulation coverage.** By inspection, the script implements the late-only band, immutable reservations, midpoint drop, real push and following midpoint skip on a fixed grid. It synthesizes each jittered midpoint independently of its real endpoints, omits `nextPickable`, and tests sampled phases. It does not compare modes, exercise a missing position or all-real stream, retain commitments across reset, refit the period, or test random jitter spanning more than `2ε`. Missing positions and larger jitter alone cannot violate strict slot ordering on the fixed grid. A reset can reuse an occupied slot, and a refit can move an existing index’s time before `g`.

**Required for yes:** freeze baseline reservation and reset-floor semantics, expose `catchUpSkip`, and define dropped-frame sequence allocation. The provenance wording can follow independently.

**OK to start task 2.0 and the gates: no**
===== PLAN.md version 4, section 3.1 =====
### 3.1 What frame generation adds: fixed by the schedule

Both modes compute the same *baseline slot* for a real frame: the rule in section 5.2 does not look at `N`, and applies the same pickability floor in both. Framegen reserves baseline + `N`. So **the reserved slots differ by exactly N for the same inputs: D = N × S**. The display link's lead time and slot rounding apply to both modes and cancel. What reaches the glass is measured separately (G5, task 3.3): a missed callback or a late present can add to either mode.

| Display | N | D |
|---|---|---|
| 120 Hz | 4 | 33.33 ms |
| 120 Hz | 5 | 41.67 ms |
| 59.94 Hz | 2 | 33.37 ms |
| 59.94 Hz | 3 | 50.05 ms |

**D = 33.3 ms meets the ≤ 35 ms target by construction. The open question is how often the midpoint is ready in time.**


===== PLAN.md version 4, section 5 (architecture, 5.1, 5.2) =====
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

**Positions.** While the state is `locked22`, the output timeline has a position every H: one at each unique frame's first-copy capture time, and one halfway between consecutive unique frames. In `native60` and `unknown` there is a position at each `new` frame. **Both modes reserve every position, in time order.** In framegen mode a midpoint position holds the generated frame. In real-only mode the same position is reserved and left empty, so the presenter holds the previous real frame there. The slot rule below never looks at `N`: it gives each position a **baseline slot**, identical in both modes for the same inputs, and the reserved slot is baseline + `N`.

Baseline earliest glass time of a position at content time `c`: `g = c + base`. `base` is the calibrated minimum from capture timestamp to pickable (0 in the G1 probe; measured in real-only mode at G5). The reserved slot's earliest glass time is `g + N × S`. `N = 0` in real-only mode.

- **Grid.** The presenter numbers slots with one counter that is never reset or renumbered, across epochs and display-mode changes (a missed callback advances it by the rounded gap). The grid is (anchor slot, anchor time, period): the latest observed slot, its `targetPresentationTimestamp`, and the median of the last 120 differences. Time of slot `k` = anchor time + (`k` − anchor slot) × period. A refit changes the predicted time of future slots, never an index. No constant is used.
- **First position of an epoch.** `baseline = max(first slot whose time ≥ g, firstFree − N)`. `firstFree` is handed to the pacer at the reset: one more than the highest slot still owned by a reservation that survives the epoch change (items the presenter has already committed, and real frames already reserved). It is 0 at start. So a new epoch can never land on a slot that is still owned.
- **Every later position.** Try `predicted = previous slot + step` (step = 2 at 120 Hz, 1 at 59.94 Hz). Keep it when its time lies in `[g, g + S + 2ε)`, ε = 1.5 ms. Otherwise recompute the first slot whose time ≥ `g`. **The band is late-only: no position is ever given a slot whose predicted time, at the moment of reservation, is earlier than its `g`.** The price is up to 2ε = 3 ms of extra delay just before a correction. Sustained flapping would need timestamp jitter above 2ε peak to peak.
- **Pickability floor, on the baseline.** A real frame whose baseline is lower than `nextPickable` (it arrived too late for its slot) is raised to `nextPickable` (`lateArrival` + 1). Because the floor is applied to the baseline, it is the same in both modes. A midpoint position is never floored: in real-only mode it is empty, and in framegen mode its reserved slot is `N` slots later. If that reserved slot is itself no longer pickable, the midpoint is not requested (`midpointMiss` + 1).
- **A reservation never moves.** If a baseline is not later than the last baseline: a midpoint position is dropped (`.collision`, the previous real frame is held one more slot); a real frame takes `last + 1` (`.pushedLate`) and the following midpoint position is skipped (`.catchUpSkip`), which removes one position and brings the timeline back.
- **Refit tolerance.** A reservation is judged against the grid as it was when the reservation was made. A later refit can move a reserved slot's time by the period error × the look-ahead (E: well under 0.1 ms over 6 slots; the period error is read from G1's per-slot log). The ledger stores both the predicted slot time at reservation and the observed target time; live runs allow 0.25 ms.
- **Order of work.** When B's first copy arrives, the Conductor reserves the midpoint position and then B's position, and only then, if the pair is safe (section 5.1) and the mode is framegen, dispatches to VideoToolbox. A missing or late midpoint leaves B's slot unchanged.
- **Expected behaviour (E).** 120 Hz: H is 2.002 slots, so with step 2 the slot time falls behind `g` by 1/60 ms per position and one extra slot (a 25 ms interval) is inserted every 500 positions = 8.34 s, about 72 in 10 minutes. 59.94 Hz: only the true offset between the PS5's clock and the panel's; at 50 ppm one correction per 334 s. Counted separately: `driftSlip`, `startupAlign`, `epochReanchor`, `midpointMiss`, `collision`, `pushedLate`, `catchUpSkip`, `lateArrival`.
- **Parity.** At 120 Hz the presenter's even/odd alignment follows from the reservations; the presenter has no controller of its own.
- **Checked.** `probes/pacer_sim.py` simulates this rule for 10 minutes at every starting phase, with no jitter, ± 1 ms alternating jitter and ± 1 ms random jitter. Version 4 adds: framegen slots equal real-only slots + N in every case; 5 % of real frames arriving 5–40 ms late; 2 % of positions missing; ± 2.5 ms random jitter (5 ms peak to peak, wider than 2ε); an all-real stream; an epoch reset while earlier slots are still owned. All pass. Not simulated: a grid whose period is refitted during the run (covered by the refit tolerance above and by task 3.2). Result (M, simulation): 120 Hz: at most 73 corrections, nothing dropped; 59.94 Hz at −50, 0 and +50 ppm: at most 3 corrections and 2 dropped midpoint positions; no slot before its `g` and no shared slot in any case. The first version of the rule failed this check on a display slower than the source (it pushed every frame); the collision rule above is the fix. The Swift `Pacer` must reproduce this script's slot sequences (task 3.2).


===== PLAN.md version 4, section 6 =====
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

public struct SlotGrid: Sendable { public var anchorSlot: Int64; public var anchorTime: Double; public var period: Double; public var nextPickable: Int64
    public func time(of slot: Int64) -> Double }  // anchorTime + Double(slot - anchorSlot) * period. Slot indices come from one presenter counter and are never renumbered
public struct PacerConfig: Sendable { public var stepSlots: Int /* 2 or 1 */; public var base: Double; public var delaySlots: Int /* N */; public var epsilon: Double }
public enum SlotDecision: Sendable { case slot(Int64), pushedLate(Int64), collision, catchUpSkip, gridNotReady }   // slot values are baseline + N
public struct Pacer: Sendable {                   // owned and mutated only by the Conductor
    public init(config: PacerConfig)
    public mutating func reset(firstFreeSlot: Int64)   // on every epoch change. 1 + the highest slot owned by a surviving reservation; 0 at start
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
    case framesDropped(firstSequence: UInt64, count: Int, reason: String, hostTime: Double) }   // every frame lost before the copy: device drop, pool exhausted, unsupported subtype, replay behind.
    // A source's `sequence` counts every frame the device or file produced, delivered or not, with no gaps. The lost frames are firstSequence ..< firstSequence + count;
    // the Conductor makes one FrameID and one items.csv row for each.
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
    func cancel(epochBefore: UInt32) -> [FrameID] // drops uncommitted items of older epochs; returns the ones already committed (they will be shown).
                                                  // The Conductor knows their slots (it reserved them) and passes max + 1 to Pacer.reset(firstFreeSlot:)
    var slotGrid: SlotGrid? { get }               // lock-free snapshot, written on the display thread
    var onSlotReport: ((SlotReport) -> Void)?     // called on a utility queue, never on the display thread
}
```

**Two ledgers, written under `runs/<date-time>/`.**
- `items.csv`: one row per frame the device or file produced (including frames lost before the copy) and per midpoint position, whatever became of it: id, generated, capture PTS (host), arrival time, luma diff, verdict, state, flags, pair id, reserved slot, predicted slot time at reservation, interpolation start/end, **one** terminal disposition (`shown`, `dropped:preCopy:<reason>`, `dropped:<reason>`, `emptyPosition` (real-only), `notRequested:<reason>`, `late`, `stale`, `cancelled`, `collision`, `catchUpSkip`, `unpresentedAtExit`), and a separate yes/no column `cancelTooLate` (a cancelled item that was already committed: its disposition is `shown`, so it is counted once).
- `slots.csv`: one row per slot of the grid from first to last callback: slot, target time, pick time, outcome (`shown` id, `held` id, `skipped`), GPU start/end, presented time (0 kept). A slot with no callback gets a `skipped` row written by the Conductor when the next slot is observed.

**Golden-file mapping for task 2.1.** The golden CSV columns are `frame,is_new,state,flags,offline_is_new`. `is_new` 1/0 = `.new`/`.duplicate`. `state`: `UNKNOWN`, `LOCKED_2_2`, `PASSTHROUGH_60` = `.unknown`, `.locked22`, `.native60`. `flags` (space-separated): `first`, `timeReset`, `gap` = `.timeGap`, `latePromotion`, `sceneCut`, `static` = `.staticPicture`, `phaseFlip`; an entry `X->Y` means `previousState` = X and `state` = Y on that row. `offline_is_new` is not produced by the detector.
- `counters.txt` and `run.json` (mode, display mode applied, N, working size, power state, load average).

`tools/stats.py` computes every acceptance number from these, including rolling 15 s glitch windows and generated yield (midpoints shown ÷ midpoint opportunities). A hand-audited fixture with known skipped slots and wrong ids is part of its tests.


===== PLAN.md version 4, section 7, task 3.2 row =====
| 3 | 3.2 `Pacer` with N > 0, Conductor pair logic, epochs | Sol | metal-present §pacing | simulated clocks: exact slot and content id sequences for 59.94 vs 120.000, 59.94 vs 59.94 ± 50 ppm, every starting phase in 0.1 S steps, ± 1 ms jitter at a boundary, missing B, late real frames, busy interpolator, epoch reset with committed items still owned, grid refit, N change. Framegen slots = real-only slots + N on the same inputs. No two items in one slot. No slot whose predicted time at reservation is before its `g` (live: observed target ≥ `g` − 0.25 ms). Slot sequences equal `probes/pacer_sim.py` on its cases |

===== PLAN.md version 4, section 13, version 4 table =====
**Version 4, after Astra's confirmation pass on version 3 (`reviews/06-astra-confirm-plan.md`: 7 rows closed, 3 blockers, 1 minor):**

| Confirmation finding | Change |
|---|---|
| The startup clamp `max(ceil, nextPickable)` was applied after N was added, so the first frame differed by N − 1 slots between modes | 3.1 and 5.2: the rule computes a baseline slot without N, floor included; reserved slot = baseline + N; the claim is about reserved slots, presentation is measured separately |
| After an epoch reset the pacer forgot its last reservation while the presenter still owned a committed slot | 5.2 and 6: `reset(firstFreeSlot:)`; slot indices are one presenter counter that is never renumbered; refit tolerance stated |
| `SlotDecision` could not tell a skipped midpoint from a collision; `framesDropped` had no sequence | 6: `.catchUpSkip`; `framesDropped(firstSequence:count:…)` with a gap-free source sequence; ledger disposition `catchUpSkip` and predicted slot time |
| Task 3.2 asserted the weaker "target minus ε" | 7: pass line rewritten on `g`, with the mode identity and the reset case |
| Morning run: Low Power Mode unknown, not only the power source | RESULTS.md row corrected |
| Simulation covered neither mode comparison, late frames, missing positions, wide jitter, all-real streams nor reset | `probes/pacer_sim.py` extended; default sequences unchanged (27 cases compared with the version 3 script) |


===== probes/pacer_sim.py (runs clean: prints "pacer_sim ok") =====
#!/usr/bin/env python3
"""Check of PLAN.md section 5.2 (position timeline, baseline + N, late-only band). Run: python3 probes/pacer_sim.py
Simulates 10 minutes of positions H apart on a slot grid and asserts: no slot before g, no two positions
in one slot, and the number of corrections expected from arithmetic."""
import math, random
H = 1001 / 60            # ms, one position
EPS = 1.5

def run(S, step, phase, jitter, seed=1, minutes=10, N=0, late=0.0, first_free=None, all_real=False, miss=0.0):
    """Positions alternate real (even i) and midpoint (odd i), as in locked22 (all_real: native60).
    The baseline slot k is computed with N = 0 in both modes; the reserved slot is k + N.
    late: chance that a real frame arrives 5-40 ms late: its baseline is floored at the next pickable slot. Midpoints are never floored.
    first_free: after an epoch reset, the first slot not owned by a surviving reservation.
    miss: chance that a position does not exist (frame lost before the copy)."""
    rnd = random.Random(seed); xr = random.Random(seed + 1000)   # xr: separate stream, so the default sequences do not change
    n = int(minutes * 60000 / H)
    last = None; early = dropped = pushed = corrections = 0; slots = []; skip_next_mid = False
    for i in range(n):
        real = all_real or i % 2 == 0
        if not real and skip_next_mid:             # catchUpSkip: removes one position after a pushed real frame
            skip_next_mid = False; dropped += 1; continue
        j = (jitter if i % 2 else -jitter) if seed == 0 else rnd.uniform(-jitter, jitter)
        g = phase + i * H + j                      # baseline earliest glass time: base folded into phase, N not involved
        if miss and xr.random() < miss: continue
        floor = math.ceil((g + xr.uniform(5, 40)) / S) if real and late and xr.random() < late else None   # nextPickable
        if last is None:
            k = math.ceil(g / S)
            if first_free is not None: k = max(k, first_free - N)
        else:
            k = last + step
            if not (g <= k * S < g + S + 2 * EPS):
                k = math.ceil(g / S); corrections += 1
        if floor is not None: k = max(k, floor)
        if last is not None and k <= last:         # a reservation never moves
            if not real:
                dropped += 1; continue             # collision: midpoint position dropped, previous real held
            k = last + 1; pushed += 1; skip_next_mid = True
        if k * S < g - 1e-9: early += 1
        slots.append(k + N); last = k
    return early, dropped, pushed, corrections, slots

def demo():
    S120 = 1000 / 120
    worst = 0
    for p in range(0, 100):                        # every starting phase, 1 % of a slot apart
        for jitter, seed in ((0, 1), (1.0, 0), (1.0, 7)):
            early, dropped, pushed, corr, slots = run(S120, 2, p / 100 * S120, jitter, seed)
            assert early == 0, ("early", p, jitter)
            assert dropped == 0 and pushed == 0, ("drop on a faster grid", p, jitter)
            assert len(set(slots)) == len(slots)
            # E: 600 s / 8.342 s = 71.9 corrections
            assert 70 <= corr <= 74, ("120 Hz corrections", p, jitter, corr)
            worst = max(worst, corr)
    wm = wd = 0
    for ppm in (-50, 0, 50):
        Sm = H * (1 + ppm * 1e-6)                  # panel 59.94 Hz, off by ppm
        for p in range(0, 100, 5):
            for jitter, seed in ((0, 1), (1.0, 0), (1.0, 7)):
                early, dropped, pushed, corr, slots = run(Sm, 1, p / 100 * Sm, jitter, seed)
                assert early == 0, ("early matched", ppm, p, jitter)
                assert len(set(slots)) == len(slots)
                # E: one correction per 334 s at 50 ppm -> at most 2 in 10 min, plus 1 at startup
                assert corr <= 3 and dropped <= 2, ("matched corrections", ppm, p, jitter, corr, dropped)
                wm = max(wm, corr); wd = max(wd, dropped)
    # Version 4 cases: same baseline in both modes, late real frames, lost positions, jitter wider than 2 eps, all-real stream, epoch reset.
    inc = lambda sl: all(b > a for a, b in zip(sl, sl[1:]))
    for S, step in ((S120, 2), (H, 1)):
        for p in (0.0, 0.3, 0.8):
            for kw in ({}, {"late": 0.05}, {"miss": 0.02}, {"late": 0.05, "miss": 0.02}, {"all_real": True, "late": 0.05}):
                for jitter in (1.0, 2.5):          # 2.5 ms random = 5 ms peak to peak, wider than 2 eps
                    e0, _, _, _, s0 = run(S, step, p * S, jitter, 7, **kw)
                    e4, _, _, _, s4 = run(S, step, p * S, jitter, 7, N=4, **kw)
                    assert e0 == 0 and e4 == 0 and inc(s0), ("early or shared", S, p, kw, jitter)
                    assert s4 == [k + 4 for k in s0], ("framegen is not real-only + N", S, p, kw)
            # epoch reset while slots up to F - 1 are still owned by committed items: nothing lands at or below them, and the timeline comes back
            F = math.ceil(p) + 4 + 9
            e, _, _, _, sr = run(S, step, p * S, 0, 1, N=4, first_free=F)
            _, _, _, _, sn = run(S, step, p * S, 0, 1, N=4)
            assert e == 0 and inc(sr) and sr[0] == F and abs(sr[-1] - sn[-1]) <= 1, ("reset floor", S, p, sr[:4], sr[-1], sn[-1])
    print("pacer_sim ok. 120 Hz: corrections per 10 min <=", worst, ", none dropped. 59.94 Hz +-50 ppm: corrections <=", wm, ", positions dropped <=", wd, ". No early slot, no shared slot, all phases.")

if __name__ == "__main__":
    demo()

===== RESULTS.md, the corrected row =====
Numbers only. Each row names the file that holds the raw output. Machine state for everything below unless a row says otherwise: MacBook Pro M3 Pro, macOS 27.2.1, **under load** (six ffmpeg jobs from another project, load average 4–18), **Low Power Mode on, on battery** (checked 13:32; power source during the morning run unknown), Elgato not plugged in, OBS not running.
| 1920×1080 | back to back, 10 min of footage in 271 s wall, morning, power source and Low Power Mode unknown | 12.80 | 13.54 | 14.32 | 130.82 | `probes/out/run-10min-during-render.txt` |

===== END OF MATERIAL =====
