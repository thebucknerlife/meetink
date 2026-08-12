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
from transcript_mix import env_for_chunk, merge_spans, user_spans

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


def mask_transfer_48k(raw16: np.ndarray, clean16: np.ndarray,
                      raw48_path: str, out_path: str) -> None:
    """Apply DTLN's separation to the 48 kHz stream at SAMPLE level.

    Block-level gains could not separate mixed blocks — a 50 ms block
    holding both the user's voice and remote bleed passed in full, and
    the bleed rode along under the clean sys copy (field verdict: "echo
    worse, on both sides"). This transfers the model's time-frequency
    mask instead: |STFT(clean)|/|STFT(raw)| at 16 kHz maps 1:1 onto the
    lowest 257 bins of a 48 kHz STFT (frame 1536/hop 384 = the same
    31.25 Hz bins as frame 512/hop 128 at 16 kHz); bins above 8 kHz
    scale with the frame's broadband mask (voice presence).
    Chunked OLA so long meetings never load fully."""
    F16, H16 = 512, 128
    F48, H48 = 1536, 384
    win16 = np.hanning(F16).astype(np.float32)
    win48 = np.hanning(F48).astype(np.float32)
    n48 = os.path.getsize(raw48_path) // 2
    frames = max(0, (min(len(raw16), len(clean16)) - F16) // H16)

    with open(raw48_path, "rb") as fi, open(out_path, "wb") as fo:
        raw48 = np.frombuffer(fi.read(), dtype=np.int16).astype(np.float32) / 32768.0
        out48 = np.zeros(len(raw48), dtype=np.float32)
        norm = np.zeros(len(raw48), dtype=np.float32)
        for t in range(frames):
            o16 = t * H16
            o48 = t * H48
            if o48 + F48 > len(raw48):
                break
            S_raw = np.fft.rfft(raw16[o16:o16 + F16] * win16)
            S_cln = np.fft.rfft(clean16[o16:o16 + F16] * win16)
            mask = np.clip(np.abs(S_cln) / (np.abs(S_raw) + 1e-7), 0.0, 1.0)
            S48 = np.fft.rfft(raw48[o48:o48 + F48] * win48)
            full = np.empty(F48 // 2 + 1, dtype=np.float32)
            full[:257] = mask
            # Highs follow the frame's voiced-band mask energy.
            full[257:] = float(np.clip(mask[10:200].mean() * 1.2, 0.0, 1.0))
            seg = np.fft.irfft(S48 * full).astype(np.float32) * win48
            out48[o48:o48 + F48] += seg
            norm[o48:o48 + F48] += win48 * win48
        np.divide(out48, np.maximum(norm, 1e-3), out=out48)
        np.clip(out48, -0.98, 0.98, out=out48)
        fo.write((out48 * 32767.0).astype(np.int16).tobytes())


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
    ap.add_argument("--mode", choices=["spans", "cleanmix"], default="spans",
                    help="cleanmix: sys raw + separated mic + level match, "
                         "no ducks, no transcript — the weak-speakers mix")
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

    if args.mode == "cleanmix":
        # Weak-speakers mix: pristine sys + the separated mic, one
        # static gain each, soft headroom. No ducks (the user's echo in
        # sys is below the weak bleed by construction), no transcript.
        mic_sep = args.out + ".micsep.raw"
        mask_transfer_48k(mic16, mic_clean.astype(np.float32), args.mic, mic_sep)

        def gain16(x: np.ndarray, target: float = 0.07) -> float:
            B_ = RATE // 10
            nb_ = len(x) // B_
            if nb_ < 20:
                return 1.0
            r_ = np.sqrt((x[: nb_ * B_].reshape(nb_, B_) ** 2).mean(axis=1))
            act = r_[r_ > 0.01]
            if len(act) < 10:
                return 1.0
            return float(np.clip(target / max(float(np.percentile(act, 75)), 1e-4),
                                 0.25, 4.0))

        gm = gain16(mic_clean)
        gs = gain16(sys16)
        log(f"cleanmix level match: mic x{gm:.2f}, sys x{gs:.2f}")
        n2 = max(os.path.getsize(mic_sep) // 2, os.path.getsize(args.sys_) // 2)
        CH = args.rate * 10
        with open(mic_sep, "rb") as fm2, open(args.sys_, "rb") as fs2, \
             open(args.out, "wb") as fo2:
            pos2 = 0
            while pos2 < n2:
                take2 = min(CH, n2 - pos2)
                mm = np.frombuffer(fm2.read(take2 * 2), dtype=np.int16)
                ss = np.frombuffer(fs2.read(take2 * 2), dtype=np.int16)
                a2 = np.zeros(take2, dtype=np.float32)
                b2 = np.zeros(take2, dtype=np.float32)
                a2[: len(mm)] = mm.astype(np.float32) / 32768.0
                b2[: len(ss)] = ss.astype(np.float32) / 32768.0
                mixed2 = a2 * gm + b2 * gs
                over2 = np.abs(mixed2) > 0.85
                mixed2[over2] = np.sign(mixed2[over2]) * (
                    0.85 + 0.13 * np.tanh((np.abs(mixed2[over2]) - 0.85) / 0.13))
                fo2.write((mixed2 * 32767.0).astype(np.int16).tobytes())
                pos2 += take2
        os.unlink(mic_sep)
        log("neural clean-mix complete (weak-speakers)")
        return 0

    # The mic track IS the separation, at sample level and 48 kHz —
    # block gains passed mixed blocks whole and the bleed rode along
    # under the clean sys copy ("echo worse, on both sides").
    progress("applying separation to the archive mic")
    mic_sep = args.out + ".micsep.raw"
    mask_transfer_48k(mic16, mic_clean.astype(np.float32), args.mic, mic_sep)
    log("mic separation transferred to playback rate")

    # sys: the v6 recipe the user rated best — bit-true passthrough
    # outside their transcript spans, a uniform deep duck inside them
    # (+1.0 s tail for the echo's lag). No model in this path: the sys
    # direction misjudged echo blocks as keep-speech and let them
    # through at full level. A missed span stays harmless — the
    # separated mic carries the user's voice label-free, masking the
    # unsuppressed echo.
    spans = []
    if args.timing and os.path.isfile(args.timing):
        spans = merge_spans(user_spans(args.timing, args.me))
    duck_spans = [(s0, e0 + 1.0) for s0, e0 in spans]
    DUCK = 0.08

    n = max(os.path.getsize(mic_sep) // 2, os.path.getsize(args.sys_) // 2)
    CHUNK = args.rate * 10
    with open(mic_sep, "rb") as fm, open(args.sys_, "rb") as fs,          open(args.out, "wb") as fo:
        pos = 0
        while pos < n:
            take = min(CHUNK, n - pos)
            mic = np.frombuffer(fm.read(take * 2), dtype=np.int16)
            sy = np.frombuffer(fs.read(take * 2), dtype=np.int16)
            m = np.zeros(take, dtype=np.float32)
            sv = np.zeros(take, dtype=np.float32)
            m[: len(mic)] = mic.astype(np.float32) / 32768.0
            sv[: len(sy)] = sy.astype(np.float32) / 32768.0
            env = env_for_chunk(duck_spans, pos, take, args.rate) if duck_spans                 else np.zeros(take, dtype=np.float32)
            mixed = m + sv * (1.0 - (1.0 - DUCK) * env)
            np.clip(mixed, -0.98, 0.98, out=mixed)
            fo.write((mixed * 32767.0).astype(np.int16).tobytes())
            pos += take
    os.unlink(mic_sep)
    log("neural mix complete (separated mic + v6 sys)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
