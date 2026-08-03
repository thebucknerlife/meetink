#!/usr/bin/env python3
"""Post-meeting re-transcription ("refine") — runs in ~/.meetink/parakeet-venv.

The live transcript is built from independent 3-second chunks, so whisper
never sees cross-chunk acoustic context — the dominant quality limiter.
This pass re-transcribes the WHOLE session audio with Parakeet TDT 0.6B v2
(English specialist: matches/beats whisper large-v3 WER at ~48x throughput,
so an hour-long meeting refines in ~1-2 minutes on Apple Silicon) and
re-diarizes at natural sentence boundaries instead of arbitrary 3 s windows.

Two modes:
  session:  --mic mic.raw --sys sys.raw   (spools written by meetink-capture:
            headerless s16le / 16 kHz / mono, one file per stream)
  import:   --input <any audio file>      (dropped/CLI file; decoded via
            ffmpeg; the whole file is treated as system audio and diarized)

Speaker labels: mic stream is always --me (the person running meetink);
system-stream sentences are sliced out of the raw audio and identified
against the diarize sidecar (:8179/identify) — sentence-length windows are
far better diarization units than the live path's 3 s chunks, and enrolled
voices come back by name. Sidecar down → plain THEM labels, still useful.

Output format matches the live transcript exactly ([HH:MM:SS] LABEL: text),
so everything downstream (titling, summaries, /ask, the app window, the
name-inference pass) consumes it unchanged.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import urllib.request
import wave
from pathlib import Path

# When Meetink.app (launched via `open`, i.e. the launchd environment)
# invokes us, PATH is the bare system set — no Homebrew — and both our
# decode step and parakeet-mlx's internal audio loader exec plain
# "ffmpeg". Extend PATH before anything needs it.
os.environ["PATH"] = (
    os.environ.get("PATH", "/usr/bin:/bin")
    + ":/opt/homebrew/bin:/usr/local/bin"
)

SAMPLE_RATE = 16000
MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v2"


def log(msg: str) -> None:
    print(f"refine: {msg}", file=sys.stderr)


def raw_to_wav(raw: bytes, path: str) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(raw)


def decode_to_raw(input_path: str) -> bytes:
    """Any audio container → headerless s16le/16k/mono via ffmpeg (which
    parakeet-mlx already requires, so it's guaranteed present)."""
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", input_path,
         "-ar", str(SAMPLE_RATE), "-ac", "1", "-f", "s16le", "-"],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg decode failed: {proc.stderr.decode()[:300]}")
    return proc.stdout


# Chunked decoding: whole-file attention on a long recording tries to
# allocate memory quadratic in length (observed: a ~1 h video -> a 520 GB
# Metal allocation). 120 s windows with the library's default 15 s overlap
# keep memory flat with no measurable accuracy cost at the seams.
CHUNK_S = 120.0


def transcribe_sentences(model, raw: bytes, label_for_log: str) -> list[dict]:
    """Parakeet over one stream → [{start, end, text}] sentence segments."""
    if len(raw) < SAMPLE_RATE * 2:  # < 1 s of audio
        return []
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        raw_to_wav(raw, f.name)
        wav_path = f.name

    def on_chunk(*args):
        # chunk_callback(current, total): emit machine-readable progress on
        # STDOUT (flushed) — the app streams these into its progress bar,
        # and they double as a CLI heartbeat on long files.
        if len(args) >= 2 and args[1]:
            pct = min(100, int(100 * float(args[0]) / float(args[1])))
            print(f"refine: progress {label_for_log} {pct}", flush=True)

    try:
        result = model.transcribe(
            wav_path, chunk_duration=CHUNK_S, chunk_callback=on_chunk)
    finally:
        Path(wav_path).unlink(missing_ok=True)
    sentences = getattr(result, "sentences", None) or []
    out = []
    for s in sentences:
        text = s.text.strip()
        if text:
            out.append({
                "start": float(s.start), "end": float(s.end), "text": text,
                # token timing enables mid-sentence speaker splits in the
                # offline diarizer (punctuation is not a turn boundary)
                "tokens": [
                    {"text": t.text, "start": float(t.start)}
                    for t in (getattr(s, "tokens", None) or [])
                ],
            })
    log(f"{label_for_log}: {len(out)} segments, "
        f"{len(raw) // 2 // SAMPLE_RATE}s audio")
    return out


