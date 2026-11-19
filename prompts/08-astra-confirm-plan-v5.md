You are the independent reviewer on a macOS project (PS5 30 fps gameplay captured by an Elgato card, shown at 60 fps on a MacBook Pro with generated frames). Your check of version 4 of `PLAN.md` closed three of four points and left one blocker: at an epoch reset, `firstFree − N` made the first baseline depend on N. The lead has made version 5. Confirm or refute that this last point is closed. Do not re-open points you marked Closed, and do not raise new points unless they block task 2.0 (package skeleton and shared types) or gates G1 to G4.

**Everything you need is pasted below, between the `=====` markers. Do not run any command and do not open any file: answer from this prompt alone.**

The lead did not take your formula `max(ceilGrid(g), firstFree) + N` and gives a reason in section 13. Check that reason with your own arithmetic rather than accepting it: in your reset example you used the same `firstFree = 9` in both modes. Under identical inputs (same frames, same timestamps, same arrival times), where does the surviving real frame sit in real-only and where in framegen, and what does each formula then give?

Then answer:
1. Version 5 rule: first baseline of an epoch = `max(first slot whose time ≥ g, last real baseline + 1)`, then the pickability floor, reserved slot = baseline + N. Is the baseline now independent of N for a fixed N? Work one reset example with numbers, in both modes.
2. Can anything that survives an epoch change (a pending real frame, a committed real frame, a committed midpoint) end up at or after the first slot of the new epoch? Consider each. Consider also a change of N at the reset (5 → 4, 4 → 0).
3. Read `run()` and the reset asserts in `probes/pacer_sim.py`. Do they implement and test the rule as written? Name anything the plan claims about a reset that the script does not test and that task 3.2's pass line also does not cover.
4. Section 6: `reset(delaySlots:)` and `cancel(epochBefore:generatedOnly:)`. Is anything missing for task 2.0 to be written without guessing?

Format: findings first, each with severity (blocker / major / minor), the section, and the smallest fix. Label every number "measured" (you can point at the line below it came from) or "estimate". Under 500 words.

End with one line: **"OK to start task 2.0 and the gates: yes / no"**. If no, list only the edits that would make it yes.


===== YOUR CHECK OF VERSION 4 =====
- **Blocker — shared timeline / startup clamp: Not closed (§§3.1, 5.2; task 3.2).** Startup is fixed. Reset is not: `firstFree − N` makes the baseline depend on `N`, even for identical inputs. **Smallest fix preserving the exact‑N claim:** use `max(ceilGrid(g), firstFree)` as the first baseline in both modes, then apply the real-frame floor and add `N`. Make the same change in the simulator and compare both modes with the same binding `firstFree`. The framegen reset assertion should expect `firstFree + N` when that bound wins.
- **Blocker — shared-slot collision at reset / refit: Closed (§§5.2, 6).** This is distinct from exact‑N spacing. Even the current subtraction ensures the first *reserved* index is at least `firstFree`. Later reservations strictly increase. A refit changes predicted times, not slot identities; the early-time guarantee is explicitly judged at reservation. No edit needed for that invariant.
- **Blocker — ledger coverage / `SlotDecision`: Closed (§6).** `firstSequence` and `count` identify each consecutive pre-copy loss. `.catchUpSkip` and `.collision` have distinct ledger dispositions. No edit needed.
- **Minor — provenance: Closed (`RESULTS.md`, morning row).** The row explicitly marks both power source and Low Power Mode unknown, overriding the header default. No edit needed.

**Arithmetic (all numbers here are estimates for hypothetical inputs; section, task and gate numbers are references).** At **120.000 Hz**, start on-grid at slot **0**, with `nextPickable = 1`, `firstFree = 0`, and framegen `N = 4`. Both modes start at baseline **0** and floor it to **1**. Real-only reserves **1**; framegen reserves **5**: **5 − 1 = 4**, exactly `N`. By contrast, reset with the same inputs except `firstFree = 9`: real-only reserves **9**, and framegen reserves **max(0, 9 − 4, 1) + 4 = 9**. No old slot is reused, but the inter-mode difference is **0**.

**Simulator (§5.2).** `run()` implements the written reset subtraction, real-only-in-the-sense-of-*real-frame* floor, and never-moves rule—not an `N`-independent reset baseline. It models `nextPickable` only for injected late arrivals and defaults to no startup `first_free` bound. On a fixed positive-period grid with an accurate survivor bound, neither floor can create a shared slot or move a slot before `g`: both only raise indices. The asserts cannot detect an **omitted survivor** because `run()` receives a scalar bound, not the old reservations. Nor do they compare modes with a binding reset bound.

