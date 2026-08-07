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


_PERF: dict[str, float] = {}
_PERF_T0 = None


def perf_mark(phase: str, t0: float) -> None:
    import time as _t
    _PERF[phase] = _PERF.get(phase, 0.0) + (_t.time() - t0)


def perf_write(kind: str, name: str, audio_s: float) -> None:
    """One line per run into ~/.meetink/perf.log — the longitudinal
    record of what each phase costs, so 'is it getting faster?' has data
    instead of vibes. Grep-able key=value format."""
    import time as _t
    total = _t.time() - _PERF_T0 if _PERF_T0 else 0
    parts = [f"{k}_s={v:.1f}" for k, v in sorted(_PERF.items())]
    line = (f"{_t.strftime('%Y-%m-%d %H:%M:%S')}  kind={kind} name={name} "
            f"audio_s={audio_s:.0f} total_s={total:.1f} " + " ".join(parts))
    try:
        with open(os.path.expanduser("~/.meetink/perf.log"), "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    log(f"perf: {line.split('  ', 1)[1]}")


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


def parse_label_priors(txt_path: str) -> list[tuple[float, float, str]]:
    """User-blessed (start_s, end_s, LABEL) spans from an existing
    transcript — the supervision a reprocess must not throw away. Only
    proper names count (Speaker N / THEM carry no user intent). Offsets
    come from the line stamps minus the Started header; the ±1 s slop of
    wall-clock stamps is fine for overlap voting."""
    try:
        lines = Path(txt_path).read_text(errors="replace").splitlines()
    except OSError:
        return []
    started = None
    for ln in lines:
        if ln.startswith("Started:"):
            try:
                started = dt.datetime.fromisoformat(
                    ln.split(":", 1)[1].strip().replace("Z", "+00:00")).astimezone()
            except ValueError:
                pass
            break
    if started is None:
        return []
    day0 = started.hour * 3600 + started.minute * 60 + started.second
    stamped: list[tuple[float, str]] = []
    for ln in lines:
        m = re.match(r"^\[(\d{2}):(\d{2}):(\d{2})\] ([^:]+):", ln)
        if not m:
            continue
        t = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) - day0
        if t < -3600:
            t += 86400
        stamped.append((max(0.0, t), m.group(4).strip().upper()))
    spans = []
    for i, (t, lab) in enumerate(stamped):
        if lab == "THEM" or re.match(r"^SPEAKER \S+$", lab):
            continue
        end = stamped[i + 1][0] if i + 1 < len(stamped) else t + 5.0
        if end > t:
            spans.append((t, end, lab))
    return spans


PYANNOTE_VENV = os.environ.get(
    "MEETINK_PYANNOTE_VENV",
    os.path.expanduser("~/.meetink/pyannote-venv"))


