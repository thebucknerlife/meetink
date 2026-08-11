#!/usr/bin/env python3
"""Trim trailing silence from session spools, in place, before the
archive mix and refine run.

A forgotten recording keeps rolling long after everyone leaves; the tail
is dead air that costs hours of transcription and pads the playback m4a.
This truncates the spool FILES when the tail's silence is huge (default
10+ minutes), leaving a short grace so the meeting's real ending stays
audible. Both spool rates are cut to the same wall-clock point.

The trim length is min() across the streams that exist: a stream with
real audio at the end vetoes the cut (sys is all-zero for in-person
recordings, so mic alone decides there — and vice versa).

Prints the trimmed whole seconds to stdout; "0" means untouched.
Runs in the parakeet venv (numpy guaranteed).
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

RATE = 16000
ARCHIVE_RATE = 48000
# RMS floor for "silent" — half the capture gate's speech threshold;
# quiet-room mic noise sits below it, speech far above.
SILENCE_RMS = 0.01


def trailing_silence_s(path: str) -> float | None:
    """Seconds of continuous sub-threshold audio at the file's end,
    or None when the stream doesn't exist / is empty (no constraint)."""
    try:
        if os.path.getsize(path) < 2 * RATE:
            return None
    except OSError:
        return None
    data = np.fromfile(path, dtype=np.int16)
    nb = len(data) // RATE
    if nb < 2:
        return 0.0
    x = (data[: nb * RATE].astype(np.float32) / 32768.0).reshape(nb, RATE)
    rms = np.sqrt((x ** 2).mean(axis=1))
    t = 0
    for i in range(nb - 1, -1, -1):
        if rms[i] < SILENCE_RMS:
            t += 1
        else:
            break
    return float(t)


def truncate_tail(path: str, cut_s: float, rate: int) -> None:
    """Drop cut_s seconds off the end (sample-aligned s16le)."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    new = max(0, size - int(cut_s * rate) * 2)
    if new < size:
        os.truncate(path, new)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic", required=True)
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--min-seconds", type=int, default=600,
                    help="only trim when the silent tail exceeds this")
    ap.add_argument("--grace", type=int, default=30,
                    help="silence to LEAVE so the ending stays audible")
    args = ap.parse_args()

    trails = [t for t in (trailing_silence_s(args.mic),
                          trailing_silence_s(args.sys_)) if t is not None]
    if not trails:
        print(0)
        return 0
    trail = min(trails)
    if trail < args.min_seconds:
        print(0)
        return 0
    cut = trail - args.grace
    for p, rate in ((args.mic, RATE), (args.sys_, RATE),
                    (args.mic[:-4] + ".48k.raw", ARCHIVE_RATE),
                    (args.sys_[:-4] + ".48k.raw", ARCHIVE_RATE)):
        if os.path.isfile(p):
            truncate_tail(p, cut, rate)
    print(int(cut))
    return 0


if __name__ == "__main__":
    sys.exit(main())