**Midpoint (§§5.1–5.2, 6).** Yes. Both modes try the same unfloored midpoint baseline when B arrives. Real-only leaves the position empty. Framegen tests the **delayed reserved slot’s** pick deadline, not the past baseline’s; if that slot is no longer pickable, it records a miss without moving B. A skipped or collided midpoint has no reserved slot and needs no dispatch deadline.

**OK to start task 2.0 and the gates: no**
===== PLAN.md version 5, section 3.1 =====
### 3.1 What frame generation adds: fixed by the schedule

Both modes compute the same *baseline slot* for a real frame: the rule in section 5.2 does not look at `N`, and applies the same pickability floor in both. Framegen reserves baseline + `N`. So **the reserved slots differ by exactly N for the same inputs: D = N × S**. The display link's lead time and slot rounding apply to both modes and cancel. What reaches the glass is measured separately (G5, task 3.3): a missed callback or a late present can add to either mode.

| Display | N | D |
|---|---|---|
| 120 Hz | 4 | 33.33 ms |
| 120 Hz | 5 | 41.67 ms |
| 59.94 Hz | 2 | 33.37 ms |
| 59.94 Hz | 3 | 50.05 ms |

**D = 33.3 ms meets the ≤ 35 ms target by construction. The open question is how often the midpoint is ready in time.**


===== PLAN.md version 5, section 5 intro (Conductor, epochs, commit boundary) =====
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


===== PLAN.md version 5, section 5.2 =====
### 5.2 Pacer: one position timeline for both modes

**Positions.** While the state is `locked22`, the output timeline has a position every H: one at each unique frame's first-copy capture time, and one halfway between consecutive unique frames. In `native60` and `unknown` there is a position at each `new` frame. **Both modes reserve every position, in time order.** In framegen mode a midpoint position holds the generated frame. In real-only mode the same position is reserved and left empty, so the presenter holds the previous real frame there. The slot rule below never looks at `N`: it gives each position a **baseline slot**, identical in both modes for the same inputs, and the reserved slot is baseline + `N`.

Baseline earliest glass time of a position at content time `c`: `g = c + base`. `base` is the calibrated minimum from capture timestamp to pickable (0 in the G1 probe; measured in real-only mode at G5). The reserved slot's earliest glass time is `g + N × S`. `N = 0` in real-only mode.

- **Grid.** The presenter numbers slots with one counter that is never reset or renumbered, across epochs and display-mode changes (a missed callback advances it by the rounded gap). The grid is (anchor slot, anchor time, period): the latest observed slot, its `targetPresentationTimestamp`, and the median of the last 120 differences. Time of slot `k` = anchor time + (`k` − anchor slot) × period. A refit changes the predicted time of future slots, never an index. No constant is used.
- **First position of an epoch.** It is always a real frame: a midpoint needs two unique frames of the same epoch. `baseline = max(first slot whose time ≥ g, last real baseline + 1)`, then the pickability floor below. **The pacer keeps the baseline of the last real frame it reserved across a reset; a reset only forgets the band.** Real frames already reserved survive an epoch change in both modes, at the same baseline, so this floor is the same in both modes and the difference stays exactly N. Midpoints of the old epoch never constrain the new one: uncommitted ones are cancelled, and a committed one sits below `nextPickable`, which the pickability floor already clears (reserved slot ≥ `nextPickable` + N). **A change of N** is an epoch change and not a comparison between modes: the surviving real frame sits at its old N, so the floor is raised by `max(0, N_old − N_new)` and the new slot is still later than it.
- **Every later position.** Try `predicted = previous slot + step` (step = 2 at 120 Hz, 1 at 59.94 Hz). Keep it when its time lies in `[g, g + S + 2ε)`, ε = 1.5 ms. Otherwise recompute the first slot whose time ≥ `g`. **The band is late-only: no position is ever given a slot whose predicted time, at the moment of reservation, is earlier than its `g`.** The price is up to 2ε = 3 ms of extra delay just before a correction. Sustained flapping would need timestamp jitter above 2ε peak to peak.
- **Pickability floor, on the baseline.** A real frame whose baseline is lower than `nextPickable` (it arrived too late for its slot) is raised to `nextPickable` (`lateArrival` + 1). Because the floor is applied to the baseline, it is the same in both modes. A midpoint position is never floored: in real-only mode it is empty, and in framegen mode its reserved slot is `N` slots later. If that reserved slot is itself no longer pickable, the midpoint is not requested (`midpointMiss` + 1).
- **A reservation never moves.** If a baseline is not later than the last baseline: a midpoint position is dropped (`.collision`, the previous real frame is held one more slot); a real frame takes `last + 1` (`.pushedLate`) and the following midpoint position is skipped (`.catchUpSkip`), which removes one position and brings the timeline back.
- **Refit tolerance.** A reservation is judged against the grid as it was when the reservation was made. A later refit can move a reserved slot's time by the period error × the look-ahead (E: well under 0.1 ms over 6 slots; the period error is read from G1's per-slot log). The ledger stores both the predicted slot time at reservation and the observed target time; live runs allow 0.25 ms.
- **Order of work.** When B's first copy arrives, the Conductor reserves the midpoint position and then B's position, and only then, if the pair is safe (section 5.1) and the mode is framegen, dispatches to VideoToolbox. A missing or late midpoint leaves B's slot unchanged.
- **Expected behaviour (E).** 120 Hz: H is 2.002 slots, so with step 2 the slot time falls behind `g` by 1/60 ms per position and one extra slot (a 25 ms interval) is inserted every 500 positions = 8.34 s, about 72 in 10 minutes. 59.94 Hz: only the true offset between the PS5's clock and the panel's; at 50 ppm one correction per 334 s. Counted separately: `driftSlip`, `startupAlign`, `epochReanchor`, `midpointMiss`, `collision`, `pushedLate`, `catchUpSkip`, `lateArrival`.
- **Parity.** At 120 Hz the presenter's even/odd alignment follows from the reservations; the presenter has no controller of its own.
- **Checked.** `probes/pacer_sim.py` simulates this rule for 10 minutes at every starting phase, with no jitter, ± 1 ms alternating jitter and ± 1 ms random jitter. Version 4 adds: framegen slots equal real-only slots + N in every case; 5 % of real frames arriving 5–40 ms late; 2 % of positions missing; ± 2.5 ms random jitter (5 ms peak to peak, wider than 2ε); an all-real stream; an epoch reset in mid-run with no timestamp jump, a jump of −50 ms (the kept baseline then binds) and +80 ms; a change of N at the reset (4→0, 0→4, 5→4, 2→3). All pass, and removing the reset floor from the script makes it fail. Not simulated: a grid whose period is refitted during the run (covered by the refit tolerance above and by task 3.2), and the commit clock (the argument for committed midpoints above is by construction, tested in task 3.2). Result (M, simulation): 120 Hz: at most 73 corrections, nothing dropped; 59.94 Hz at −50, 0 and +50 ppm: at most 3 corrections and 2 dropped midpoint positions; no slot before its `g` and no shared slot in any case. The first version of the rule failed this check on a display slower than the source (it pushed every frame); the collision rule above is the fix. The Swift `Pacer` must reproduce this script's slot sequences (task 3.2).