def pyannote_diarize_import(raw: bytes, segs: list[dict],
                            port: int) -> list[dict] | None:
    """Premium diarization for IMPORTS: pyannote 3.1 does the WHO-SPOKE-
    WHEN (joint segmentation + clustering, overlap-aware — much stronger
    than our sliding-window clustering on single-stream audio), then the
    sidecar does the WHO-IS-IT: each pyannote cluster is embedded and
    matched against enrolled profiles with the same gate ladder the rest
    of the system uses, unnamed clusters become Speaker N, and the
    clusters are handed to the sidecar so post-hoc assignment enrolls
    real voice data. Returns labeled entries or None (caller falls back
    to the built-in path). Disable with import_diarizer=builtin."""
    import numpy as np

    py = os.path.join(PYANNOTE_VENV, "bin", "python")
    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          "pyannote_diar.py")
    if not (os.path.isfile(py) and os.path.isfile(helper)):
        return None
    cfg = os.path.expanduser("~/.meetink/config")
    try:
        for line in open(cfg):
            if line.startswith("import_diarizer=") and \
                    line.strip().split("=", 1)[1] == "builtin":
                return None
    except OSError:
        pass

    prof = _http_json(f"http://127.0.0.1:{port}/profiles/centroids")
    if prof is None:
        return None   # sidecar down — the fallback path handles that too

    print("refine: status identifying speakers (pyannote)", flush=True)
    with tempfile.NamedTemporaryFile(suffix=".raw", delete=False) as tf:
        tf.write(raw)
        raw_path = tf.name
    # Popen with streamed stderr: pyannote runs MINUTES on long files, and
    # its progress lines must reach the status bar live, not post-mortem
    # (field report: 'is it hanging? would be nice if it had progress').
    stderr_tail = ""
    try:
        proc = subprocess.Popen([py, helper, "--raw", raw_path],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True)
        for line in proc.stderr:
            stderr_tail = (stderr_tail + line)[-400:]
            if line.startswith("pyannote: progress "):
                parts = line.strip().split(" ")
                pct, phase = parts[2], (parts[3] if len(parts) > 3 else "")
                print(f"refine: status identifying speakers — pyannote "
                      f"{phase + ' ' if phase else ''}{pct}%", flush=True)
        stdout, _ = proc.communicate(timeout=60)
    finally:
        os.unlink(raw_path)
    if proc.returncode != 0:
        log(f"pyannote failed (rc={proc.returncode}) — using built-in "
            f"diarizer: {stderr_tail.strip()[-200:]}")
        return None
    try:
        turns = json.loads(stdout.strip().splitlines()[-1])["turns"]
    except (ValueError, KeyError, IndexError):
        log("pyannote produced no parsable turns — using built-in diarizer")
        return None
    if not turns:
        return None
    log(f"pyannote: {len(turns)} turns, "
        f"{len(set(t[2] for t in turns))} speakers")

    # Majority-overlap speaker per parakeet segment.
    def seg_speaker(a: float, b: float) -> str | None:
        votes: dict[str, float] = {}
        for t0, t1, spk in turns:
            ov = min(b, t1) - max(a, t0)
            if ov > 0:
                votes[spk] = votes.get(spk, 0.0) + ov
        return max(votes, key=lambda k: votes[k]) if votes else None

    # Name pyannote's clusters via the sidecar: embed a sample of each
    # cluster's segments, average, and run the same profile gate ladder
    # offline_diarize_multi uses.
    threshold = float(prof.get("settings", {}).get("threshold", 0.65))
    margin = float(prof.get("settings", {}).get("margin", 0.07))
    single_floor = float(prof.get("settings", {}).get("single_profile_floor", 0.78))
    profiles = {
        name: np.asarray(cents, dtype=np.float32)
        for name, cents in (prof.get("profiles") or {}).items()
    }

    by_spk: dict[str, list[dict]] = {}
    for seg in segs:
        spk = seg_speaker(seg["start"], seg["end"])
        seg["_spk"] = spk
        if spk:
            by_spk.setdefault(spk, []).append(seg)

    spk_embs: dict[str, list] = {}
    for spk, spk_segs in by_spk.items():
        sample = spk_segs if len(spk_segs) <= 12 else \
            [spk_segs[int(k * (len(spk_segs) - 1) / 11)] for k in range(12)]
        embs = []
        for seg in sample:
            a = int(seg["start"] * SAMPLE_RATE) * 2
            b = min(len(raw), int(seg["end"] * SAMPLE_RATE) * 2)
            resp = _http_json(f"http://127.0.0.1:{port}/embed",
                              data=_wav_bytes(raw, a, b))
            vec = (resp or {}).get("embedding")
            if vec:
                v = np.asarray(vec, dtype=np.float32)
                embs.append(v / (np.linalg.norm(v) + 1e-9))
        if embs:
            spk_embs[spk] = embs

    names: dict[str, str] = {}
    speaker_n = 0
    for spk in sorted(by_spk, key=lambda k: -len(by_spk[k])):
        nm = None
        embs = spk_embs.get(spk)
        if embs:
            c = np.mean(embs, axis=0)
            c = c / (np.linalg.norm(c) + 1e-9)
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
                nm = best_name.upper()
        if nm is None:
            speaker_n += 1
            nm = f"Speaker {speaker_n}"
        names[spk] = nm

    # Hand the clusters to the sidecar (same contract as the built-in
    # path) unless a live recording owns the session.
    try:
        live_pid = int(Path("/tmp/meetink-capture.pid").read_text().strip())
        os.kill(live_pid, 0)
        log("a recording is live — NOT handing clusters to the sidecar")
    except (OSError, ValueError):
        payload = {"clusters": [
            {"label": names[spk], "embeddings": [e.tolist() for e in embs]}
            for spk, embs in spk_embs.items()
        ]}
        resp = _http_json(f"http://127.0.0.1:{port}/session/load",
                          data=json.dumps(payload).encode())
        if resp and resp.get("ok"):
            log(f"session clusters handed to sidecar ({len(spk_embs)})")

    out = []
    for seg in segs:
        label = names.get(seg.pop("_spk", None) or "", "THEM")
        out.append({**seg, "label": label, "origin": "import"})
    log(f"pyannote diarize: {len(names)} voices "
        f"({', '.join(sorted(set(names.values())))})")
    return out


