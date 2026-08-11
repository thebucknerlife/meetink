#!/usr/bin/env python3
"""Transcript-driven playback mix — the Krisp-grade path.

The blind sidechain duck layered the mic's residual speaker bleed (room
reverb and AEC suppressor chop) under the clean sys copy of every remote
utterance (field report: "echoy, jumpier"). But we know EXACTLY when the
user speaks — the refine pass wrote word-level timings. So:

  sys: passes through untouched OUTSIDE the user's spans — there it is
       literally the audio the user heard during the call. INSIDE their
       spans it ducks (--sys-duck): the user's remote echo comes back
       through sys, and playing it undamped under their mic voice
       doubled them ("substantially more echo from me").
  mic: opens only inside the user's own word spans (padded, merged,
       raised-cosine fades), plus an energy fallback that opens it when
       the mic clearly carries exclusive speech the transcript didn't
       attribute to the user (in-person participants, mislabeled lines).

Streams are s16le mono at --rate; output is the mixed s16le raw on
--out. Chunked processing — a 2 h 48 kHz meeting never fully loads.
Runs in the parakeet venv (numpy).
"""
from __future__ import annotations

import argparse
import json
import sys

import numpy as np


def log(msg: str) -> None:
    print(f"mix: {msg}", file=sys.stderr, flush=True)


def user_spans(timing_path: str, me: str) -> list[tuple[float, float]]:
    """Merged [start, end] spans of the user's words, padded."""
    with open(timing_path) as f:
        lines = json.load(f).get("lines", [])
    pts: list[tuple[float, float]] = []
    for line in lines:
        if (line.get("label") or "").upper() != me.upper():
            continue
        for w in line.get("words", []):
            s = float(w.get("s", 0))
            e = max(float(w.get("e", s)), s + 0.30)   # e is often == s
            pts.append((s - 0.30, e + 0.45))
    pts.sort()
    merged: list[tuple[float, float]] = []
    for s, e in pts:
        # ≤1.5 s gaps merge — Parakeet's word stamps are coarse and tight
        # gating chopped real speech into robotic fragments (field
        # report); longer pauses (a line can span a remote monologue)
        # still close the mic.
        if merged and s - merged[-1][1] <= 1.5:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return merged


def env_for_chunk(spans: list[tuple[float, float]], pos: int, take: int,
                  rate: int, fade_s: float = 0.20) -> np.ndarray:
    """Gain curve for samples [pos, pos+take): 1 inside spans, 0 outside,
    cosine ramps of fade_s OUTSIDE each span edge (the fade adds ramp
    rather than eating the first/last word). Analytic per chunk — a full
    2 h envelope at 48 kHz would be 1.4 GB."""
    env = np.zeros(take, dtype=np.float32)
    t0 = pos / rate
    t1 = (pos + take) / rate
    t = t0 + np.arange(take, dtype=np.float64) / rate
    for s, e in spans:
        if e + fade_s <= t0 or s - fade_s >= t1:
            continue
        g = np.zeros(take, dtype=np.float32)
        core = (t >= s) & (t <= e)
        g[core] = 1.0
        rise = (t >= s - fade_s) & (t < s)
        g[rise] = (0.5 - 0.5 * np.cos(np.pi * (t[rise] - (s - fade_s)) / fade_s)).astype(np.float32)
        fall = (t > e) & (t <= e + fade_s)
        g[fall] = (0.5 + 0.5 * np.cos(np.pi * (t[fall] - e) / fade_s)).astype(np.float32)
        np.maximum(env, g, out=env)
    return env


def rms_blocks(path: str, rate: int, block_s: float = 0.1) -> np.ndarray:
    B = int(rate * block_s)
    data = np.fromfile(path, dtype=np.int16)
    nb = len(data) // B
    if nb == 0:
        return np.zeros(0, dtype=np.float32)
    x = (data[: nb * B].astype(np.float32) / 32768.0).reshape(nb, B)
    return np.sqrt((x ** 2).mean(axis=1))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic", required=True)
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--timing", required=True)
    ap.add_argument("--me", default="ME")
    ap.add_argument("--sys-duck", type=float, default=0.15,
                    help="sys gain INSIDE the user's spans — their remote "
                         "echo lives there (0.15 ≈ -16 dB; 1.0 disables)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    spans = user_spans(args.timing, args.me)
    if not spans:
        # Nothing attributed to the user — bail so the caller falls back
        # to the duck mix rather than muting the mic outright.
        log("no user spans in timing — falling back")
        return 1

    # Energy fallback: 100 ms blocks where the mic clearly carries
    # speech the sys stream doesn't (in-person voices, mislabeled
    # lines). Bleed never qualifies — it co-occurs with active sys.
    mic_rms = rms_blocks(args.mic, args.rate)
    sys_rms = rms_blocks(args.sys_, args.rate)
    n_blocks = min(len(mic_rms), len(sys_rms))
    extra: list[tuple[float, float]] = []
    run_start = None
    for i in range(n_blocks):
        exclusive = mic_rms[i] > 0.015 and mic_rms[i] > 4 * sys_rms[i]
        if exclusive and run_start is None:
            run_start = i
        elif not exclusive and run_start is not None:
            # ≥0.4 s of mic-exclusive speech opens the mic there too.
            if i - run_start >= 4:
                extra.append((run_start * 0.1 - 0.15, i * 0.1 + 0.15))
            run_start = None
    if run_start is not None and n_blocks - run_start >= 4:
        extra.append((run_start * 0.1 - 0.15, n_blocks * 0.1 + 0.15))
    if extra:
        log(f"energy fallback opened {sum(e - s for s, e in extra):.0f}s "
            f"of mic-exclusive audio")

    import os
    n_mic = os.path.getsize(args.mic) // 2
    n_sys = os.path.getsize(args.sys_) // 2
    n = max(n_mic, n_sys)
    all_spans = sorted(spans + extra)

    CHUNK = args.rate * 10
    with open(args.mic, "rb") as fm, open(args.sys_, "rb") as fs, \
         open(args.out, "wb") as fo:
        pos = 0
        while pos < n:
            take = min(CHUNK, n - pos)
            mic = np.frombuffer(fm.read(take * 2), dtype=np.int16)
            sy = np.frombuffer(fs.read(take * 2), dtype=np.int16)
            m = np.zeros(take, dtype=np.float32)
            s = np.zeros(take, dtype=np.float32)
            m[: len(mic)] = mic.astype(np.float32) / 32768.0
            s[: len(sy)] = sy.astype(np.float32) / 32768.0
            env = env_for_chunk(all_spans, pos, take, args.rate)
            # Outside the user's spans sys is UNTOUCHED (that's the
            # whole point); inside them it ducks — the user's remote
            # echo comes back through sys and played undamped under
            # their mic voice ("substantially more echo from me").
            sys_gain = 1.0 - (1.0 - args.sys_duck) * env
            mixed = s * sys_gain + m * env
            # Soft headroom: simultaneous speech can sum past full scale.
            np.clip(mixed, -0.98, 0.98, out=mixed)
            fo.write((mixed * 32767.0).astype(np.int16).tobytes())
            pos += take
    log(f"transcript mix: {len(spans)} user spans, sys passthrough")
    return 0


if __name__ == "__main__":
    sys.exit(main())
