#!/usr/bin/env python3
"""Executable reference for the cadence rules in skills/capture-cadence/SKILL.md. Not app code.

  python3 probes/cadence_ref.py selftest             # the six required cases, with their expected results
  python3 probes/cadence_ref.py run <trace.csv>...   # online detector vs offline two-pass check on a diff trace
  python3 probes/cadence_ref.py dump <trace.csv> <out.csv>   # golden file: frame,is_new,state,flags,offline_is_new

Trace CSV: columns frame,pts_s,diff (from probes/luma_mad or probes/cadence_trace.py).
The Swift detector in FrameGenCore must give the same verdict, state and counters as Detector here
for the same (timestamp, diff) sequence. Every number in PARAMS is a starting value to be fitted on
uncompressed capture; none was fitted on real capture yet.
"""
import collections, csv, math, sys

UNKNOWN, LOCKED, PASS60 = "UNKNOWN", "LOCKED_2_2", "PASSTHROUGH_60"
PARAMS = dict(
    period=1001 / 60000,  # s, nominal capture interval; tracked at run time
    t_floor=0.02,         # diff <= this is always a duplicate (8-bit code units)
    k_lo=2.0,             # t_lo = max(t_floor, k_lo * (noise mean + 4 * noise deviation))
    k_motion=0.5,         # t_hi = max(2 * t_lo, k_motion * motion)
    r_boot=4.0,           # before 8 noise samples: duplicate if diff * r_boot <= previous diff
    cut_abs=20.0, cut_k=4.0,   # scene cut: diff >= max(cut_abs, cut_k * motion)
    lock_run=8,           # UNKNOWN -> LOCKED_2_2: alternating frames in a row
    pass_window=12, pass_new=10,   # -> PASSTHROUGH_60: at least pass_new NEW in the last pass_window frames
    pass_exit_dups=4,     # PASSTHROUGH_60 -> UNKNOWN: at least this many DUP in the last pass_window frames
    window=32, max_violations=6,   # LOCKED_2_2 -> UNKNOWN: alternation violations in the last window (and few NEW, see push)
    static_run=5,         # duplicates in a row that count as a static screen (state frozen); must be < max_violations
    reset_gap=0.5,        # s without a frame: back to UNKNOWN
)