def offline_diarize_multi(streams: list[dict], port: int,
                          me_label: str | None = None,
                          priors: list[tuple[float, float, str]] | None = None) -> list[dict] | None:
    """Joint offline diarization over one or more streams.

    streams: [{"raw": bytes, "segs": [...], "origin": "mic"|"sys"|"import"}]
    Returns labeled entries [{start, end, text, label, origin}] or None when
    the sidecar is unreachable (caller falls back).

    All streams cluster in ONE embedding space — that's what makes hybrid
    meetings work: the mic hears the room AND (without headphones) an echo
    of the remote side, and joint clustering puts the echo windows in the
    same cluster as the remote voice's system-audio windows, so they get
    the remote speaker's label (and the text-level dedup then removes the
    duplicates). Deliberately NO reliance on which streams are silent — a
    hybrid meeting has a busy sys stream and a multi-voice mic stream.

    Labeling policy (agreed in the field):
      - cluster matches an enrolled profile        -> that name
      - me_label given and no cluster matched it   -> the cluster with the
        most MIC speech is assumed to be the user (logged; enrolling pins
        it properly)
      - small unnamed mic-only clusters fold into the user's cluster —
        they're almost always the user's noisy windows, and this is what
        keeps a normal headset call from growing phantom speakers
      - everything else -> "Speaker N" (numbering shared across streams)
    """
    import numpy as np

    prof = _http_json(f"http://127.0.0.1:{port}/profiles/centroids")
    if prof is None:
        return None
    threshold = float(prof.get("settings", {}).get("threshold", 0.65))
    margin = float(prof.get("settings", {}).get("margin", 0.07))
    single_floor = float(prof.get("settings", {}).get("single_profile_floor", 0.78))
    cluster_thr = float(prof.get("settings", {}).get("cluster_threshold", 0.72))
    # Pre-pass collapses only near-duplicates; "near" is relative to the
    # active model's similarity scale, so derive it instead of hardcoding.
    pre_sim = min(0.85, cluster_thr + 0.15)
    profiles = {
        name: np.asarray(cents, dtype=np.float32)
        for name, cents in (prof.get("profiles") or {}).items()
    }

    # 1. Windows across every stream: (stream_idx, seg_idx, t0, t1).
    windows: list[tuple[int, int, float, float]] = []
    for si, stream in enumerate(streams):
        for i, seg in enumerate(stream["segs"]):
            t = seg["start"]
            while t < seg["end"]:
                t1 = min(t + WIN_S, seg["end"])
                if t1 - t >= 1.0:
                    windows.append((si, i, t, t1))
                if t1 >= seg["end"]:
                    break
                t += HOP_S
    if not windows:
        return None

    n = len(windows)
    print(f"refine: status identifying speakers ({n} windows, global clustering)",
          flush=True)
    embs: list = []
    step = max(1, n // 25)
    for k, (si, _, t0, t1) in enumerate(windows):
        raw = streams[si]["raw"]
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
    centroids: list = []
    for k in range(len(E)):
        if centroids:
            sims = np.stack(centroids) @ E[k]
            j = int(np.argmax(sims))
            if sims[j] >= pre_sim:
                minis[j].append(k)
                c = E[list(minis[j])].mean(axis=0)
                centroids[j] = c / (np.linalg.norm(c) + 1e-9)
                continue
        minis.append([k])
        centroids.append(E[k])

    # 2b. Average-linkage agglomerative merge on mini-cluster centroids.
    groups = [list(m) for m in minis]
    cents = list(centroids)
    while len(groups) > 1:
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

    # Helpers: per-origin seconds in a cluster.
    def origin_seconds(g: list[int], origin: str) -> float:
        total = 0.0
        for k in g:
            si, _, t0, t1 = windows[k]
            if streams[si]["origin"] == origin:
                total += t1 - t0
        return total

    def mic_seconds(g: list[int]) -> float:
        return origin_seconds(g, "mic")

    # 3a. User-blessed priors first: on a reprocess, a cluster whose
    # windows spend most of their time inside spans the user already
    # labeled inherits that label — direct supervision outranks the
    # voiceprint gates below (which is exactly how manual corrections
    # used to get lost on reprocess).
    names: list = [None] * len(groups)
    if priors:
        for gi, g in enumerate(groups):
            votes: dict[str, float] = {}
            total = 0.0
            for k in g:
                _, _, t0, t1 = windows[k]
                total += t1 - t0
                for (p0, p1, lab) in priors:
                    ov = min(t1, p1) - max(t0, p0)
                    if ov > 0:
                        votes[lab] = votes.get(lab, 0.0) + ov
            if total > 0 and votes:
                best = max(votes, key=lambda k2: votes[k2])
                if votes[best] >= 0.6 * total:
                    names[gi] = best
        n_prior = sum(1 for nm in names if nm is not None)
        if n_prior:
            log(f"label priors matched {n_prior} cluster(s) from the "
                f"existing transcript")

    # 3b. Cluster -> name via enrolled profiles (same gate ladder /identify
    # uses), then resolve the user's cluster, then Speaker N the rest.
    for gi, c in enumerate(cents):
        if names[gi] is not None:
            continue
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
            names[gi] = best_name.upper()

    me_name = (me_label or "").strip().upper() or None
    me_gi: int | None = None
    if me_name:
        for gi, nm in enumerate(names):
            if nm == me_name:
                me_gi = gi
                break
        if me_gi is None and any(st["origin"] == "mic" for st in streams):
            # No enrolled match — assume the dominant MIC-EXCLUSIVE voice is
            # the user. Crucial subtlety: without headphones, a remote
            # speaker's echo is also mic-origin audio, and a chatty remote
            # participant can out-talk the user on the mic — but their
            # cluster also contains system-audio windows, and the local
            # user's never does. Clusters with meaningful sys audio are
            # therefore ineligible to be "me".
            best_gi, best_mic = None, 0.0
            for gi, g in enumerate(groups):
                total = sum(windows[k][3] - windows[k][2] for k in g)
                if total <= 0 or origin_seconds(g, "sys") > 0.2 * total:
                    continue
                m = mic_seconds(g)
                if m > best_mic:
                    best_gi, best_mic = gi, m
            if best_gi is not None and best_mic > 0.0:
                me_gi = best_gi
                names[me_gi] = me_name
                log(f"no enrolled profile matched {me_name} — assuming the "
                    f"dominant mic-only voice is them ({best_mic:.0f}s). "
                    f"Enroll (/profile add) to pin this.")

    # Headset-call guard: STRAY unnamed mic windows fold into the user —
    # but only when they also SOUND like the user (centroid similarity at
    # the sticky-tier floor). Without the similarity check this ate real
    # guests: a room voice saying one short sentence is also a "small
    # mostly-mic cluster". The user's noise-windows pass both tests; a
    # distinct guest voice fails the similarity one.
    if me_gi is not None:
        me_cent = cents[me_gi]
        for gi, g in enumerate(groups):
            if gi == me_gi or names[gi] is not None:
                continue
            total = sum(windows[k][3] - windows[k][2] for k in g)
            if len(g) <= 2 and mic_seconds(g) >= 0.7 * total and \
                    float(cents[gi] @ me_cent) >= 0.35:
                names[gi] = names[me_gi]
            if os.environ.get("MEETINK_REFINE_DEBUG"):
                log(f"debug cluster {gi}: windows={len(g)} total={total:.1f}s "
                    f"mic={mic_seconds(g):.1f}s sim_to_me={float(cents[gi] @ me_cent):.3f} "
                    f"name={names[gi]}")

    # Tiny unnamed clusters are almost never a real extra person — they're
    # one short interjection whose embedding didn't match anyone. Fold each
    # into the acoustically nearest substantial cluster when plausibly the
    # same voice; otherwise label THEM. Never mint "Speaker 23" for a
    # one-liner (field case: 5 people became 19 labels).
    fold_into: dict[int, int] = {}
    substantial = [gi for gi, g in enumerate(groups)
                   if names[gi] is not None or
                   (len(g) >= 3 and sum(windows[k][3] - windows[k][2] for k in g) >= 6.0)]
    for gi, g in enumerate(groups):
        if names[gi] is not None or gi in substantial:
            continue
        best_t, best_sim = None, -1.0
        for tj in substantial:
            if tj == gi:
                continue
            sim = float(cents[gi] @ cents[tj])
            if sim > best_sim:
                best_t, best_sim = tj, sim
        if best_t is not None and best_sim >= 0.35:
            fold_into[gi] = best_t
        else:
            names[gi] = "THEM"

    speaker_n = 0
    labels: list[str] = []
    for gi, nm in enumerate(names):
        if gi in fold_into:
            labels.append("")  # resolved below, target may not be labeled yet
        elif nm is not None:
            labels.append(nm)
        else:
            speaker_n += 1
            labels.append(f"Speaker {speaker_n}")
    for gi, tj in fold_into.items():
        labels[gi] = labels[tj]
    if fold_into:
        log(f"folded {len(fold_into)} tiny cluster(s) into their nearest voice")

    win_label: dict[int, str] = {}
    for g, lab in zip(groups, labels):
        for k in g:
            win_label[k] = lab

    # Exemplar anchoring: the user's per-segment corrections are FEW-SHOT
    # VOICEPRINTS, not just cluster names. When clustering FUSED several
    # people into one cluster, overlap voting can only rename the fused
    # blob — but a centroid built from each corrected span lets every
    # window re-test against the actual voices, and strong matches take
    # the person's label directly, overriding the fused cluster. Per-
    # segment voting below then re-attributes the meeting. Workflow:
    # reassign one clean span per person, hit Reprocess.
    if priors:
        per: dict[str, list] = {}
        for k, (si, i, t0, t1) in enumerate(windows):
            mid = (t0 + t1) / 2
            for (p0, p1, lab) in priors:
                if p0 <= mid <= p1:
                    per.setdefault(lab, []).append(E[k])
                    break
        exemplars = {lab: (lambda m: m / (np.linalg.norm(m) + 1e-9))(
                        np.mean(vs, axis=0))
                     for lab, vs in per.items() if len(vs) >= 2}
        if len(exemplars) >= 2:
            # Two+ distinct voices pointed out — that's a real distinction
            # worth propagating. (A single exemplar adds nothing beyond
            # the overlap voting above.)
            ANCHOR_FLOOR = 0.40   # between sticky (0.38) and cluster (0.50)
            labs = list(exemplars)
            M = np.stack([exemplars[l] for l in labs])
            sims = E @ M.T
            anchored = 0
            for k in range(len(E)):
                j = int(np.argmax(sims[k]))
                if sims[k, j] >= ANCHOR_FLOOR:
                    win_label[k] = labs[j]
                    anchored += 1
            log(f"exemplar anchoring: {len(exemplars)} corrected voices "
                f"({', '.join(labs)}) re-attributed {anchored}/{len(E)} windows")

    # 4. Per-segment vote (duration-weighted) + single-change splits.
    out: list[dict] = []
    by_seg: dict[tuple[int, int], list] = {}
    for k, (si, i, t0, t1) in enumerate(windows):
        if k in win_label:
            by_seg.setdefault((si, i), []).append((t0, t1, win_label[k]))

    for si, stream in enumerate(streams):
        origin = stream["origin"]
        default_label = names[me_gi] if (origin == "mic" and me_gi is not None) \
            else "THEM"
        for i, seg in enumerate(stream["segs"]):
            wins = sorted(by_seg.get((si, i), []))
            if not wins:
                out.append({**seg, "label": default_label, "origin": origin})
                continue
            runs: list = []
            for t0, t1, lab in wins:
                if runs and runs[-1][0] == lab:
                    runs[-1] = (lab, runs[-1][1], t1)
                else:
                    runs.append((lab, t0, t1))
            tokens = seg.get("tokens") or []
            if len(runs) == 2 and tokens and \
                    min(runs[0][2] - runs[0][1], runs[1][2] - runs[1][1]) >= WIN_S:
                cut_t = runs[1][1]
                cut = min(range(len(tokens)),
                          key=lambda t: abs(tokens[t]["start"] - cut_t))
                first = "".join(t["text"] for t in tokens[:cut]).strip()
                second = "".join(t["text"] for t in tokens[cut:]).strip()
                if first and second:
                    out.append({"start": seg["start"], "end": cut_t,
                                "text": first, "label": runs[0][0],
                                "origin": origin})
                    out.append({"start": cut_t, "end": seg["end"],
                                "text": second, "label": runs[1][0],
                                "origin": origin})
                    continue
            votes: dict = {}
            for lab, a, b in runs:
                votes[lab] = votes.get(lab, 0.0) + (b - a)
            out.append({**seg, "label": max(votes, key=votes.get),
                        "origin": origin})

    log(f"offline diarize: {len(groups)} voices "
        f"({', '.join(sorted(set(labels)))}) across {len(out)} lines")

    # Hand the final clusters (label + sample embeddings) to the sidecar so
    # the session survives the refine: assigning a speaker AFTER the call —
    # app click-to-name or /profile assign "Speaker 3" Diogo — folds these
    # exact embeddings into a voice profile. Without this the offline
    # analysis was discarded and post-call assignment had nothing to enroll
    # from. Best-effort: an old sidecar without /session/load just 404s.
    # COLLISION GUARD: the sidecar's session state belongs to the LIVE
    # recording when one is running — replacing it mid-call from a
    # concurrent reprocess/import would wipe the live Speaker-N clusters
    # and scramble labels for the rest of the meeting. The live session's
    # own stop pushes after its capture exits, so this only skips the
    # genuinely-concurrent case.
    try:
        live_pid = int(Path("/tmp/meetink-capture.pid").read_text().strip())
        os.kill(live_pid, 0)
        log("a recording is live — NOT handing clusters to the sidecar "
            "(post-call assignment for this transcript needs a reprocess)")
        return out
    except (OSError, ValueError):
        pass

    payload = {"clusters": []}
    for g, lab in zip(groups, labels):
        sample_idx = g if len(g) <= 40 else             [g[int(k * (len(g) - 1) / 39)] for k in range(40)]
        payload["clusters"].append({
            "label": lab,
            "embeddings": [E[k].tolist() for k in sample_idx],
        })
    resp = _http_json(f"http://127.0.0.1:{port}/session/load",
                      data=json.dumps(payload).encode())
    if resp and resp.get("ok"):
        log(f"session clusters handed to sidecar ({len(groups)} clusters) — "
            f"post-call /profile assign works from these")
    return out


def relabel_main(args) -> int:
    """Recluster WITHOUT retranscribing. The transcript's text and the
    timing sidecar already carry everything except fresh labels: segments
    come from timing.json (offsets ARE the kept m4a's timeline — that's
    what playback sync runs on), audio from the kept m4a, and the current
    labels act as priors + exemplar corrections. A full reprocess spends
    most of its minutes in Parakeet for text that will not change."""
    txt = Path(args.relabel)
    base = str(txt)[: -len(".txt")]
    tj = Path(base + ".timing.json")
    m4a = Path(base + ".m4a")
    if not (txt.is_file() and tj.is_file() and m4a.is_file()):
        log("relabel needs the transcript, its .timing.json and kept .m4a")
        return 1
    timing = json.loads(tj.read_text())["lines"]
    lines = [l for l in txt.read_text(errors="replace").splitlines()
             if re.match(r"^\[\d{2}:\d{2}:\d{2}\] [^:]+: ", l)]
    if len(lines) != len(timing):
        log(f"transcript/timing misaligned ({len(lines)} vs {len(timing)}) — "
            f"run a full reprocess instead")
        return 1

    raw = decode_to_raw(str(m4a))
    segs = []
    for i, (line, t) in enumerate(zip(lines, timing)):
        m = re.match(r"^\[[\d:]+\] ([^:]+): (.*)$", line)
        start = float(t.get("t", 0))
        end = float(timing[i + 1].get("t", start + 30)) if i + 1 < len(timing) \
            else start + 30
        segs.append({"start": start, "end": max(end, start + 0.5),
                     "text": m.group(2) if m else "", "tokens": None})

    labeled = offline_diarize_multi(
        [{"raw": raw, "segs": segs, "origin": "import"}],
        args.diarize_port, me_label=args.me,
        priors=parse_label_priors(str(txt)))
    if labeled is None:
        log("diarize sidecar unreachable — relabel needs it")
        return 1

    # 1:1 with the original lines — only the label changes.
    out_lines = []
    changed = 0
    for line, seg, t in zip(lines, labeled, timing):
        m = re.match(r"^(\[[\d:]+\]) ([^:]+): (.*)$", line)
        new = f"{m.group(1)} {seg['label']}: {m.group(3)}"
        if seg["label"] != m.group(2):
            changed += 1
        out_lines.append(new)
        t["label"] = seg["label"]

    # Rewrite content lines in place, headers/footers untouched.
    all_lines = txt.read_text(errors="replace").splitlines()
    it = iter(out_lines)
    for i, l in enumerate(all_lines):
        if re.match(r"^\[\d{2}:\d{2}:\d{2}\] [^:]+: ", l):
            all_lines[i] = next(it)
    Path(args.out).write_text("\n".join(all_lines) + "\n")
    tj.write_text(json.dumps({"lines": timing}))
    log(f"relabel: {changed}/{len(lines)} lines changed speaker")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mic", help="mic-stream spool (raw s16le/16k/mono)")
    ap.add_argument("--sys", dest="sys_", help="system-stream spool (raw)")
    ap.add_argument("--input", help="import mode: any audio file")
    ap.add_argument("--out", required=True)
    ap.add_argument("--me", default="ME", help="label for the mic stream")
    ap.add_argument("--header-from", help="copy header lines from this transcript")
    ap.add_argument("--started", help="session start (ISO8601) for wall-clock stamps")
    ap.add_argument("--prior", help="existing transcript whose labels seed the reprocess")
    ap.add_argument("--relabel", help="fast path: re-diarize an EXISTING transcript "
                    "using its timing sidecar and kept audio — no transcription, "
                    "no enhancement; exemplar corrections propagate")
    ap.add_argument("--diarize-port", type=int, default=8179)
    args = ap.parse_args()

    if args.relabel:
        return relabel_main(args)
    if not args.input and not (args.mic or args.sys_):
        ap.error("need --input or at least one of --mic/--sys")

    import time as _time
    global _PERF_T0
    _PERF_T0 = _time.time()
    log(f"loading {MODEL_ID}")
    _t0 = _time.time()
    from parakeet_mlx import from_pretrained
    model = from_pretrained(MODEL_ID)
    perf_mark("load", _t0)

    # (start_s, label, text, origin, tokens) — origin drives echo
    # suppression; tokens (parakeet word timestamps, may be None) feed the
    # timing sidecar that powers the app's playback highlight.
    entries: list[tuple[float, str, str, str, list | None]] = []

    def diarize_all(raw: bytes, segs: list[dict], origin: str) -> None:
        """Sidecar-down fallback: sequential per-segment identify."""
        n = len(segs)
        if n:
            print(f"refine: status identifying speakers ({n} segments)", flush=True)
        step = max(1, n // 25)
        for i, seg in enumerate(segs):
            label = identify_segment(raw, seg["start"], seg["end"],
                                     args.diarize_port) or "THEM"
            entries.append((seg["start"], label, seg["text"], origin,
                            seg.get("tokens")))
            if (i + 1) % step == 0 or i + 1 == n:
                print(f"refine: progress diarize {int(100 * (i + 1) / n)}",
                      flush=True)

    audio_s = 0.0
    if args.input:
        raw = decode_to_raw(args.input)
        audio_s = len(raw) / 2 / SAMPLE_RATE
        _t0 = _time.time()
        segs = transcribe_sentences(model, raw, "import")
        perf_mark("transcribe", _t0)
        # Premium path first (pyannote), built-in clustering as fallback.
        _t0 = _time.time()
        labeled = pyannote_diarize_import(raw, segs, args.diarize_port)
        if labeled is None:
            labeled = offline_diarize_multi(
                [{"raw": raw, "segs": segs, "origin": "import"}],
                args.diarize_port)
        perf_mark("diarize", _t0)
        if labeled is not None:
            for seg in labeled:
                entries.append((seg["start"], seg["label"], seg["text"],
                                seg["origin"], seg.get("tokens")))
        else:
            diarize_all(raw, segs, "import")
    else:
        streams: list[dict] = []
        _t0 = _time.time()
        if args.mic and Path(args.mic).exists():
            mic_raw = Path(args.mic).read_bytes()
            audio_s = max(audio_s, len(mic_raw) / 2 / SAMPLE_RATE)
            streams.append({"raw": mic_raw, "origin": "mic",
                            "segs": transcribe_sentences(model, mic_raw, "mic")})
        if args.sys_ and Path(args.sys_).exists():
            sys_raw = Path(args.sys_).read_bytes()
            audio_s = max(audio_s, len(sys_raw) / 2 / SAMPLE_RATE)
            streams.append({"raw": sys_raw, "origin": "sys",
                            "segs": transcribe_sentences(model, sys_raw, "sys")})
        perf_mark("transcribe", _t0)
        # Joint diarization across BOTH streams: the mic is no longer
        # assumed to be only the user — in-person guests, speakerphone
        # calls and hybrid meetings all label correctly, anchored by the
        # user's enrolled profile (or the dominant mic voice as fallback).
        _t0 = _time.time()
        labeled = offline_diarize_multi(
            streams, args.diarize_port, me_label=args.me,
            priors=parse_label_priors(args.prior) if args.prior else None)
        perf_mark("diarize", _t0)
        if labeled is not None:
            for seg in labeled:
                entries.append((seg["start"], seg["label"], seg["text"],
                                seg["origin"], seg.get("tokens")))
        else:
            # Sidecar down: old behavior — mic blanket-labeled, sys THEM.
            me = args.me.strip().upper() or "ME"
            for st in streams:
                if st["origin"] == "mic":
                    for seg in st["segs"]:
                        entries.append((seg["start"], me, seg["text"], "mic",
                                        seg.get("tokens")))
                else:
                    diarize_all(st["raw"], st["segs"], "sys")

    if not entries:
        log("no speech found — leaving original transcript untouched")
        return 2

    entries.sort(key=lambda e: e[0])

    # Echo suppression (session mode): with speakers instead of headphones,
    # the mic hears the remote side too — every remote utterance lands
    # TWICE, once via the mic. The joint diarizer usually gives the echo
    # the remote speaker's label already (same voice, same cluster), so
    # dedup is ORIGIN-based, not label-based: a mic-origin entry whose text
    # near-matches a nearby sys-origin entry is the speaker bleed, and the
    # sys copy is the authoritative one.
    if args.mic and args.sys_:
        import difflib

        me_lab = (args.me or "").strip().upper()

        def norm(t: str) -> str:
            return re.sub(r"[^a-z0-9 ]", "", t.lower()).strip()

        def echo_match(a: str, b: str) -> bool:
            # Containment first: a sys echo often arrives as FRAGMENTS of
            # one long mic sentence, which line-vs-line similarity misses.
            # Length floor keeps a stray "yeah" from matching everything.
            if not a or not b:
                return False
            if len(a) < 10 or len(b) < 10:
                return a == b
            if min(len(a), len(b)) >= 12 and (a in b or b in a):
                return True
            return difflib.SequenceMatcher(None, a, b).ratio() >= 0.75

        # Pass 1 — remote echo of the USER. You cannot legitimately be on
        # your own meeting's system audio: any sys entry that (a) got the
        # user's label from the joint clusterer, or (b) textually echoes a
        # nearby mic line spoken by the user, is someone's echoey client
        # sending your voice back (field case: headphones on, every
        # sentence doubled, phantom 'Speaker 6' speaking only fragments of
        # the user's sentences).
        dropped_self = 0
        if me_lab:
            mic_me = [(t, norm(x)) for t, lab, x, o, _tk in entries
                      if o == "mic" and lab == me_lab]
            kept = []
            for t, lab, text, origin, toks in entries:
                if origin == "sys":
                    if lab == me_lab:
                        dropped_self += 1
                        continue
                    nt = norm(text)
                    if any(abs(mt - t) <= 6.0 and echo_match(nt, mx)
                           for mt, mx in mic_me):
                        dropped_self += 1
                        continue
                kept.append((t, lab, text, origin, toks))
            entries = kept

        # Pass 2 — speaker bleed INTO the mic (no headphones): a mic entry
        # that echoes nearby system audio is the room speakers, and the sys
        # copy is authoritative. Never drop the user's own mic lines here —
        # their sys echoes were already removed in pass 1.
        sys_entries = [(t, norm(x)) for t, _, x, o, _tk in entries if o == "sys"]
        deduped = []
        dropped = 0
        for t, lab, text, origin, toks in entries:
            if origin == "mic" and lab != me_lab:
                nt = norm(text)
                echo = False
                for st, sx in sys_entries:
                    if abs(st - t) > 6.0:
                        continue
                    if len(nt) < 10:
                        echo = nt == sx and abs(st - t) <= 3.0
                    else:
                        echo = echo_match(nt, sx)
                    if echo:
                        break
                if echo:
                    dropped += 1
                    continue
            deduped.append((t, lab, text, origin, toks))
        total_dropped = dropped + dropped_self
        if total_dropped:
            log(f"echo suppression: dropped {dropped_self} sys echoes of the "
                f"user + {dropped} mic lines duplicated from system audio")
            print(f"refine: status removed {total_dropped} echoed lines",
                  flush=True)
        entries = deduped

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
    ended_line: str | None = None
    if args.header_from and Path(args.header_from).exists():
        src_lines = Path(args.header_from).read_text(errors="replace").splitlines()
        for hl in src_lines:
            if re.match(r"^\[\d{2}:\d{2}:\d{2}\] ", hl) or hl.startswith("---"):
                break
            lines.append(hl)
        # The Ended footer lives at the BOTTOM — preserve it or the app's
        # header timer has no stop time and ticks forever.
        for hl in reversed(src_lines):
            if hl.startswith("Ended:"):
                ended_line = hl
                break
        header_done = True
    if not header_done:
        lines.append("# Meeting Transcript (imported audio)")
        if args.input:
            lines.append(f"# source: {Path(args.input).name}")
        lines.append("Started: " +
                     dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
        lines.append("")
    lines.append(f"# refined: parakeet ({MODEL_ID.split('/')[-1]})")

    timing_lines: list[dict] = []
    for start_s, label, text, _origin, toks in entries:
        lines.append(f"[{stamp(start_s)}] {label}: {text}")
        words = []
        for tk in toks or []:
            w = (tk.get("text") or "").strip()
            if w:
                words.append({"w": w, "s": round(float(tk.get("start", start_s)), 2),
                              "e": round(float(tk.get("end", tk.get("start", start_s))), 2)})
        timing_lines.append({"t": round(start_s, 2), "label": label, "words": words})

    if ended_line:
        lines.append("---")
        lines.append(ended_line)

    Path(args.out).write_text("\n".join(lines) + "\n")
    # Timing sidecar: one entry per transcript line, in file order — the
    # app's playback highlight and seek map key on this. Written next to
    # --out; refine_session/titling move+rename it with the transcript.
    Path(args.out + ".timing.json").write_text(
        json.dumps({"lines": timing_lines}))
    log(f"wrote {len(entries)} lines -> {args.out}")
    perf_write("import" if args.input else "session",
               Path(args.out).stem, audio_s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
