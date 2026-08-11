#!/usr/bin/env python3
"""Neural playback mix — DTLN-aec in both directions, gains only.

The field-tested constraints this must honor (hard-won verdicts):
  - The remote side sounds best as a PASSTHROUGH of the raw sys stream
    (any DFN/duck/neural coloration audibly degrades it).
  - The user sounds best as their RAW mic voice (AEC3's suppressor and
    hard gates made them robotic; misses left them as naked echo).

So the DTLN-aec outputs are never played. Each direction runs as a
DETECTOR: the model removes echo from a stream, and the per-block ratio
rms(clean)/rms(raw) becomes a gain curve applied to the RAW stream —
ratio ≈ 1 (kept speech) passes bit-true, ratio ≈ 0 (echo/bleed) mutes.

  mic gains = DTLN(mic, ref=sys): the remote bleed blocks collapse,
              the user's speech passes raw and natural.
  sys gains = DTLN(sys, ref=CLEANED mic), but applied ONLY inside the
              user's activity windows (cleaned-mic energy, no labels) —
              outside them sys is forced to exactly 1.0. Measured twice:
              with the raw mic as reference the model cancels the remote
              speaker as "echo of the reference" (31% passthrough), and
              even the cleaned mic's residual bleed poisons it (loud
              remote blocks kept at median 0.03). The user's echo only
              exists while they speak, so suppression is confined there.

Mix = mic48*micgains + sys48*sysgains. No transcript, no labels, no
thresholds tied to anyone's noise floor.

Analysis runs at 16 kHz (DTLN's native rate) on the transcription
spools; gains map by time onto the 48 kHz archive pair.
Runs in ~/.meetink/dtln-venv (tensorflow + numpy).
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from transcript_mix import merge_spans, user_spans  # transcript spans

os.environ["CUDA_VISIBLE_DEVICES"] = ""
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "3"


def log(msg: str) -> None:
    print(f"neural-mix: {msg}", file=sys.stderr, flush=True)


PROGRESS_FILE: str | None = None


def progress(msg: str) -> None:
    if PROGRESS_FILE:
        try:
            Path(PROGRESS_FILE).write_text(f"mixing audio — {msg} (step 3/3)\n")
        except OSError:
            pass


def load_raw16(path: str) -> np.ndarray:
    return np.fromfile(path, dtype=np.int16).astype(np.float32) / 32768.0


def dtln_aec(mic: np.ndarray, lpb: np.ndarray, model_prefix: str,
             label: str) -> np.ndarray:
    """Port of breizhn/DTLN-aec run_aec.py to in-memory arrays.
    mic/lpb are 16 kHz float32 mono; returns the echo-cancelled mic."""
    import tensorflow.lite as tflite

    n = min(len(mic), len(lpb))
    audio, ref = mic[:n].copy(), lpb[:n].copy()

    i1 = tflite.Interpreter(model_path=model_prefix + "_1.tflite", num_threads=4)
    i1.allocate_tensors()
    i2 = tflite.Interpreter(model_path=model_prefix + "_2.tflite", num_threads=4)
    i2.allocate_tensors()
    in1, out1 = i1.get_input_details(), i1.get_output_details()
    in2, out2 = i2.get_input_details(), i2.get_output_details()

    block_len, block_shift = 512, 128
    pad = np.zeros(block_len - block_shift, dtype=np.float32)
    audio = np.concatenate((pad, audio, pad))
    ref = np.concatenate((pad, ref, pad))
    states_1 = np.zeros(in1[1]["shape"], dtype=np.float32)
    states_2 = np.zeros(in2[1]["shape"], dtype=np.float32)
    out_file = np.zeros(len(audio), dtype=np.float32)
    in_buf = np.zeros(block_len, dtype=np.float32)
    lpb_buf = np.zeros(block_len, dtype=np.float32)
    out_buf = np.zeros(block_len, dtype=np.float32)
    num_blocks = (audio.shape[0] - (block_len - block_shift)) // block_shift
    step = max(1, num_blocks // 20)
    for idx in range(num_blocks):
        if idx % step == 0:
            progress(f"neural echo removal {label} {int(100 * idx / num_blocks)}%")
        o = idx * block_shift
        in_buf[:-block_shift] = in_buf[block_shift:]
        in_buf[-block_shift:] = audio[o:o + block_shift]
        lpb_buf[:-block_shift] = lpb_buf[block_shift:]
        lpb_buf[-block_shift:] = ref[o:o + block_shift]

        in_fft = np.fft.rfft(in_buf).astype("complex64")
        in_mag = np.abs(in_fft).reshape(1, 1, -1).astype("float32")
        lpb_mag = np.abs(np.fft.rfft(lpb_buf)).reshape(1, 1, -1).astype("float32")
        i1.set_tensor(in1[0]["index"], in_mag)
        i1.set_tensor(in1[2]["index"], lpb_mag)
        i1.set_tensor(in1[1]["index"], states_1)
        i1.invoke()
        mask = i1.get_tensor(out1[0]["index"])
        states_1 = i1.get_tensor(out1[1]["index"])
        est = np.fft.irfft(in_fft * mask).reshape(1, 1, -1).astype("float32")
        lpb_t = lpb_buf.reshape(1, 1, -1).astype("float32")
        i2.set_tensor(in2[1]["index"], states_2)
        i2.set_tensor(in2[0]["index"], est)
        i2.set_tensor(in2[2]["index"], lpb_t)
        i2.invoke()
        out_block = i2.get_tensor(out2[0]["index"])
        states_2 = i2.get_tensor(out2[1]["index"])
        out_buf[:-block_shift] = out_buf[block_shift:]
        out_buf[-block_shift:] = 0.0
        out_buf += np.squeeze(out_block)
        out_file[o:o + block_shift] = out_buf[:block_shift]
    return out_file[(block_len - block_shift):(block_len - block_shift) + n]


def gain_curve(raw: np.ndarray, clean: np.ndarray,
               floor: float = 0.03) -> np.ndarray:
    """Per-50ms-block gains: how much of each block the model kept.
    Blocks the model left alone round UP to exactly 1.0 so kept speech
    is a bit-true passthrough of the raw stream (the field verdicts)."""
    B = 16000 // 20
    n = min(len(raw), len(clean))
    nb = n // B
    r = np.sqrt((raw[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    c = np.sqrt((clean[: nb * B].reshape(nb, B) ** 2).mean(axis=1))
    g = c / np.maximum(r, 1e-6)
    g = np.clip(g, floor, 1.0)
    g[g >= 0.6] = 1.0          # kept speech → exact passthrough
    g[r < 0.003] = 1.0         # silence: nothing to remove, don't pump
    # ~150 ms smoothing so gain steps don't click.
    kernel = np.ones(3, dtype=np.float32) / 3
    return np.convolve(g.astype(np.float32), kernel, mode="same")


def apply_and_sum(mic_path: str, sys_path: str, rate: int,
                  mic_g: np.ndarray, sys_g: np.ndarray, out_path: str) -> None:
    B_hi = rate // 20
    n = max(os.path.getsize(mic_path) // 2, os.path.getsize(sys_path) // 2)
    CHUNK = rate * 10
    with open(mic_path, "rb") as fm, open(sys_path, "rb") as fs, \
         open(out_path, "wb") as fo:
        pos = 0
        while pos < n:
            take = min(CHUNK, n - pos)
            mic = np.frombuffer(fm.read(take * 2), dtype=np.int16)
            sy = np.frombuffer(fs.read(take * 2), dtype=np.int16)
            m = np.zeros(take, dtype=np.float32)
            s = np.zeros(take, dtype=np.float32)
            m[: len(mic)] = mic.astype(np.float32) / 32768.0
            s[: len(sy)] = sy.astype(np.float32) / 32768.0
            idx = np.minimum((np.arange(take) + pos) // B_hi,
                             len(mic_g) - 1)
            idx2 = np.minimum((np.arange(take) + pos) // B_hi,
                              len(sys_g) - 1)
            mixed = m * mic_g[idx] + s * sys_g[idx2]
            np.clip(mixed, -0.98, 0.98, out=mixed)
            fo.write((mixed * 32767.0).astype(np.int16).tobytes())
            pos += take


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic16", required=True, help="16 kHz mic spool (analysis)")
    ap.add_argument("--sys16", required=True, help="16 kHz sys spool (analysis)")
    ap.add_argument("--mic", required=True, help="playback-rate mic stream")
    ap.add_argument("--sys", dest="sys_", required=True)
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--model", default=os.path.expanduser(
        "~/.meetink/dtln/dtln_aec_512"))
    ap.add_argument("--timing", help="timing.json — confines sys suppression "
                    "to the user's spans; omit = sys full passthrough")
    ap.add_argument("--me", default="ME")
    ap.add_argument("--out", required=True)
    ap.add_argument("--progress-state")
    args = ap.parse_args()
    global PROGRESS_FILE
    PROGRESS_FILE = args.progress_state

    if not os.path.isfile(args.model + "_1.tflite"):
        log(f"model not found at {args.model} — falling back")
        return 1
    mic16 = load_raw16(args.mic16)
    sys16 = load_raw16(args.sys16)
    if not len(mic16) or not len(sys16):
        log("a stream is empty — falling back")
        return 1

    mic_clean = dtln_aec(mic16, sys16, args.model, "mic")
    log("mic direction done (bleed removal)")
    # Reference = the CLEANED mic (user-only): see module docstring.
    sys_clean = dtln_aec(sys16, mic_clean.astype(np.float32), args.model, "sys")
    log("sys direction done (echo removal)")

    mic_g = gain_curve(mic16, mic_clean)
    sys_g = gain_curve(sys16, sys_clean)

    # Confine sys suppression to the user's TRANSCRIPT spans (+0.8 s
    # tail for the echo's lag). Everywhere else sys is forced to exact
    # 1.0 — the remote side's proven-best passthrough. Inside the spans
    # the neural ratio decides per block: the user's echo collapses,
    # genuine overlap speech survives. Energy-derived activity masks were
    # tried twice and blanketed ~90% of a real meeting (silence blocks,
    # residual bleed); the transcript is the reliable span source, and a
    # MISSED span is harmless here — the neural mic gains keep the
    # user's voice without labels, so their direct voice always masks
    # the (then unsuppressed) echo, matching the original mix's feel.
    B = 16000 // 20
    dil = np.zeros(len(sys_g), dtype=bool)
    if args.timing and os.path.isfile(args.timing):
        spans = merge_spans(user_spans(args.timing, args.me))
        for s_t, e_t in spans:
            a = max(0, int(s_t / 0.05) - 4)
            b = min(len(dil), int((e_t + 0.8) / 0.05))
            if a < b:
                dil[a:b] = True
    sys_g = np.where(dil, sys_g, 1.0).astype(np.float32)
    log(f"gains: mic passthrough {(mic_g >= 1.0).mean()*100:.0f}%, "
        f"sys passthrough {(sys_g >= 1.0).mean()*100:.0f}% "
        f"(suppression confined to {dil.mean()*100:.0f}% transcript-active)")

    apply_and_sum(args.mic, args.sys_, args.rate, mic_g, sys_g, args.out)
    log("neural mix complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