class Detector:
    def __init__(self, **overrides):
        self.p = dict(PARAMS, **overrides)
        self.state = UNKNOWN
        self.counters = collections.Counter()
        self.period = self.p["period"]
        self.noise_mean = self.noise_dev = 0.0
        self.noise_n = 0
        self.motion = 0.0
        self.motion_n = 0
        self.prev_t = self.prev_d = None
        self.slots = 0            # capture slots since the last NEW verdict
        self.last_new = True
        self.prev_mid_dup = False
        self.alt_run = self.dup_run = 0
        self.win = collections.deque(maxlen=self.p["window"])  # (is_new, is_violation)

    def thresholds(self):
        if self.noise_n < 8:
            return None
        lo = max(self.p["t_floor"], self.p["k_lo"] * (self.noise_mean + 4 * self.noise_dev))
        hi = max(2 * lo, self.p["k_motion"] * self.motion if self.motion_n >= 4 else 0.0)
        return lo, hi

    def first(self, t):
        """First captured frame: there is no diff. It is NEW."""
        self.prev_t = t
        return True, self.state, ["first"]

    def push(self, t, d):
        """One captured frame: host time t (s), diff d vs the previous delivered frame. Returns (is_new, state, flags)."""
        p, c, flags = self.p, self.counters, []
        dt, self.prev_t = t - self.prev_t, t
        n = 1                                     # capture slots this frame advanced
        if dt > p["reset_gap"]:
            c["timeResets"] += 1; flags.append("timeReset")
            self._enter(UNKNOWN, flags)
        elif dt <= 0.5 * self.period:
            c["timestampAnomalies"] += 1
        else:
            n = max(1, round(dt / self.period))
            if n == 1:
                self.period += (dt - self.period) / 16
            else:
                c["droppedSlots"] += n - 1; flags.append("gap")
        self.slots += n
        expect_new = self.slots % 2 == 0          # 2:2: a new game frame every second slot

        th = self.thresholds()
        if d <= p["t_floor"]:
            band = "LOW"
        elif th is None:                           # bootstrap, no thresholds yet
            band = "LOW" if self.prev_d is not None and d * p["r_boot"] <= self.prev_d else "HIGH"
        else:
            band = "LOW" if d <= th[0] else "HIGH" if d >= th[1] else "MID"

        promoted = False
        if band == "HIGH":
            new = True                             # differs from the previous frame: new, no delay, in every state
        elif band == "LOW":
            new = False
            if self.state == LOCKED and self.prev_mid_dup and expect_new and n == 1:
                new = promoted = True              # previous frame was a new frame judged DUP: show its repeat now
                c["latePromotions"] += 1; flags.append("latePromotion")
        else:
            c["midBandFrames"] += 1
            new = expect_new if self.state == LOCKED else True
        self.prev_mid_dup = band == "MID" and not new

        if not new and band == "LOW" and n == 1:   # noise floor learns from clear duplicates only
            self.noise_n += 1
            a = 1 / min(self.noise_n, 32)
            self.noise_mean += (d - self.noise_mean) * a
            self.noise_dev += (abs(d - self.noise_mean) - self.noise_dev) * a
        if new and not promoted and n == 1:
            if band == "HIGH" and self.motion_n >= 4 and d >= max(p["cut_abs"], p["cut_k"] * self.motion):
                c["sceneCuts"] += 1; flags.append("sceneCut")   # not fed into motion
            else:
                self.motion_n += 1
                self.motion += (d - self.motion) / min(self.motion_n, 16)

        self.dup_run = 0 if new else self.dup_run + 1
        static = self.dup_run >= p["static_run"]
        if static:
            c["staticFrames"] += 1; flags.append("static")
        violation = n == 1 and new == self.last_new      # 2:2 means verdicts alternate
        if self.state == LOCKED and n == 1 and not static:
            if new and not expect_new and not promoted:
                c["phaseFlips"] += 1; flags.append("phaseFlip")
            elif not new and expect_new:
                c["repeatedFrames"] += 1
        self.alt_run = self.alt_run + 1 if n == 1 and not violation else 0
        self.win.append((new, violation and not static))
        if new:
            self.slots = 0
        self.last_new, self.prev_d = new, d

        if not static:                              # a static screen freezes the state
            recent = list(self.win)[-p["pass_window"]:]
            full = len(recent) == p["pass_window"]
            news = sum(1 for x in recent if x[0])
            few_new = full and news <= p["pass_window"] - p["pass_exit_dups"]
            if self.state == UNKNOWN:
                if self.alt_run >= p["lock_run"]: self._enter(LOCKED, flags)
                elif full and news >= p["pass_new"]: self._enter(PASS60, flags)
            elif self.state == LOCKED:
                if full and news >= p["pass_new"]: self._enter(PASS60, flags)
                elif few_new and sum(1 for x in self.win if x[1]) >= p["max_violations"]: self._enter(UNKNOWN, flags)
            elif few_new:
                self._enter(UNKNOWN, flags)             # LOCKED_2_2 is only ever entered from UNKNOWN
        return new, self.state, flags

    def _enter(self, state, flags):
        if state != self.state:
            flags.append(self.state + "->" + state)
            self.counters["stateChanges"] += 1
            self.state = state
        self.win.clear(); self.alt_run = 0


