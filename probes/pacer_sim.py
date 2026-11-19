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