def identify_segment(raw: bytes, start: float, end: float, port: int) -> str | None:
    """Slice [start,end] out of the raw stream and ask the diarize sidecar
    who it is. Sentence-length windows beat the live path's 3 s chunks."""
    a = max(0, int(start * SAMPLE_RATE) * 2)
    b = min(len(raw), int(end * SAMPLE_RATE) * 2)
    if b - a < SAMPLE_RATE * 2:  # server rejects < 1 s as unreliable
        return None
    # Cap the slice: a 3-minute monologue is one sentence to parakeet
    # sometimes; the embedder is happiest around 3-15 s.
    b = min(b, a + SAMPLE_RATE * 2 * 15)
    wav = bytearray()
    n = b - a
    wav += b"RIFF" + struct.pack("<I", 36 + n) + b"WAVEfmt "
    wav += struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16)
    wav += b"data" + struct.pack("<I", n) + raw[a:b]
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/identify", data=bytes(wav), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            body = json.loads(resp.read())
            return body.get("speaker")
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Offline diarization (imports)
#
# The live path labels 3 s chunks greedily as they arrive — it has no choice.
# An import has ALL the audio up front, so it earns the batch treatment:
#   1. slide 3 s windows (1.5 s hop) over every transcribed segment and
#      fetch a stateless embedding per window (:8179/embed — no session
#      mutation, so imports can't contaminate a live meeting's clusters);
#   2. two-stage global clustering: a low-threshold sequential pre-pass
#      collapses the N windows into ~tens of mini-clusters (pure numpy,
#      O(N·M)), then average-linkage agglomerative merging on the
#      mini-cluster centroids (M is small, O(M^3) is nothing) — the global
#      view a one-pass greedy assigner fundamentally lacks;
#   3. map each final cluster to an enrolled profile (centroids + live
#      thresholds from /profiles/centroids) or a fresh "Speaker N";
#   4. label each sentence by duration-weighted majority vote over its
#      windows — and when the windows show one clean label change inside a
#      sentence (speaker turns mid-"sentence" constantly; punctuation is
#      not a turn boundary), split the sentence at the nearest token edge.
# ---------------------------------------------------------------------------

WIN_S = 3.0
HOP_S = 1.5
PRE_CLUSTER_SIM = 0.80   # pre-pass: only near-duplicates collapse


def _http_json(url: str, data: bytes | None = None, timeout: float = 15) -> dict | None:
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except Exception:
        return None


def _wav_bytes(raw: bytes, a: int, b: int) -> bytes:
    n = b - a
    wav = bytearray()
    wav += b"RIFF" + struct.pack("<I", 36 + n) + b"WAVEfmt "
    wav += struct.pack("<IHHIIHH", 16, 1, 1, SAMPLE_RATE, SAMPLE_RATE * 2, 2, 16)
    wav += b"data" + struct.pack("<I", n) + raw[a:b]
    return bytes(wav)


