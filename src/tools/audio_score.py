#!/usr/bin/env python3
"""Standalone perceptual audio-quality scorer — an assessment TOOL, not
a pipeline stage. Nothing in capture/refine/mix imports this; it exists
so a human (or a test) can ask "how does this recording actually sound?"
and get numbers where ears were previously required.

Models (all local, ONNX via the speechmos package):
  DNSMOS P.835 — SIG (speech quality: mangled/robotic voices depress
                 it), BAK (background noise), OVRL (overall), each an
                 estimated human MOS on 1-5.
  PLCMOS      — packet-loss-concealment artifacts ("robotic" codec
                 glitches from network jitter).

Honest limits: absolute numbers are noisy for out-of-distribution
degradations (far-end echo inside a meeting mix was not in anyone's
training set — echo depresses OVRL/SIG but has no dedicated axis).
DELTAS between two renders of the SAME content are far more reliable
than absolutes — use --compare for A/B verdicts.

Usage:
  audio_score.py MEETING.m4a [--window 15] [--json out.json]
  audio_score.py A.m4a --compare B.m4a     # the reliable mode
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

RATE = 16000


def die(msg: str) -> None:
    print(f"audio-score: error: {msg}", file=sys.stderr)
    sys.exit(1)


def decode(path: str) -> np.ndarray:
    """Any ffmpeg-decodable input → 16 kHz mono float32 in [-1, 1]."""
    if not os.path.isfile(path):
        die(f"no such file: {path}")
    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as tf:
        tmp = tf.name
    try:
        proc = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", path,
             "-ar", str(RATE), "-ac", "1", "-f", "s16le", tmp],
            capture_output=True, text=True)
        if proc.returncode != 0:
            die(f"ffmpeg failed on {path}: {proc.stderr.strip()}")
        pcm = np.fromfile(tmp, dtype=np.int16)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if not len(pcm):
        die(f"decoded no audio from {path}")
    return pcm.astype(np.float32) / 32768.0


def mmss(t: float) -> str:
    s = int(t)
    return f"{s // 60}:{s % 60:02d}"


def score_windows(audio: np.ndarray, window_s: int) -> list[dict]:
    """Per-window DNSMOS + PLCMOS. Near-silent windows are skipped —
    scoring silence produces garbage MOS that poisons aggregates."""
    from speechmos import dnsmos, plcmos
    win = window_s * RATE
    out: list[dict] = []
    for start in range(0, len(audio), win):
        seg = audio[start:start + win]
        if len(seg) < RATE * 3:
            continue
        rms = float(np.sqrt(np.mean(seg ** 2)))
        row = {"t": start / RATE, "rms": round(rms, 4)}
        if rms < 0.004:
            row["silent"] = True
            out.append(row)
            continue
        d = dnsmos.run(seg.astype(np.float64), sr=RATE)
        row["ovrl"] = round(float(d["ovrl_mos"]), 2)
        row["sig"] = round(float(d["sig_mos"]), 2)
        row["bak"] = round(float(d["bak_mos"]), 2)
        try:
            p = plcmos.run(seg.astype(np.float64), sr=RATE)
            row["plc"] = round(float(p["plcmos"]), 2)
        except Exception:
            pass          # plcmos is best-effort; dnsmos is the core
        out.append(row)
    return out


def aggregate(rows: list[dict]) -> dict:
    scored = [r for r in rows if "ovrl" in r]
    if not scored:
        return {"scored_windows": 0}
    def stats(key: str) -> dict:
        v = sorted(r[key] for r in scored if key in r)
        if not v:
            return {}
        return {"mean": round(sum(v) / len(v), 2),
                "p10": round(v[max(0, len(v) // 10 - 1)], 2),
                "min": v[0]}
    return {
        "scored_windows": len(scored),
        "silent_windows": sum(1 for r in rows if r.get("silent")),
        "ovrl": stats("ovrl"), "sig": stats("sig"),
        "bak": stats("bak"), "plc": stats("plc"),
    }


def worst(rows: list[dict], key: str = "ovrl", n: int = 5) -> list[dict]:
    scored = [r for r in rows if key in r]
    return sorted(scored, key=lambda r: r[key])[:n]


def print_report(path: str, rows: list[dict], agg: dict) -> None:
    print(f"\n{os.path.basename(path)}")
    if not agg.get("scored_windows"):
        print("  (nothing scoreable)")
        return
    print(f"  windows scored: {agg['scored_windows']} "
          f"(+{agg.get('silent_windows', 0)} silent)")
    for key, label in [("ovrl", "OVRL overall"), ("sig", "SIG  speech"),
                       ("bak", "BAK  background"), ("plc", "PLC  jitter")]:
        s = agg.get(key) or {}
        if s:
            print(f"  {label:16s} mean {s['mean']:.2f}   "
                  f"worst-decile {s['p10']:.2f}   min {s['min']:.2f}")
    print("  worst windows (OVRL):")
    for r in worst(rows):
        extra = f"  sig {r.get('sig', '-')}  plc {r.get('plc', '-')}"
        print(f"    {mmss(r['t']):>7s}  ovrl {r['ovrl']:.2f}{extra}")


def print_compare(pa: str, ra: list[dict], pb: str, rb: list[dict]) -> None:
    """Windows aligned by time; the delta is the trustworthy signal."""
    bmap = {r["t"]: r for r in rb}
    deltas = []
    for r in ra:
        o = bmap.get(r["t"])
        if o and "ovrl" in r and "ovrl" in o:
            deltas.append((r["t"], o["ovrl"] - r["ovrl"], r["ovrl"], o["ovrl"]))
    if not deltas:
        print("no comparable windows")
        return
    d = [x[1] for x in deltas]
    print(f"\nA = {os.path.basename(pa)}")
    print(f"B = {os.path.basename(pb)}")
    print(f"OVRL delta (B - A): mean {sum(d)/len(d):+.2f} over "
          f"{len(deltas)} windows  "
          f"(B better in {sum(1 for x in d if x > 0.05)}, "
          f"worse in {sum(1 for x in d if x < -0.05)}, "
          f"± even in {sum(1 for x in d if abs(x) <= 0.05)})")
    print("largest disagreements:")
    for t, dd, a, b in sorted(deltas, key=lambda x: -abs(x[1]))[:6]:
        print(f"    {mmss(t):>7s}  A {a:.2f} → B {b:.2f}  ({dd:+.2f})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("audio")
    ap.add_argument("--compare", help="second render of the same content")
    ap.add_argument("--window", type=int, default=15)
    ap.add_argument("--json", dest="json_out")
    args = ap.parse_args()

    a = decode(args.audio)
    rows_a = score_windows(a, args.window)
    agg_a = aggregate(rows_a)
    print_report(args.audio, rows_a, agg_a)

    result = {"file": args.audio, "aggregate": agg_a, "windows": rows_a}
    if args.compare:
        b = decode(args.compare)
        rows_b = score_windows(b, args.window)
        agg_b = aggregate(rows_b)
        print_report(args.compare, rows_b, agg_b)
        print_compare(args.audio, rows_a, args.compare, rows_b)
        result = {"a": result,
                  "b": {"file": args.compare, "aggregate": agg_b,
                        "windows": rows_b}}
    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(result, f, indent=2)
        print(f"\njson → {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
