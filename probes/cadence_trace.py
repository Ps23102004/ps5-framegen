#!/usr/bin/env python3
"""Cadence probe: per-frame luma diff trace of a recording window, plus 2:2 cadence stats.

  python3 cadence_trace.py trace <video> <start s> <seconds> <out.csv>   # decode + write CSV (index,pts,diff)
  python3 cadence_trace.py stats <csv> [threshold] [-v]                  # analyse a CSV (-v lists every break)
  python3 cadence_trace.py selftest

Decode: ffmpeg -> 160x90 gray (area scale). Webcam overlay (measured on this recording:
x 86.8-100 %, y 76.9-98.7 %) is excluded: x >= 136, y >= 68 at 160x90.
diff = mean absolute luma difference to the previous frame over unmasked pixels (0..255 scale).
"""
import subprocess, sys, tempfile, re, csv

W, H, MX, MY = 160, 90, 136, 68
KEEP = [y * W + x for y in range(H) for x in range(W) if not (x >= MX and y >= MY)]


def trace(video, start, secs, out):
    with tempfile.TemporaryFile("w+") as err:
        p = subprocess.Popen(
            ["ffmpeg", "-nostdin", "-v", "info", "-threads", "4", "-ss", str(start), "-copyts", "-t", str(secs),
             "-i", video, "-an", "-vf", f"scale={W}:{H}:flags=area,format=gray,showinfo",
             "-f", "rawvideo", "-"], stdout=subprocess.PIPE, stderr=err)
        diffs, prev = [], None
        while True:
            buf = p.stdout.read(W * H)
            if len(buf) < W * H:
                break
            cur = bytes(buf[i] for i in KEEP)
            if prev is not None:
                diffs.append(sum(abs(a - b) for a, b in zip(cur, prev)) / len(cur))
            else:
                diffs.append(float("nan"))  # first frame has no predecessor
            prev = cur
        p.wait()
        err.seek(0)
        pts = [float(m.group(1)) for m in re.finditer(r"pts_time:\s*([0-9.]+)", err.read())]
    assert len(pts) == len(diffs), (len(pts), len(diffs))
    with open(out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["frame", "pts_s", "diff"])
        for i, (t, d) in enumerate(zip(pts, diffs)):
            w.writerow([i, f"{t:.6f}", "" if d != d else f"{d:.4f}"])
    print(f"wrote {len(diffs)} frames to {out}")


def load(path):
    rows = list(csv.DictReader(open(path)))
    return [(int(r["frame"]), float(r["pts_s"]), float(r["diff"])) for r in rows if r["diff"] != ""]


def pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int(p * len(s)))] if s else float("nan")


T_ABS, FLOOR, RATIO = 1.0, 0.04, 3.0


def classify(d, thr=None):
    """True = new game frame, False = duplicate.
    thr given: plain absolute threshold. Otherwise the hybrid rule: new if diff > T_ABS, or the diff is an
    isolated small peak (diff > FLOOR, > RATIO * previous diff, and next diff < diff / RATIO).
    The peak arm catches slow-motion new frames (0.1-0.5) and rejects both HEVC keyframe pops (a duplicate
    that lands on an I-frame reads 0.4-0.8) and the 0.07-0.2 blip on the third repeat of a 3:1 slip.
    ponytail: the peak arm looks one frame ahead, fine for offline traces; a live detector on uncompressed
    capture has no keyframe pops and should start from a plain threshold, tuned on real capture."""
    if thr is not None:
        return [x > thr for x in d]
    n = len(d)
    return [x > T_ABS or (x > FLOOR and i > 0 and x > RATIO * d[i - 1] and (i + 1 >= n or d[i + 1] < x / RATIO))
            for i, x in enumerate(d)]


def runs(cls):
    """[(index of new frame, frames until the next new frame)]; 2:2 cadence means every run is 2."""
    new = [i for i, c in enumerate(cls) if c]
    return [(a, b - a) for a, b in zip(new, new[1:])]


def breaks(cls):
    return [a for a, n in runs(cls) if n != 2]


def stats(path, thr=None):
    rows = load(path)
    d = [r[2] for r in rows]
    cls = classify(d, thr)
    dup = [x for x, c in zip(d, cls) if not c]
    new = [x for x, c in zip(d, cls) if c]
    rs = runs(cls)
    hist = {}
    for _, n in rs:
        hist[n] = hist.get(n, 0) + 1
    in22 = sum(n for _, n in rs if n == 2)
    print(f"{path}: {len(d)} diffs, rule {'abs>%g' % thr if thr is not None else 'hybrid'}")
    print(f"  dup n={len(dup)} p5/p50/p95/p99/max = {pct(dup,.05):.3f}/{pct(dup,.5):.3f}/{pct(dup,.95):.3f}/{pct(dup,.99):.3f}/{max(dup):.3f}")
    print(f"  new n={len(new)} min/p1/p5/p50/p95 = {min(new):.3f}/{pct(new,.01):.3f}/{pct(new,.05):.3f}/{pct(new,.5):.3f}/{pct(new,.95):.3f}")
    print(f"  frames inside 2-frame runs: {in22}/{sum(n for _, n in rs)} = {in22 / max(1, sum(n for _, n in rs)):.4f}")
    print(f"  run-length histogram (frames per unique picture): {dict(sorted(hist.items()))}")
    for a, n in rs:
        if n != 2 and "-v" in sys.argv:
            gap = d[a + 1:a + n]
            kind = "shown once" if n == 1 else ("static/frozen (diffs ~0)" if max(gap) < 0.005 else "repeat or slow fade")
            print(f"    frame {rows[a][0]} pts {rows[a][1]:.3f} run {n} {kind}: " + " ".join(f"{x:.2f}" for x in d[max(0, a - 2):a + min(n, 8) + 2]))
    return cls


def selftest():
    d = [0.02, 3.0] * 10
    for thr in (0.3, None):
        assert breaks(classify(d, thr)) == []
        assert breaks(classify(d[:8] + d[9:], thr)) == [7]            # duplicate dropped -> frame 7 shown once
        assert breaks(classify(d[:6] + [0.02] + d[6:], thr)) == [5]   # extra repeat -> frame 5 shown 3 times
    pop = [0.02, 5.0, 0.6, 5.0, 0.02, 5.0]                            # keyframe pop on a duplicate
    assert breaks(classify(pop)) == [] and breaks(classify(pop, 0.3)) != []
    slow = [0.01, 0.2, 0.01, 0.15, 0.02, 0.18]                        # slow motion, new frames below 0.3
    assert breaks(classify(slow)) == [] and sum(classify(slow, 0.3)) == 0
    slip = [0.02, 5.0, 0.02, 5.0, 0.02, 0.14, 5.0, 5.0, 0.02, 5.0]    # 3:1 slip with a blip on the third repeat
    assert [n for _, n in runs(classify(slip))] == [2, 3, 1, 2]
    print("selftest ok")


if __name__ == "__main__":
    a = sys.argv
    if len(a) > 1 and a[1] == "trace":
        trace(a[2], float(a[3]), float(a[4]), a[5])
    elif len(a) > 1 and a[1] == "stats":
        stats(a[2], float(a[3]) if len(a) > 3 and a[3] != "-v" else None)
    elif len(a) > 1 and a[1] == "selftest":
        selftest()
    else:
        print(__doc__)
