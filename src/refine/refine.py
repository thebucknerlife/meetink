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
            out.append({"start": float(s.start), "end": float(s.end), "text": text})
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

    if args.input:
        raw = decode_to_raw(args.input)
        for seg in transcribe_sentences(model, raw, "import"):
            label = identify_segment(raw, seg["start"], seg["end"],
                                     args.diarize_port) or "THEM"
            entries.append((seg["start"], label, seg["text"]))
    else:
        if args.mic and Path(args.mic).exists():
            mic_raw = Path(args.mic).read_bytes()
            me = args.me.strip().upper() or "ME"
            for seg in transcribe_sentences(model, mic_raw, "mic"):
                entries.append((seg["start"], me, seg["text"]))
        if args.sys_ and Path(args.sys_).exists():
            sys_raw = Path(args.sys_).read_bytes()
            for seg in transcribe_sentences(model, sys_raw, "sys"):
                label = identify_segment(sys_raw, seg["start"], seg["end"],
                                         args.diarize_port) or "THEM"
                entries.append((seg["start"], label, seg["text"]))

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