def offline_two_pass(d, contrast=0.25):
    """Ground truth for the agreement number. Pass 1: one global threshold (Otsu on log10(diff + 1e-3)).
    Pass 2: a frame is NEW only if it is above that threshold AND at least `contrast` x its larger neighbour."""
    x = sorted(math.log10(v + 1e-3) for v in d)
    pre = [0.0]
    for v in x: pre.append(pre[-1] + v)
    n, best, cut = len(x), -1.0, 0.0
    for k in range(1, n):
        var = k * (n - k) * (pre[k] / k - (pre[n] - pre[k]) / (n - k)) ** 2
        if var > best: best, cut = var, (x[k - 1] + x[k]) / 2
    t = 10 ** cut - 1e-3
    return t, [v > t and v >= contrast * max(d[i - 1] if i else 0.0, d[i + 1] if i + 1 < len(d) else 0.0)
               for i, v in enumerate(d)]


def run_trace(ts, d, **overrides):
    det = Detector(**overrides)
    det.first(ts[0] - det.period)
    return det, [det.push(t, v) for t, v in zip(ts, d)]


def run_files(paths):
    for path in paths:
        rows = [r for r in csv.DictReader(open(path)) if r["diff"] != ""]
        ts, d = [float(r["pts_s"]) for r in rows], [float(r["diff"]) for r in rows]
        det, res = run_trace(ts, d)
        t, truth = offline_two_pass(d)
        differ = [i for i, (r, l) in enumerate(zip(res, truth)) if r[0] != l]
        states = collections.Counter(r[1] for r in res)
        print(f"{path}: frames {len(d)}  agreement {100 * (1 - len(differ) / len(d)):.2f}% ({len(differ)} differ)  offline threshold {t:.3f}")
        print(f"  states {dict(states)}\n  counters {dict(det.counters)}\n  thresholds (lo, hi) {det.thresholds()}  motion {det.motion:.2f}")
        for i in differ[:10]:
            print(f"  differ frame {rows[i]['frame']}: online {'NEW' if res[i][0] else 'DUP'} {res[i][1]} {res[i][2]}  diffs",
                  " ".join(f"{v:.2f}" for v in d[max(0, i - 3):i + 4]))


def dump(path, out):
    rows = [r for r in csv.DictReader(open(path)) if r["diff"] != ""]
    ts, d = [float(r["pts_s"]) for r in rows], [float(r["diff"]) for r in rows]
    _, res = run_trace(ts, d)
    _, truth = offline_two_pass(d)
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["frame", "is_new", "state", "flags", "offline_is_new"])
        for r, (new, state, flags), t in zip(rows, res, truth):
            w.writerow([r["frame"], int(new), state, "|".join(flags), int(t)])
    print(f"wrote {len(rows)} rows to {out}")


# ---------- the six required cases ----------
P = PARAMS["period"]
NEW_D, DUP_D = 5.0, 0.05


def feed(pattern, start_t=0.0, det=None):
    """pattern: list of (slots, diff). Returns (det, results)."""
    det = det or Detector()
    t = start_t
    if det.prev_t is None: det.first(t)
    out = []
    for slots, d in pattern:
        t += slots * P
        out.append(det.push(t, d))
    return det, out


