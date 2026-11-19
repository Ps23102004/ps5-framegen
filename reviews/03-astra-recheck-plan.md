**E** means estimate from arithmetic or a specified test input. **M** means measured in the named saved file. Section and task numbers are references.

### Four blockers

1. **Latency budget — Partly.** §§3.1–3.3 now separate scheduled delay, midpoint readiness and TV-relative latency. §3.2 still calls `D−H` the worst-phase window while §5.2 permits an ε-early pick. At four fast slots, the E median margin falls from `1.04` to `−0.46 ms` before any late arrival of B. Label the table nominal and subtract actual early assignment and excess arrival delay for the deadline check.

2. **Pacer — Partly.** §5.2 fixes reservation order. Its history still differs by mode. Starting on-grid without jitter, framegen’s midpoint and B land at E slots `2,4` before adding N. Real-only skips the midpoint, predicts `2` for B, then ceilings `4.004` to `5`. The differential is `N−1`. Reserve the same baseline content timeline in both modes, including unshown midpoint positions, then add N. Define one collision policy as below.

3. **Cadence specification — Partly.** §5.1 now separates detector confidence from pair safety and identifies the commit boundary. Capture skill §8 still says to ignore duplicate deliveries, while `Detector.push` counts a short interval and continues classification. Specify whether filtering happens before `ingest`, and add a fixture asserting the next verdict, endpoint IDs and epoch after that input. [Reference implementation](~/Developer/ps5-framegen/probes/cadence_ref.py:63)

4. **Interfaces and ownership — Partly.** §§5–6 assign scheduling to the Conductor, yet `FrameSource` supplies an already epoch-stamped `FrameID`. `CVPixelBuffer` also carries no pool provenance, and capture skill §8 still passes native buffers unchanged despite §1a requiring a copy. Have the source emit a sequence and a buffer constructible only by the normaliser. Let the Conductor stamp the epoch. Delete the identity exception.

### Four majors

1. **Acceptance criteria — Partly.** §7 tasks 2.3–2.4 now distinguish content cadence by mode. Metal-present §8 still grades consecutive drawable presentations and reads `frames.csv`. Use content-ID changes from `slots.csv`, the mode-specific interval and rolling windows. Record `cancelTooLate` separately from terminal disposition so a shown item counts once.

2. **Gates — Partly.** §4 corrects G2 transport evidence, G3 failure branches and G5 sequencing. G1 can still pass solely on `nextDrawable`, while §5.2 requires display-link observations. Define the plain loop’s grid and pick-time source or make that backend diagnostic only. Specify which latency percentile must pass.

3. **Live recovery — Partly.** §§5, 5.3 and 12 cover disconnects, fresh timestamps and mode readback. §§8–9 still defer PQ handling while task 2.2 tests only BT.709. Add a run-sheet branch that checks transfer metadata and black/white levels against the TV, then either verifies tone mapping or marks PQ unsupported.

4. **Provenance — Partly.** RESULTS corrects morning wall time and sampler scope. PLAN’s opening machine-state claim still includes the morning run despite unknown power, §2 labels the transcribed quiet MetalFX figure M, and RESULTS lists display modes without saved evidence. Qualify power per run and mark the latter observations reported-only.

### Three new checks

**§5.2, ε rule.** On the E 120.000 Hz grid, `S=8.333333 ms`, `H=16.683333 ms`, so drift is `1/60 ms` per interval. Start on-grid, then alternate `+1 ms` on odd samples and `−1 ms` on even ones. At samples 30–32 the slots are `60,63,65`. Sample 31 crosses ε (`31/60+1=1.517 ms`); sample 32 keeps the corrected step. Sustained reversal on this fixed grid requires crossing a `2ε=3 ms` hysteresis gap; jitter spans `2 ms`. Neither branch selects before observed `g−ε`.

For **every startup phase**, initial ceiling error `e₀∈[0,S)`. The next predicted error is `e₀−(H−step×S)+j₀−j₁`; keep exactly when it lies in `[−ε,S+ε)`. On a matched grid, `+1,−1 ms` jitter therefore causes a collision whenever `e₀≥S−0.5 ms`. Example: observed `g₀=0.25`, `g₁=S−1.75 ms`; both ceilings equal S. Preserve the committed reservation and explicitly drop or advance the newcomer.

**§3.2, all cells.** E milliseconds, using `W=NS−H` and `margin=W−1.10−T`. The three T values are M from [the paced and contended runs](~/Developer/ps5-framegen/probes/out/interp_speed_res.txt:71). Every printed cell rounds correctly.

| Grid / N | W | T=14.51 | T=18.28 | T=41.82 |
|---|---:|---:|---:|---:|
| 120 / 4 | 16.650 | 1.040 | −2.730 | −26.270 |
| Matched / 2 | 16.683 | 1.073 | −2.697 | −26.237 |
| 120 / 5 | 24.983 | 9.373 | 5.603 | −17.937 |
| Matched / 3 | 33.367 | 17.757 | 13.987 | −9.553 |

**§6, phase 2 freeze.** Task 2.1 needs public initializers and a golden-flag mapping, including state transitions. Tasks 2.2–2.4 need a pre-copy drop event and a skipped-slot outcome. Neither ledger can recover those from successful frame deliveries alone. G1 also needs a provisional `base` before G5 calibrates it.

**Edits needed to start:** freeze the phase 2 types and ownership, settle shared reservations and collisions, align the skills’ acceptance rules, and specify G1’s backend, baseline and pass statistic. Hardware outcomes remain unverified.

**OK to start task 2.0 and the gates: no**