#!/usr/bin/env python3
"""Unified playback renderer: per-window mode detection + crossfade.

The two field-validated recipes, now selected PER WINDOW instead of per
meeting (the user takes headphones on and off mid-call):

  speakers window   → mic-only (one copy of every voice; echo
                      structurally impossible — the A/B-winning mix)
  headphones window → level-matched plain sum of both raw streams,
                      with the twice-guarded residual echo gate

Mode evidence: the mic tracks sys at a substantial fraction when
speakers play (measured 0.57-1.03) and barely at all with headphones
(0.004). Windows without enough sys activity inherit their neighbor
(hysteresis: two consecutive windows must disagree to switch). A
uniform meeting renders identically to the old single-mode paths.

Both renders share one set of static per-stream gains so crossfades
(0.4 s equal-power) never step in loudness. Soft tanh headroom instead
of a hard clip. No transcript, no labels, no models — numpy only.
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from enhance import gcc_phat_delay, residual_echo_gate

RATE = 16000
WIN_S = 15           # mode-detection window
RATIO_THRESHOLD = 0.15


def log(msg: str) -> None:
    print(f"playback-mix: {msg}", file=sys.stderr, flush=True)


def detect_modes(mic16: np.ndarray, sys16: np.ndarray) -> list[bool]:
    """Per-window: True = speakers (mic-only), False = headphones (sum)."""
    B = RATE // 10
    n = min(len(mic16), len(sys16))
    nb = n // B
    m = np.sqrt((mic16[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    s = np.sqrt((sys16[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    act = s[s > 0.001]
    floor = max(0.01, float(np.percentile(act, 75)) * 0.5) if len(act) > 50 else 0.05

    per_win: list[bool | None] = []
    wb = WIN_S * 10  # blocks per window
    for w0 in range(0, nb, wb):
        sl = slice(w0, min(nb, w0 + wb))
        loud = s[sl] > floor
        if loud.sum() < 10:
            per_win.append(None)   # not enough evidence — inherit
            continue
        ratio = float(np.median(m[sl][loud] / s[sl][loud]))
        per_win.append(ratio > RATIO_THRESHOLD)

    # Fill evidence-less windows from the nearest decided neighbor
    # (forward first, then backward for a silent head).
    last: bool | None = None
    for i, v in enumerate(per_win):
        if v is None:
            per_win[i] = last
        else:
            last = v
    last = None
    for i in range(len(per_win) - 1, -1, -1):
        if per_win[i] is None:
            per_win[i] = last if last is not None else False
        else:
            last = per_win[i]

    # Hysteresis: a single dissenting window between agreeing neighbors
    # is measurement noise, not a device change.
    modes = [bool(v) for v in per_win]
    for i in range(1, len(modes) - 1):
        if modes[i] != modes[i - 1] and modes[i] != modes[i + 1]:
            modes[i] = modes[i - 1]
    return modes


def stream_gain(x: np.ndarray, target: float = 0.07) -> float:
    B = RATE // 10
    nb = len(x) // B
    if nb < 20:
        return 1.0
    r = np.sqrt((x[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    act = r[r > 0.01]
    if len(act) < 10:
        return 1.0
    return float(np.clip(target / max(float(np.percentile(act, 75)), 1e-4),
                         0.25, 4.0))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic16", required=True)
    ap.add_argument("--sys16", required=True)
    ap.add_argument("--mic", required=True, help="playback-rate mic stream")
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--force-mode", choices=["mic", "split"],
                    help="override detection (mix_mode config)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    def load16(path: str) -> np.ndarray:
        try:
            return np.fromfile(path, dtype=np.int16).astype(np.float32) / 32768.0
        except OSError:
            return np.zeros(0, dtype=np.float32)

    mic16 = load16(args.mic16)
    sys16 = load16(args.sys16)
    if not len(mic16):
        log("mic stream empty — falling back")
        return 1
    if not len(sys16):
        # In-person recording: no system audio at all → pure mic-only.
        sys16 = np.zeros(len(mic16), dtype=np.float32)

    if args.force_mode:
        modes = [args.force_mode == "mic"]
        log(f"mode forced: {'speakers/mic-only' if modes[0] else 'headphones/sum'}")
    else:
        modes = detect_modes(mic16, sys16)
        switches = sum(1 for i in range(1, len(modes)) if modes[i] != modes[i - 1])
        log(f"modes: {sum(modes)}/{len(modes)} windows speakers, "
            f"{switches} device switch(es)")

    # Echo gate for the SUM segments only (twice-guarded, as shipped).
    gains = None
    if not all(modes):
        delay = gcc_phat_delay(mic16, sys16, max_delay_s=0.6)
        if delay >= 0:
            _, gains = residual_echo_gate(mic16, sys16, delay)
            if gains is not None:
                ducked = float((gains < 0.9).mean())
                if ducked > 0.20:
                    log(f"gate misfire (would duck {ducked*100:.0f}%) — no gate")
                    gains = None
                else:
                    log(f"echo gate armed (delay {delay/16.0:.0f} ms)")

    mic_gain = stream_gain(mic16)
    sys_gain = stream_gain(sys16)
    log(f"level match: mic x{mic_gain:.2f}, sys x{sys_gain:.2f}")

    # Sample-level speakers-mode weight from the window modes, with
    # 0.4 s equal-power crossfades at every transition.
    def fsize(path: str) -> int:
        try:
            return os.path.getsize(path)
        except OSError:
            return 0

    n = max(fsize(args.mic) // 2, fsize(args.sys_) // 2)
    win_hi = WIN_S * args.rate
    fade_hi = int(0.4 * args.rate)

    def alpha_for_chunk(pos: int, take: int) -> np.ndarray:
        idx = np.minimum((np.arange(take) + pos) // win_hi, len(modes) - 1)
        a = np.array([1.0 if modes[i] else 0.0 for i in range(len(modes))],
                     dtype=np.float32)[idx]
        # Smooth transitions: linear ramp over fade_hi around each
        # window boundary where the mode flips.
        for w in range(1, len(modes)):
            if modes[w] == modes[w - 1]:
                continue
            b_pos = w * win_hi          # global sample of the flip
            lo, hi = b_pos - fade_hi // 2, b_pos + fade_hi // 2
            s0, s1 = max(lo, pos), min(hi, pos + take)
            if s0 < s1:
                t = (np.arange(s0, s1) - lo) / max(1, hi - lo)
                ramp = (1 - np.cos(np.pi * t)) / 2
                seg = ramp if modes[w] else 1 - ramp
                a[s0 - pos:s1 - pos] = seg.astype(np.float32)
        return a

    B_hi = args.rate // 20
    CHUNK = args.rate * 10
    sys_src = args.sys_ if fsize(args.sys_) else os.devnull
    with open(args.mic, "rb") as fm, open(sys_src, "rb") as fs, \
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
            if gains is not None:
                gidx = np.minimum((np.arange(take) + pos) // B_hi,
                                  len(gains) - 1)
                s = s * gains[gidx]
            alpha = alpha_for_chunk(pos, take)   # 1 = mic-only, 0 = sum
            mic_track = m * mic_gain             # shared by both renders
            sum_track = mic_track + s * sys_gain
            mixed = alpha * mic_track + (1.0 - alpha) * sum_track
            over = np.abs(mixed) > 0.85
            mixed[over] = np.sign(mixed[over]) * (
                0.85 + 0.13 * np.tanh((np.abs(mixed[over]) - 0.85) / 0.13))
            fo.write((mixed * 32767.0).astype(np.int16).tobytes())
            pos += take
    log("playback mix complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