def selftest():
    lock = [(1, NEW_D), (1, DUP_D)] * 30           # 1 s of clean cadence: new, dup, new, dup ...

    # 1. clean 2:2
    det, r = feed(lock)
    assert [x[0] for x in r] == [True, False] * 30, "clean 2:2: verdicts"
    assert all(x[1] == UNKNOWN for x in r[:8]) and all(x[1] == LOCKED for x in r[8:]), "clean 2:2: locked at the 9th diff (150 ms)"
    assert det.counters["phaseFlips"] == 0 and det.counters["stateChanges"] == 1

    # 2a. one dropped frame that was the first copy of a game frame: the phase flips, the lock is kept
    det, _ = feed(lock)
    det, r = feed([(2, NEW_D), (1, NEW_D), (1, DUP_D)] + [(1, NEW_D), (1, DUP_D)] * 20, 60 * P, det)
    assert [x[0] for x in r[:3]] == [True, True, False], "drop: every delivered frame judged by content"
    assert "gap" in r[0][2] and "phaseFlip" in r[1][2]
    assert det.counters["droppedSlots"] == 1 and det.counters["phaseFlips"] == 1
    assert all(x[1] == LOCKED for x in r), "drop: lock is kept"
    # 2b. one dropped frame that was the second copy: no flip
    det, _ = feed(lock)
    det, r = feed([(1, NEW_D), (2, NEW_D), (1, DUP_D)] + [(1, NEW_D), (1, DUP_D)] * 20, 60 * P, det)
    assert [x[0] for x in r[:3]] == [True, True, False]
    assert det.counters["droppedSlots"] == 1 and det.counters["phaseFlips"] == 0 and all(x[1] == LOCKED for x in r)

    # 3. 60 fps menu, then back to 2:2
    det, _ = feed(lock)
    det, r = feed([(1, NEW_D)] * 60, 60 * P, det)
    assert all(x[0] for x in r), "60 fps: every frame new"
    first_pass = next(i for i, x in enumerate(r) if x[1] == PASS60)
    assert first_pass == 7, f"60 fps: PASSTHROUGH_60 at the 8th frame (133 ms), got {first_pass + 1}"
    assert all(x[1] == PASS60 for x in r[first_pass:])
    det, r = feed([(1, DUP_D), (1, NEW_D)] * 30, 120 * P, det)
    to_unknown = next(i for i, x in enumerate(r) if x[1] == UNKNOWN)
    relock = next(i for i, x in enumerate(r) if x[1] == LOCKED)
    assert (to_unknown, relock) == (6, 14), f"60 fps -> 2:2: UNKNOWN at the 7th frame, LOCKED_2_2 at the 15th (250 ms), got {to_unknown + 1}, {relock + 1}"

    # 4. static screen (all frames identical), then motion resumes
    det, _ = feed(lock)
    det, r = feed([(1, 0.0)] * 300, 60 * P, det)
    assert not any(x[0] for x in r) and all(x[1] == LOCKED for x in r), "static: all DUP, state frozen"
    assert det.counters["staticFrames"] == 297, det.counters["staticFrames"]
    det, r = feed([(1, NEW_D), (1, DUP_D)] * 10, 360 * P, det)
    assert [x[0] for x in r] == [True, False] * 10 and all(x[1] == LOCKED for x in r), "static: first moving frame is NEW at once"
    assert det.counters["phaseFlips"] <= 1 and det.counters["stateChanges"] == 1

    # 5. scene cut
    det, _ = feed(lock)
    motion_before, th_before = det.motion, det.thresholds()
    det, r = feed([(1, 60.0)], 60 * P, det)
    assert r[0][0] and "sceneCut" in r[0][2] and det.counters["sceneCuts"] == 1
    assert det.motion == motion_before and det.thresholds() == th_before, "cut: not fed into motion or thresholds"
    det, r = feed([(1, DUP_D), (1, NEW_D), (1, DUP_D)], 61 * P, det)
    assert [x[0] for x in r] == [False, True, False] and all(x[1] == LOCKED for x in r)

    # 6. 3:2-like irregular cadence (new, dup, dup, new, dup repeating)
    det, _ = feed(lock)
    det, r = feed([(1, NEW_D), (1, DUP_D), (1, DUP_D), (1, NEW_D), (1, DUP_D)] * 24, 60 * P, det)
    assert [x[0] for x in r] == [True, False, False, True, False] * 24, "3:2: verdicts follow content"
    left = next(i for i, x in enumerate(r) if x[1] != LOCKED)
    assert left == 27, f"3:2: leaves LOCKED_2_2 at the 28th frame, got {left + 1}"
    assert all(x[1] == UNKNOWN for x in r[left:]), "3:2: UNKNOWN, never PASSTHROUGH_60, no relock"
    print("selftest ok: 6 cases")


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "run": run_files(sys.argv[2:])
    elif len(sys.argv) == 4 and sys.argv[1] == "dump": dump(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 2 and sys.argv[1] == "selftest": selftest()
    else: print(__doc__)
