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