def offline_diarize(raw: bytes, segs: list[dict], port: int) -> list[dict] | None:
    """Return segs relabeled (and possibly split), or None if the sidecar
    is unreachable — caller falls back to plain THEM labels."""
    import numpy as np

    prof = _http_json(f"http://127.0.0.1:{port}/profiles/centroids")
    if prof is None:
        return None
    threshold = float(prof.get("settings", {}).get("threshold", 0.65))
    margin = float(prof.get("settings", {}).get("margin", 0.07))
    single_floor = float(prof.get("settings", {}).get("single_profile_floor", 0.78))
    cluster_thr = float(prof.get("settings", {}).get("cluster_threshold", 0.72))
    profiles = {
        name: np.asarray(cents, dtype=np.float32)
        for name, cents in (prof.get("profiles") or {}).items()
    }

    # 1. Window embeddings.
    windows = []   # (seg_idx, t0, t1)
    for i, seg in enumerate(segs):
        t = seg["start"]
        while t < seg["end"]:
            t1 = min(t + WIN_S, seg["end"])
            if t1 - t >= 1.0:
                windows.append((i, t, t1))
            if t1 >= seg["end"]:
                break
            t += HOP_S
    if not windows:
        return None

    n = len(windows)
    print(f"refine: status identifying speakers ({n} windows, global clustering)",
          flush=True)
    embs: list[np.ndarray | None] = []
    step = max(1, n // 25)
    for k, (_, t0, t1) in enumerate(windows):
        a = int(t0 * SAMPLE_RATE) * 2
        b = min(len(raw), int(t1 * SAMPLE_RATE) * 2)
        resp = _http_json(f"http://127.0.0.1:{port}/embed", data=_wav_bytes(raw, a, b))
        vec = (resp or {}).get("embedding")
        embs.append(np.asarray(vec, dtype=np.float32) if vec else None)
        if (k + 1) % step == 0 or k + 1 == n:
            print(f"refine: progress diarize {int(100 * (k + 1) / n)}", flush=True)

    keep = [k for k, e in enumerate(embs) if e is not None]
    if not keep:
        return None
    E = np.stack([embs[k] / (np.linalg.norm(embs[k]) + 1e-9) for k in keep])
    windows = [windows[k] for k in keep]

    # 2a. Sequential pre-pass: collapse near-duplicates into mini-clusters.
    minis: list[list[int]] = []
    centroids: list[np.ndarray] = []
    for k in range(len(E)):
        if centroids:
            sims = np.stack(centroids) @ E[k]
            j = int(np.argmax(sims))
            if sims[j] >= PRE_CLUSTER_SIM:
                minis[j].append(k)
                c = E[list(minis[j])].mean(axis=0)
                centroids[j] = c / (np.linalg.norm(c) + 1e-9)
                continue
        minis.append([k])
        centroids.append(E[k])

    # 2b. Average-linkage agglomerative merge on mini-cluster centroids,
    # size-weighted, until no pair clears the cluster threshold.
    groups = [list(m) for m in minis]
    cents = list(centroids)
    while len(groups) > 1:
        M = len(cents)
        C = np.stack(cents)
        S = C @ C.T
        np.fill_diagonal(S, -1.0)
        i, j = np.unravel_index(int(np.argmax(S)), S.shape)
        if S[i, j] < cluster_thr:
            break
        merged = groups[i] + groups[j]
        c = E[merged].mean(axis=0)
        groups = [g for k2, g in enumerate(groups) if k2 not in (i, j)] + [merged]
        cents = [c2 for k2, c2 in enumerate(cents) if k2 not in (i, j)] \
            + [c / (np.linalg.norm(c) + 1e-9)]

    # 3. Cluster → name. Enrolled profile if its best centroid clears the
    # live thresholds (same threshold+margin ladder /identify uses; the
    # absolute floor stands in when only one profile exists); else Speaker N.
    labels: list[str] = []
    speaker_n = 0
    for g, c in zip(groups, cents):
        best_name, best_sim, runner = None, -1.0, -1.0
        for name, cent_rows in profiles.items():
            sim = float(np.max(cent_rows @ c)) if len(cent_rows) else -1.0
            if sim > best_sim:
                best_name, runner, best_sim = name, best_sim, sim
            elif sim > runner:
                runner = sim
        ok = best_name is not None and best_sim >= threshold
        if ok and len(profiles) == 1:
            ok = best_sim >= single_floor
        elif ok:
            ok = (best_sim - runner) >= margin
        if ok:
            labels.append(best_name.upper())
        else:
            speaker_n += 1
            labels.append(f"Speaker {speaker_n}")

    win_label: dict[int, str] = {}
    for g, lab in zip(groups, labels):
        for k in g:
            win_label[k] = lab

    # 4. Sentence labels by duration-weighted vote, splitting a sentence at
    # the token boundary nearest a single clean label change.
    out: list[dict] = []
    by_seg: dict[int, list[tuple[float, float, str]]] = {}
    for k, (si, t0, t1) in enumerate(windows):
        if k in win_label:
            by_seg.setdefault(si, []).append((t0, t1, win_label[k]))

    for i, seg in enumerate(segs):
        wins = sorted(by_seg.get(i, []))
        if not wins:
            out.append({**seg, "label": "THEM"})
            continue
        runs: list[tuple[str, float, float]] = []   # (label, from_t, to_t)
        for t0, t1, lab in wins:
            if runs and runs[-1][0] == lab:
                runs[-1] = (lab, runs[-1][1], t1)
            else:
                runs.append((lab, t0, t1))
        tokens = seg.get("tokens") or []
        if len(runs) == 2 and tokens and \
                min(runs[0][2] - runs[0][1], runs[1][2] - runs[1][1]) >= WIN_S:
            # One clean change mid-sentence: split at the nearest token edge.
            cut_t = runs[1][1]
            cut = min(range(len(tokens)),
                      key=lambda t: abs(tokens[t]["start"] - cut_t))
            first = "".join(t["text"] for t in tokens[:cut]).strip()
            second = "".join(t["text"] for t in tokens[cut:]).strip()
            if first and second:
                out.append({"start": seg["start"], "end": cut_t,
                            "text": first, "label": runs[0][0]})
                out.append({"start": cut_t, "end": seg["end"],
                            "text": second, "label": runs[1][0]})
                continue
        votes: dict[str, float] = {}
        for lab, a, b in runs:
            votes[lab] = votes.get(lab, 0.0) + (b - a)
        out.append({**seg, "label": max(votes, key=votes.get)})

    log(f"offline diarize: {len(groups)} voices "
        f"({', '.join(sorted(set(labels)))}) across {len(out)} lines")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic", help="mic-stream spool (raw s16le/16k/mono)")
    ap.add_argument("--sys", dest="sys_", help="system-stream spool (raw)")
    ap.add_argument("--input", help="import mode: any audio file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--me", default="ME", help="label for the mic stream")
    ap.add_argument("--header-from", help="copy header lines from this transcript")
    ap.add_argument("--started", help="session start (ISO8601) for wall-clock stamps")
    ap.add_argument("--diarize-port", type=int, default=8179)
    args = ap.parse_args()

    if not args.input and not (args.mic or args.sys_):
        ap.error("need --input or at least one of --mic/--sys")

    log(f"loading {MODEL_ID}")
    from parakeet_mlx import from_pretrained
    model = from_pretrained(MODEL_ID)

    entries: list[tuple[float, str, str]] = []  # (start_s, label, text)

    def diarize_all(raw: bytes, segs: list[dict]) -> None:
        """Identify every segment, with progress — on long files this pass
        takes real minutes (one embedding per sentence), and it runs AFTER
        the transcription bar hits 100%, so it must narrate itself."""
        n = len(segs)
        if n:
            print(f"refine: status identifying speakers ({n} segments)", flush=True)
        step = max(1, n // 25)
        for i, seg in enumerate(segs):
            label = identify_segment(raw, seg["start"], seg["end"],
                                     args.diarize_port) or "THEM"
            entries.append((seg["start"], label, seg["text"]))
            if (i + 1) % step == 0 or i + 1 == n:
                print(f"refine: progress diarize {int(100 * (i + 1) / n)}",
                      flush=True)

    if args.input:
        raw = decode_to_raw(args.input)
        segs = transcribe_sentences(model, raw, "import")
        labeled = offline_diarize(raw, segs, args.diarize_port)
        if labeled is not None:
            for seg in labeled:
                entries.append((seg["start"], seg["label"], seg["text"]))
        else:
            # Sidecar unreachable — sequential per-segment fallback.
            diarize_all(raw, segs)
    else:
        if args.mic and Path(args.mic).exists():
            mic_raw = Path(args.mic).read_bytes()
            me = args.me.strip().upper() or "ME"
            for seg in transcribe_sentences(model, mic_raw, "mic"):
                entries.append((seg["start"], me, seg["text"]))
        if args.sys_ and Path(args.sys_).exists():
            sys_raw = Path(args.sys_).read_bytes()
            diarize_all(sys_raw, transcribe_sentences(model, sys_raw, "sys"))

    if not entries:
        log("no speech found — leaving original transcript untouched")
        return 2

    entries.sort(key=lambda e: e[0])

    # Wall-clock line stamps when we know the session start (matches the
    # live format); otherwise relative from 0 (imports).
    base: dt.datetime | None = None
    if args.started:
        try:
            base = dt.datetime.fromisoformat(
                args.started.replace("Z", "+00:00")).astimezone()
        except ValueError:
            pass

    def stamp(offset_s: float) -> str:
        if base is not None:
            return (base + dt.timedelta(seconds=offset_s)).strftime("%H:%M:%S")
        return str(dt.timedelta(seconds=int(offset_s))).rjust(8, "0")

    lines: list[str] = []
    header_done = False
    if args.header_from and Path(args.header_from).exists():
        for hl in Path(args.header_from).read_text(errors="replace").splitlines():
            if re.match(r"^\[\d{2}:\d{2}:\d{2}\] ", hl) or hl.startswith("---"):
                break
            lines.append(hl)
        header_done = True
    if not header_done:
        lines.append("# Meeting Transcript (imported audio)")
        if args.input:
            lines.append(f"# source: {Path(args.input).name}")
        lines.append("Started: " +
                     dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        lines.append("")
    lines.append(f"# refined: parakeet ({MODEL_ID.split('/')[-1]})")

    for start_s, label, text in entries:
        lines.append(f"[{stamp(start_s)}] {label}: {text}")

    Path(args.out).write_text("\n".join(lines) + "\n")
    log(f"wrote {len(entries)} lines -> {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
