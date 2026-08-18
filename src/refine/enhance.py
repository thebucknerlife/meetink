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
from dataclasses import asdict, dataclass
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


PROGRESS_FILE: str | None = None


def progress(msg: str) -> None:
    """Narrate into the app's post-processing state file — the enhance
    stage runs minutes on long meetings and looked hung without it."""
    if PROGRESS_FILE:
        try:
            Path(PROGRESS_FILE).write_text(f"enhancing audio — {msg} (step 3/3)\n")
        except OSError:
            pass


def load_raw(path: str) -> np.ndarray:
    data = np.fromfile(path, dtype=np.int16)
    return data.astype(np.float32) / 32768.0


def save_raw(x: np.ndarray, path: str) -> None:
    np.clip(x, -1.0, 1.0, out=x)
    (x * 32767.0).astype(np.int16).tofile(path)


# --- Stage 1: cross echo cancellation ---


@dataclass(frozen=True)
class EchoPathEvidence:
    """Waveform evidence that ``ref`` occurs later inside ``sig``."""

    detected: bool
    delay_samples: int = -1
    delay_ms: float = -1.0
    peak: float = 0.0
    floor_sigma: float = 0.0
    peak_sigma: float = 0.0
    direction_ratio: float = 0.0

    def to_dict(self) -> dict:
        return asdict(self)


def echo_path_evidence(ref: np.ndarray, sig: np.ndarray,
                       min_delay_s: float = 0.004,
                       max_delay_s: float = 1.5) -> EchoPathEvidence:
    """Measure a *directional* delayed path from ``ref`` into ``sig``.

    GCC-PHAT correlation itself is symmetric.  Looking only at causal
    positive lags (the old detector) could therefore call a returned-self
    ``mic -> sys`` path local speaker bleed.  We compare the strongest
    positive-lag peak with the opposite direction and require both a clean
    peak above the correlation floor and a directional margin.
    """
    n = min(len(ref), len(sig), 120 * RATE)
    min_d = max(1, int(min_delay_s * RATE))
    max_d = min(int(max_delay_s * RATE), max(1, n - 1))
    if n < RATE or max_d <= min_d:
        return EchoPathEvidence(False)

    a = np.asarray(ref[:n], dtype=np.float32)
    b = np.asarray(sig[:n], dtype=np.float32)
    # Literal silence has an artificially flat PHAT spectrum. Reject it
    # before the FFT so health failures never become path evidence.
    if float(np.sqrt(np.mean(a * a))) < 1e-5 \
            or float(np.sqrt(np.mean(b * b))) < 1e-5:
        return EchoPathEvidence(False)

    nfft = 1 << int(np.ceil(np.log2(2 * n - 1)))
    A = np.fft.rfft(a, nfft)
    B = np.fft.rfft(b, nfft)
    R = B * np.conj(A)
    R /= np.abs(R) + 1e-9
    cc = np.fft.irfft(R, nfft)

    positive = np.abs(cc[min_d:max_d + 1])
    negative = np.abs(cc[-max_d:-min_d + 1])
    if not len(positive) or not len(negative):
        return EchoPathEvidence(False)
    rel = int(np.argmax(positive))
    peak = float(positive[rel])
    opposite = float(np.max(negative))
    # Robust-ish floor excluding the winning point. The 4-sigma condition
    # preserves the established no-path rejection; direction_ratio is what
    # separates the two physical echo directions.
    floor_sigma = float(np.std(np.concatenate([positive, negative])))
    peak_sigma = peak / max(floor_sigma, 1e-9)
    direction_ratio = peak / max(opposite, 1e-9)
    delay = min_d + rel
    # A dominant directional peak handles the usual one-way case. Two real
    # echo paths can coexist, in which case neither direction dominates; a
    # much stronger 20-sigma absolute peak admits both without confusing the
    # 4-8 sigma maxima produced by unrelated double-talk.
    detected = peak_sigma >= 20.0 \
        or (peak_sigma >= 4.0 and direction_ratio >= 1.50)
    return EchoPathEvidence(
        detected=bool(detected),
        delay_samples=delay if detected else -1,
        delay_ms=round(delay / RATE * 1000.0, 2) if detected else -1.0,
        peak=round(peak, 7),
        floor_sigma=round(floor_sigma, 7),
        peak_sigma=round(peak_sigma, 2),
        direction_ratio=round(direction_ratio, 3),
    )

