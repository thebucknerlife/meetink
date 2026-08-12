#!/usr/bin/env python3
"""Realign the sys spool onto the mic spool's timeline.

The two spools are written by independent pipelines on independent
clocks (AirPods mic vs ScreenCaptureKit), and their relative delay was
measured WANDERING between 40 ms and 1,433 ms across one real meeting —
which quietly broke every reference-based echo tool we ran offline
(AEC3, FDAF, DTLN-aec all assume a near-static delay of a few hundred
ms). This module estimates the delay trajectory from the echo path
itself (windowed GCC-PHAT of sys inside mic), fills the no-correlation
gaps by interpolation, and rebuilds sys as a piecewise-shifted stream
whose echo sits at one constant target delay the models can handle.

Segment shifts are piecewise-constant with short crossfades at the
seams: the aligned stream is a cancellation REFERENCE, where alignment
matters and seam artifacts don't.
"""
from __future__ import annotations

import sys
import os

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from enhance import gcc_phat_delay

RATE = 16000


def measure_delay_curve(mic: np.ndarray, sys_: np.ndarray,
                        win_s: int = 30, hop_s: int = 15,
                        log=None) -> list[tuple[float, float]]:
    """(window_center_s, delay_s) points where the echo path is
    measurable; callers interpolate across the gaps."""
    n = min(len(mic), len(sys_))
    pts: list[tuple[float, float]] = []
    for w0 in range(0, max(1, n - win_s * RATE), hop_s * RATE):
        seg_s = sys_[w0:w0 + win_s * RATE]
        seg_m = mic[w0:w0 + win_s * RATE]
        d = gcc_phat_delay(seg_s, seg_m, max_delay_s=2.0)
        if d >= 0:
            pts.append((w0 / RATE + win_s / 2, d / RATE))
    # Median-of-3 to knock out single bad estimates without flattening
    # the real step changes that spool gaps produce.
    if len(pts) >= 3:
        vals = [p[1] for p in pts]
        med = [vals[0]] + [sorted(vals[i - 1:i + 2])[1]
                           for i in range(1, len(vals) - 1)] + [vals[-1]]
        pts = [(t, v) for (t, _), v in zip(pts, med)]
    if log:
        log(f"delay curve: {len(pts)} anchor points, "
            f"range {min(p[1] for p in pts)*1000:.0f}-"
            f"{max(p[1] for p in pts)*1000:.0f} ms" if pts else
            "delay curve: no echo path found")
    return pts


def align_sys(mic: np.ndarray, sys_: np.ndarray,
              target_delay_s: float = 0.10,
              seg_s: int = 10, log=None) -> np.ndarray:
    """sys rebuilt so its echo inside mic sits at target_delay_s."""
    n = len(mic)
    pts = measure_delay_curve(mic, sys_, log=log)
    if not pts:
        return sys_[:n] if len(sys_) >= n else np.pad(sys_, (0, n - len(sys_)))
    times = np.array([p[0] for p in pts])
    delays = np.array([p[1] for p in pts])

    out = np.zeros(n, dtype=np.float32)
    fade = int(0.05 * RATE)
    prev_tail: np.ndarray | None = None
    for o in range(0, n, seg_s * RATE):
        take = min(seg_s * RATE, n - o)
        t_mid = (o + take / 2) / RATE
        d = float(np.interp(t_mid, times, delays))
        # mic(t) echoes sys(t - d); shifting sys forward by (d - target)
        # puts the echo at the constant target delay.
        shift = int(round((d - target_delay_s) * RATE))
        a = o + shift
        seg = np.zeros(take, dtype=np.float32)
        lo, hi = max(0, a), min(len(sys_), a + take)
        if lo < hi:
            seg[lo - a:lo - a + (hi - lo)] = sys_[lo:hi]
        if prev_tail is not None and fade < take:
            # Crossfade the seam — reference use, but no hard clicks.
            ramp = np.linspace(0, 1, fade, dtype=np.float32)
            seg[:fade] = seg[:fade] * ramp + prev_tail * (1 - ramp)
        out[o:o + take] = seg
        prev_tail = seg[-fade:].copy() if take > fade else None
        if prev_tail is not None and o + take < n:
            nxt_take = min(seg_s * RATE, n - (o + take))
            if nxt_take <= fade:
                prev_tail = None
    return out


def align_hi(sys_hi: np.ndarray, mic16: np.ndarray, sys16: np.ndarray,
             rate_hi: int, target_delay_s: float = 0.10,
             seg_s: int = 10) -> np.ndarray:
    """Apply the SAME 16 kHz-measured shifts to the high-rate sys."""
    pts = measure_delay_curve(mic16, sys16)
    n_hi = len(sys_hi)
    if not pts:
        return sys_hi
    times = np.array([p[0] for p in pts])
    delays = np.array([p[1] for p in pts])
    out = np.zeros(n_hi, dtype=np.float32)
    fade = int(0.05 * rate_hi)
    for o in range(0, n_hi, seg_s * rate_hi):
        take = min(seg_s * rate_hi, n_hi - o)
        t_mid = (o + take / 2) / rate_hi
        d = float(np.interp(t_mid, times, delays))
        a = o + int(round((d - target_delay_s) * rate_hi))
        seg = np.zeros(take, dtype=np.float32)
        lo, hi = max(0, a), min(n_hi, a + take)
        if lo < hi:
            seg[lo - a:lo - a + (hi - lo)] = sys_hi[lo:hi]
        if o > 0 and fade < take:
            ramp = np.linspace(0, 1, fade, dtype=np.float32)
            seg[:fade] *= ramp
            out[o:o + fade] *= (1 - ramp)
            out[o:o + fade] += seg[:fade]
            out[o + fade:o + take] = seg[fade:]
            continue
        out[o:o + take] = seg
    return out
