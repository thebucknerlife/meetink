#!/usr/bin/env python3
"""Offline audio enhancement for kept meeting recordings.

Two stages, run at archive time (cmd_stop) and by `meetink reprocess`:

1. Cross echo cancellation (always, needs only numpy). Each spool is the
   other's echo *reference*: the sys stream carries a delayed copy of the
   user's mic (a remote participant's echoey client sending their voice
   back), and the mic carries speaker/headphone bleed of the sys stream.
   A ducked mix can only hide these while the other side is quiet; an
   adaptive filter actually *subtracts* them. This is the same
   reference-based AEC idea tools like Krisp run live in the call path —
   we run it offline on the spools, where latency doesn't matter.

   Per direction: bulk delay via GCC-PHAT cross-correlation, then a
   partitioned frequency-domain NLMS (overlap-save) with adaptation
   freezing during near-end-dominant frames (double-talk protection).

2. DeepFilterNet denoise/de-reverb (optional). If the enhance venv is
   installed (`meetink enhance install`), each cleaned stream also goes
   through DeepFilterNet3 — this is what fixes the "tinny" compressed
   quality of remote voices. Skipped silently when not installed.

Usage:
  enhance.py --mic mic.raw --sys sys.raw --out-mic clean-mic.raw --out-sys clean-sys.raw
Raw streams are s16le / 16 kHz / mono, same as the spools.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

RATE = 16000
ENHANCE_VENV = os.environ.get(
    "MEETINK_ENHANCE_VENV",
    os.path.expanduser("~/.meetink/enhance-venv"))


def log(msg: str) -> None:
    print(f"enhance: {msg}", file=sys.stderr, flush=True)


def load_raw(path: str) -> np.ndarray:
    data = np.fromfile(path, dtype=np.int16)
    return data.astype(np.float32) / 32768.0


def save_raw(x: np.ndarray, path: str) -> None:
    np.clip(x, -1.0, 1.0, out=x)
    (x * 32767.0).astype(np.int16).tofile(path)


# --- Stage 1: cross echo cancellation ---

def gcc_phat_delay(ref: np.ndarray, sig: np.ndarray, max_delay_s: float = 1.5) -> int:
    """Bulk delay (samples) of ref's echo inside sig, via GCC-PHAT.

    Uses up to the first ~120 s — enough for a stable peak, cheap on long
    meetings. Positive result means sig lags ref (the normal case: the
    echo arrives after the original)."""
    n = min(len(ref), len(sig), 120 * RATE)
    if n < RATE:
        return 0
    a, b = ref[:n], sig[:n]
    nfft = 1 << int(np.ceil(np.log2(2 * n - 1)))
    A = np.fft.rfft(a, nfft)
    B = np.fft.rfft(b, nfft)
    R = B * np.conj(A)
    R /= np.abs(R) + 1e-9
    cc = np.fft.irfft(R, nfft)
    max_d = int(max_delay_s * RATE)
    # Only search causal delays: the echo can't precede its source.
    window = cc[:max_d]
    peak = int(np.argmax(np.abs(window)))
    # Reject a mushy correlation floor — no echo path at all.
    if np.abs(window[peak]) < 4 * np.std(np.abs(window)):
        return -1
    return peak


def fdaf_cancel(ref: np.ndarray, sig: np.ndarray, delay: int,
                taps: int = 4096, mu: float = 0.5) -> np.ndarray:
    """Subtract ref's echo from sig: partitioned block-frequency NLMS.

    Overlap-save with block size B; `taps` total filter length split into
    partitions so a long echo tail stays cheap (FFTs of 2B, not 2*taps).
    Adaptation freezes when the near-end (sig) is much louder than the
    reference — classic double-talk protection, so the filter models the
    echo path instead of eating the real speaker."""
    if delay > 0:
        ref = np.concatenate([np.zeros(delay, dtype=np.float32), ref])
    n = min(len(ref), len(sig))
    ref, out = ref[:n], sig[:n].copy()

    B = 1024                       # block (hop) size
    P = max(1, taps // B)          # partitions
    F = 2 * B                      # FFT size
    W = np.zeros((P, F // 2 + 1), dtype=np.complex64)   # filter partitions
    X = np.zeros((P, F // 2 + 1), dtype=np.complex64)   # reference spectra history
    eps = 1e-6

    blocks = (n - F) // B
    for k in range(max(0, blocks)):
        i = k * B
        xb = ref[i:i + F]
        X = np.roll(X, 1, axis=0)
        X[0] = np.fft.rfft(xb)
        yhat = np.fft.irfft((W * X).sum(axis=0), F)[B:]   # overlap-save tail
        seg = slice(i + B, i + F)
        py = float((out[seg] ** 2).mean()) + eps          # power BEFORE subtraction
        e = out[seg] - yhat
        pe = float((e ** 2).mean())
        # Divergence clamp: a correct echo filter can only REMOVE energy.
        # If subtraction grew the segment (no real echo path, or the filter
        # is chasing correlated-but-causally-backwards content), keep the
        # original audio and skip the update for this block.
        if pe > 1.5 * py:
            continue
        out[seg] = e
        px = float((np.abs(X[0]) ** 2).mean()) + eps
        if px > 1e-7:
            E = np.fft.rfft(np.concatenate([np.zeros(B, dtype=np.float32), e]))
            norm = (np.abs(X) ** 2).sum(axis=0) + eps
            W += mu * np.conj(X) * E / norm
    return out


def cancel_direction(ref: np.ndarray, sig: np.ndarray,
                     name: str) -> tuple[np.ndarray, int]:
    delay = gcc_phat_delay(ref, sig)
    if delay < 0:
        log(f"{name}: no echo path detected — left untouched")
        return sig, -1
    before = float(np.sqrt((sig ** 2).mean()))
    cleaned = fdaf_cancel(ref, sig, delay)
    after = float(np.sqrt((cleaned ** 2).mean()))
    # An echo canceller can only remove energy; growth means the "echo
    # path" was a spurious correlation. Keep the original.
    if after > before * 1.02:
        log(f"{name}: cancellation diverged (rms {before:.4f} -> {after:.4f}) "
            f"— left untouched")
        return sig, delay
    log(f"{name}: echo path at {delay / RATE * 1000:.0f} ms, "
        f"rms {before:.4f} -> {after:.4f}")
    return cleaned, delay


def residual_echo_gate(mic: np.ndarray, sys_: np.ndarray, delay: int,
                       floor: float = 0.12) -> np.ndarray:
    """Post-AEC safety net for the user's remote echo.

    The linear filter assumes a fixed echo path, but conferencing echo
    drifts (jitter buffers re-time it), so slap-back residue survives.
    And the mix-time ducking can't catch it either: the echo lands
    ~delay ms AFTER the user spoke, when their mic is quiet again and
    the duck has released. This gate ducks sys blocks where the
    DELAY-SHIFTED mic envelope is active and sys is no louder than a
    plausible echo of it — genuinely remote speech is independent of
    the user's (usually louder than a decayed echo, or present while
    the shifted mic is silent) and passes through untouched."""
    B = RATE // 20   # 50 ms blocks
    n = len(sys_)
    if delay > 0:
        micd = np.concatenate([np.zeros(delay, dtype=np.float32), mic])
    else:
        micd = mic
    micd = micd[:n]
    if len(micd) < n:
        micd = np.pad(micd, (0, n - len(micd)))
    nb = n // B
    if nb < 4:
        return sys_
    me = np.sqrt((micd[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    se = np.sqrt((sys_[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    echoish = (me > 0.008) & (se < 1.2 * me)
    # Dilate one block each side: echo tails smear past the envelope.
    d = echoish.copy()
    d[1:] |= echoish[:-1]
    d[:-1] |= echoish[1:]
    gains = np.where(d, floor, 1.0).astype(np.float32)
    # Smooth the gain curve (~3 blocks) so ducking doesn't click.
    kernel = np.ones(3, dtype=np.float32) / 3
    gains = np.convolve(gains, kernel, mode="same")
    out = sys_.copy()
    out[: nb * B] *= np.repeat(gains, B)
    ducked = int(d.sum())
    if ducked:
        log(f"sys: residual echo gate ducked {ducked * B / RATE:.0f}s "
            f"of {nb * B / RATE:.0f}s")
    return out


# --- Stage 2: DeepFilterNet (optional) ---

def deepfilter_available() -> bool:
    return os.path.isfile(os.path.join(ENHANCE_VENV, "bin", "deepFilter"))


def deepfilter(x: np.ndarray, name: str) -> np.ndarray:
    """Run one stream through DeepFilterNet3 via its CLI (own venv)."""
    import wave

    with tempfile.TemporaryDirectory(prefix="meetink-dfn") as td:
        src = os.path.join(td, "in.wav")
        with wave.open(src, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes((np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes())
        rc = subprocess.run(
            [os.path.join(ENHANCE_VENV, "bin", "deepFilter"), src, "-o", td],
            capture_output=True, text=True).returncode
        out_path = os.path.join(td, "in_DeepFilterNet3.wav")
        if rc != 0 or not os.path.isfile(out_path):
            log(f"{name}: DeepFilterNet failed (rc={rc}) — using AEC-only stream")
            return x
        with wave.open(out_path, "rb") as w:
            frames = w.readframes(w.getnframes())
            sr = w.getframerate()
        y = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        if sr != RATE:   # DFN outputs 48 kHz — bring it back to the spool rate
            idx = (np.arange(int(len(y) * RATE / sr)) * (sr / RATE)).astype(np.int64)
            y = y[np.minimum(idx, len(y) - 1)]
        log(f"{name}: DeepFilterNet applied")
        return y


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic", required=True)
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--out-mic", required=True)
    ap.add_argument("--out-sys", required=True)
    ap.add_argument("--no-deepfilter", action="store_true")
    args = ap.parse_args()

    mic = load_raw(args.mic)
    sys_ = load_raw(args.sys_)
    if not len(mic) or not len(sys_):
        log("a stream is empty — nothing to enhance")
        return 1

    # The user's remote echo inside sys (mic is the reference), then
    # speaker/headphone bleed inside mic (sys is the reference).
    clean_sys, sys_delay = cancel_direction(mic, sys_, "sys")
    clean_mic, _ = cancel_direction(sys_, mic, "mic")
    if sys_delay >= 0:
        clean_sys = residual_echo_gate(mic, clean_sys, sys_delay)

    if not args.no_deepfilter and deepfilter_available():
        clean_sys = deepfilter(clean_sys, "sys")
        clean_mic = deepfilter(clean_mic, "mic")

    save_raw(clean_mic, args.out_mic)
    save_raw(clean_sys, args.out_sys)
    return 0


if __name__ == "__main__":
    sys.exit(main())