def gcc_phat_delay(ref: np.ndarray, sig: np.ndarray, max_delay_s: float = 1.5) -> int:
    """Bulk delay (samples) of ref's echo inside sig, via GCC-PHAT.

    Uses up to the first ~120 s — enough for a stable peak, cheap on long
    meetings. Positive result means sig lags ref (the normal case: the
    echo arrives after the original)."""
    ev = echo_path_evidence(ref, sig, min_delay_s=0.0,
                            max_delay_s=max_delay_s)
    return ev.delay_samples if ev.detected else -1


def fdaf_cancel(ref: np.ndarray, sig: np.ndarray, delay: int,
                taps: int = 4096, mu: float = 0.5,
                progress_label: str = "echo cancel") -> np.ndarray:
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
    step = max(1, blocks // 10)
    for k in range(max(0, blocks)):
        if k % step == 0:
            progress(f"{progress_label} {int(100 * k / max(1, blocks))}%")
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
    cleaned = fdaf_cancel(ref, sig, delay, progress_label=f"{name} echo cancel")
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
                       floor: float = 0.12) -> tuple[np.ndarray, np.ndarray | None]:
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
    nb = n // B
    if nb < 4:
        return sys_, None
    mic = mic[:n]
    if len(mic) < n:
        mic = np.pad(mic, (0, n - len(mic)))

    # Conferencing delay DRIFTS (jitter buffers re-time the echo), so one
    # start-of-call measurement misses later echo. Re-measure per minute,
    # falling back to the previous chunk's delay when a chunk has no
    # usable correlation (silence, remote-only speech).
    CHUNK = 60 * RATE
    delays = []
    d_prev = delay
    for c0 in range(0, n, CHUNK):
        c1 = min(n, c0 + CHUNK)
        d = gcc_phat_delay(mic[c0:c1], sys_[c0:c1]) if c1 - c0 > 5 * RATE else -1
        if d < 0:
            d = d_prev
        delays.append(d)
        d_prev = d

    me_raw = np.sqrt((mic[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    se = np.sqrt((sys_[: nb * B].reshape(nb, B) ** 2).mean(axis=1))

    # Per block: the STRONGEST mic activity across a tolerance window
    # around that minute's delay (-150 ms .. +350 ms) — a point test on a
    # drifted delay is exactly how residue slipped through before.
    me = np.zeros(nb, dtype=np.float32)
    lo_off, hi_off = int(-0.15 * RATE / B), int(0.35 * RATE / B)
    for k in range(nb):
        d = delays[min(k * B // CHUNK, len(delays) - 1)]
        center = k - d // B
        a = max(0, center - hi_off)
        b_ = min(nb, center - lo_off + 1)
        if a < b_:
            me[k] = me_raw[a:b_].max()

    # 0.9, not 1.5: an echo is an ATTENUATED copy — sys at or above the
    # delayed mic's level is more likely real (soft) remote speech, and
    # the aggressive ratio was ducking it to inaudible (field report:
    # transcript shows words the audio barely contains).
    echoish = (me > 0.006) & (se < 0.9 * me)
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
    # The per-block gain curve travels to the archive-rate stream too —
    # it's the transferable part of the echo work (see apply_block_gains).
    return out, gains


def apply_block_gains(x: np.ndarray, gains: np.ndarray,
                      analysis_len: int) -> np.ndarray:
    """Apply a 16 kHz-analysis gain curve to a stream at another rate.

    Time-proportional mapping: gain block k covers the same fraction of
    the archive stream as it did of the analysis stream (both spool pairs
    are driven by the same callbacks, so their timelines are proportional
    even if the sample-count ratio isn't exactly 3). Block-sliced in
    place — np.repeat at 48 kHz would allocate the full stream again."""
    if gains is None or not analysis_len:
        return x
    B = RATE // 20
    out = x.copy()
    n = len(out)
    for k, g in enumerate(gains):
        if g >= 0.999:
            continue
        a = int(k * B * n / analysis_len)
        b = int((k + 1) * B * n / analysis_len)
        if a < b:
            out[a:b] *= g
    return out


# --- Stage 2: DeepFilterNet (optional) ---

def deepfilter_available() -> bool:
    return os.path.isfile(os.path.join(ENHANCE_VENV, "bin", "deepFilter"))


def deepfilter(x: np.ndarray, name: str, rate: int = RATE) -> np.ndarray:
    """Run one stream through DeepFilterNet3 via its CLI (own venv).

    DFN3 is natively a 48 kHz model. Feed it 48 kHz and its output comes
    back at 48 kHz untouched; feed it 16 kHz and it resamples internally
    AND we have to decimate its output back down — the nearest-neighbor
    decimation below is unfiltered and contributed audible aliasing (part
    of the 'tinny/sharp' field report). The archive path avoids it
    entirely by staying at 48 kHz."""
    import wave

    progress(f"DeepFilterNet {name} — takes a while on long meetings")
    with tempfile.TemporaryDirectory(prefix="meetink-dfn") as td:
        src = os.path.join(td, "in.wav")
        with wave.open(src, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(rate)
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
        if sr != rate:   # rate mismatch — bring it back to the stream rate
            idx = (np.arange(int(len(y) * rate / sr)) * (sr / rate)).astype(np.int64)
            y = y[np.minimum(idx, len(y) - 1)]
        log(f"{name}: DeepFilterNet applied ({rate // 1000} kHz)")
        return y


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic", required=True)
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--out-mic", required=True)
    ap.add_argument("--out-sys", required=True)
    ap.add_argument("--mic48", help="48 kHz archive spool for the mic stream")
    ap.add_argument("--sys48", help="48 kHz archive spool for the sys stream")
    ap.add_argument("--no-deepfilter", action="store_true")
    ap.add_argument("--progress-state",
                    help="file to narrate progress into (app status bar)")
    args = ap.parse_args()
    global PROGRESS_FILE
    PROGRESS_FILE = args.progress_state

    mic = load_raw(args.mic)
    sys_ = load_raw(args.sys_)
    if not len(mic) or not len(sys_):
        log("a stream is empty — nothing to enhance")
        return 1

    # 48 kHz archive pair (optional). ALL analysis stays at 16 kHz — the
    # FDAF subtraction is sample-level and can't transfer across rates
    # (measured effect ~0: rms barely moves, and it self-disables on
    # divergence), but the residual echo gate is a per-block gain curve
    # that maps onto the archive streams by time. The outputs then ARE
    # the 48 kHz streams, so DFN runs at its native rate and the mix
    # keeps full bandwidth.
    mic48 = load_raw(args.mic48) if args.mic48 else None
    sys48 = load_raw(args.sys48) if args.sys48 else None
    archive = (mic48 is not None and sys48 is not None
               and len(mic48) > RATE * 3 and len(sys48) > RATE * 3)
    if archive:
        log("archive: 48 kHz streams present — output stays full bandwidth")

    # The user's remote echo inside sys (mic is the reference), then
    # speaker/headphone bleed inside mic (sys is the reference).
    clean_sys, sys_delay = cancel_direction(mic, sys_, "sys")
    clean_mic, _ = cancel_direction(sys_, mic, "mic")
    gate_gains = None
    if sys_delay >= 0:
        clean_sys, gate_gains = residual_echo_gate(mic, clean_sys, sys_delay)

    if archive:
        out_sys = apply_block_gains(sys48, gate_gains, len(sys_))
        out_mic = mic48
        out_rate = 48000
    else:
        out_sys = clean_sys
        out_mic = clean_mic
        out_rate = RATE

    if not args.no_deepfilter and deepfilter_available():
        out_sys = deepfilter(out_sys, "sys", out_rate)
        out_mic = deepfilter(out_mic, "mic", out_rate)

    save_raw(out_mic, args.out_mic)
    save_raw(out_sys, args.out_sys)
    return 0


if __name__ == "__main__":
    sys.exit(main())