===== PLAN.md version 5, section 6 (code block only) =====
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
    public mutating func reset(delaySlots: Int)   // on every epoch change; the N to use from now on. Forgets the band, keeps the last real baseline and the N it was reserved with (5.2)
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
    func cancel(epochBefore: UInt32, generatedOnly: Bool) -> [FrameID] // drops uncommitted items of older epochs (generated ones only: real frames keep their slots);
                                                  // returns the ones already committed (they will be shown)
    var slotGrid: SlotGrid? { get }               // lock-free snapshot, written on the display thread
    var onSlotReport: ((SlotReport) -> Void)?     // called on a utility queue, never on the display thread
}
```


===== PLAN.md version 5, section 7, task 3.2 row =====
| 3 | 3.2 `Pacer` with N > 0, Conductor pair logic, epochs | Sol | metal-present §pacing | simulated clocks: exact slot and content id sequences for 59.94 vs 120.000, 59.94 vs 59.94 ± 50 ppm, every starting phase in 0.1 S steps, ± 1 ms jitter at a boundary, missing B, late real frames, busy interpolator, epoch reset with a real frame still pending and a midpoint already committed, timestamp jump backwards, grid refit, N change up and down. Framegen slots = real-only slots + N on the same inputs. No two items in one slot. No slot whose predicted time at reservation is before its `g` (live: observed target ≥ `g` − 0.25 ms). Slot sequences equal `probes/pacer_sim.py` on its cases |

===== PLAN.md version 5, section 13, version 5 table =====
**Version 5, after Astra's check of version 4 (`reviews/07-astra-confirm-plan-v4.md`: 3 of 4 closed):**

| Finding | Change |
|---|---|
| The reset floor `firstFree − N` made the first baseline of an epoch depend on N | 5.2 and 6: the floor is `last real baseline + 1`, kept inside the pacer across `reset(delaySlots:)`; no slot number is passed in from outside, so a survivor cannot be left out. Only a change of N raises it, by `N_old − N_new` |
| The simulation took the bound as a number and did not compare modes with it binding | `probes/pacer_sim.py`: reset inside one run, with timestamp jumps and N changes; mode identity asserted with the floor binding; a mutation without the floor fails |

Not adopted from that check: `max(ceil, firstFree) + N` with the same `firstFree` in both modes. With the same inputs the surviving real frame sits N slots later in framegen, so `firstFree` itself differs by N between modes; that formula would then give a difference of 2N at a reset (E: real-only survivor at 8 → new slot 9; framegen survivor at 12 → 13 + 4 = 17).


===== probes/pacer_sim.py (runs clean: prints "pacer_sim ok"; with the line `if floor_b is not None: k = max(k, floor_b)` removed it fails the "reset" assert) =====
#!/usr/bin/env python3
"""Check of PLAN.md section 5.2 (position timeline, baseline + N, late-only band). Run: python3 probes/pacer_sim.py
Simulates 10 minutes of positions H apart on a slot grid and asserts: no slot before g, no two positions
in one slot, and the number of corrections expected from arithmetic."""
import math, random
H = 1001 / 60            # ms, one position
EPS = 1.5

def run(S, step, phase, jitter, seed=1, minutes=10, N=0, late=0.0, all_real=False, miss=0.0, reset_at=None, N2=None, jump=0.0):
    """Positions alternate real (even i) and midpoint (odd i), as in locked22 (all_real: native60).
    The baseline slot k is computed without N in both modes; the reserved slot is k + N.
    late: chance that a real frame arrives 5-40 ms late: its baseline is floored at the next pickable slot. Midpoints are never floored.
    miss: chance that a position does not exist (frame lost before the copy).
    reset_at: position index of an epoch reset. The band is forgotten, the last real baseline is kept, uncommitted midpoints are cancelled.
    N2: N after the reset (a change of N is an epoch change). jump: ms added to every later timestamp (a timestamp jump)."""
    rnd = random.Random(seed); xr = random.Random(seed + 1000)   # xr: separate stream, so the default sequences do not change
    n = int(minutes * 60000 / H)
    last = last_real = floor_b = None; early = dropped = pushed = corrections = 0; slots = []; isreal = []; skip_next_mid = False
    for i in range(n):
        if i == reset_at:
            while isreal and not isreal[-1]: slots.pop(); isreal.pop()      # midpoints after the last real frame: cancelled
            if N2 is not None and last_real is not None: floor_b = last_real + 1 + max(0, N - N2)
            elif last_real is not None: floor_b = last_real + 1
            if N2 is not None: N = N2
            last = None; skip_next_mid = False; phase += jump
        real = all_real or i % 2 == 0
        if last is None and not real: continue     # an epoch starts on a real frame
        if not real and skip_next_mid:             # catchUpSkip: removes one position after a pushed real frame
            skip_next_mid = False; dropped += 1; continue
        j = (jitter if i % 2 else -jitter) if seed == 0 else rnd.uniform(-jitter, jitter)
        g = phase + i * H + j                      # baseline earliest glass time: base folded into phase, N not involved
        if miss and xr.random() < miss: continue
        floor = math.ceil((g + xr.uniform(5, 40)) / S) if real and late and xr.random() < late else None   # nextPickable
        if last is None:
            k = math.ceil(g / S)
            if floor_b is not None: k = max(k, floor_b)
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
        slots.append(k + N); isreal.append(real); last = k
        if real: last_real = k
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
            # Epoch reset in mid-run, with and without a timestamp jump backwards (the kept real baseline then binds):
            # still no early slot, no shared slot, framegen = real-only + N, and the timeline returns to the undisturbed one.
            _, _, _, _, sn = run(S, step, p * S, 1.0, 7)
            for jump in (0.0, -50.0, 80.0):
                e0, _, _, _, s0 = run(S, step, p * S, 1.0, 7, reset_at=1000, jump=jump)
                e4, _, _, _, s4 = run(S, step, p * S, 1.0, 7, N=4, reset_at=1000, jump=jump)
                assert e0 == 0 and e4 == 0 and inc(s0) and s4 == [k + 4 for k in s0], ("reset", S, p, jump)
                if jump == 0.0: assert abs(s0[-1] - sn[-1]) <= 1, ("reset does not come back", S, p, s0[-1], sn[-1])
            # A change of N at the reset: the surviving real frame sits at its old N, nothing may land at or before it.
            for Na, Nb in ((4, 0), (0, 4), (5, 4), (2, 3)):
                for jump in (0.0, -50.0):
                    e, _, _, _, sc = run(S, step, p * S, 1.0, 7, N=Na, reset_at=1000, N2=Nb, jump=jump)
                    assert e == 0 and inc(sc), ("N change", S, p, Na, Nb, jump)
    print("pacer_sim ok. 120 Hz: corrections per 10 min <=", worst, ", none dropped. 59.94 Hz +-50 ppm: corrections <=", wm, ", positions dropped <=", wd, ". No early slot, no shared slot, all phases.")

if __name__ == "__main__":
    demo()

===== END OF MATERIAL =====
