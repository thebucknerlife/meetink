#!/usr/bin/env python3
"""Headphone-meeting playback mix: raw mic + sys, one targeted gate.

With headphones the two streams are ALREADY the clean separation the
whole mixing saga chased: the mic carries only the user (no speaker
bleed), sys carries only the remote side. The ideal mix is nearly a
plain sum — the field test that proved it was an AirPods recording run
through the heavy neural path, which manufactured every artifact it
was supposed to prevent (mask-transfer "glass jar" on a clean voice,
reply-span duck pumping, clipping).

The single real-call phenomenon to handle is the user's REMOTE ECHO
coming back through sys (the far side's imperfect echo cancellation).
The residual echo gate handles exactly that — it ducks only sys blocks
that match the delay-shifted mic envelope at echo-plausible levels —
and it is finally trustworthy here because (a) the headphone mic is
bleed-free, so the envelope is genuinely the user (its catastrophic
failure mode was a bleed-carrying mic reading the whole remote side as
"echo"), and (b) the spools are wall-clock aligned. When no echo path
exists (gcc finds nothing), sys passes through bit-true and the mix is
a plain sum.

No transcript, no labels, no models. Runs in the parakeet venv.
"""
from __future__ import annotations

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from enhance import gcc_phat_delay, residual_echo_gate

RATE = 16000


def log(msg: str) -> None:
    print(f"headphone-mix: {msg}", file=sys.stderr, flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic16", required=True)
    ap.add_argument("--sys16", required=True)
    ap.add_argument("--mic", required=True, help="playback-rate mic stream")
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    mic16 = np.fromfile(args.mic16, dtype=np.int16).astype(np.float32) / 32768.0
    sys16 = np.fromfile(args.sys16, dtype=np.int16).astype(np.float32) / 32768.0
    if not len(mic16) or not len(sys16):
        log("a stream is empty — falling back")
        return 1

    # The user's remote echo in sys, if any. Two sanity guards against
    # spurious correlation (field case: a no-echo AirPods test "found"
    # a 1473 ms path and ducked 42% of the playback — the pumping,
    # again): real remote-echo paths sit under ~600 ms, and real echo
    # is SPARSE. Anything else collapses to a plain sum.
    gains = None
    delay = gcc_phat_delay(mic16, sys16, max_delay_s=0.6)
    if delay >= 0:
        _, gains = residual_echo_gate(mic16, sys16, delay)
        if gains is not None:
            ducked = float((gains < 0.9).mean())
            if ducked > 0.20:
                log(f"gate misfire (delay {delay / 16.0:.0f} ms would duck "
                    f"{ducked * 100:.0f}% of sys) — plain sum instead")
                gains = None
            else:
                log(f"echo gate armed (delay {delay / 16.0:.0f} ms, "
                    f"ducking {ducked * 100:.0f}% of sys blocks)")
    if gains is None:
        log("no (plausible) echo path — plain sum, both streams bit-true")

    B_hi = args.rate // 20   # the gate's 50 ms blocks at playback rate
    n = max(os.path.getsize(args.mic) // 2, os.path.getsize(args.sys_) // 2)
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
            if gains is not None:
                idx = np.minimum((np.arange(take) + pos) // B_hi,
                                 len(gains) - 1)
                s *= gains[idx]
            mixed = m + s
            # Soft headroom instead of a hard clip — summed peaks land
            # in the knee instead of squaring off ("clipping" artifacts).
            over = np.abs(mixed) > 0.85
            mixed[over] = np.sign(mixed[over]) * (
                0.85 + 0.13 * np.tanh((np.abs(mixed[over]) - 0.85) / 0.13))
            fo.write((mixed * 32767.0).astype(np.int16).tobytes())
            pos += take
    log("headphone mix complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
