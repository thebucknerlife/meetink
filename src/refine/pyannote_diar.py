#!/usr/bin/env python3
"""Speaker turns from pyannote's speaker-diarization-3.1 pipeline.

Runs inside ~/.meetink/pyannote-venv (its own torch); refine.py shells
out here for IMPORTS — single-stream audio with unknown speakers is
exactly what pyannote's joint segmentation+clustering is best at, and
where our sliding-window/TitaNet clustering is weakest (it has no
overlap handling and fragments short interjections).

Input: raw s16le/16k/mono on --raw. Output: one JSON line on stdout:
  {"turns": [[start_s, end_s, "SPEAKER_00"], ...]}
Progress goes to stderr as "pyannote: progress N" lines.

Models are gated on Hugging Face — `snapshot_download` works once the
user has accepted the model conditions and logged in (cached token).
"""
from __future__ import annotations

import argparse
import json
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    args = ap.parse_args()

    import numpy as np
    import torch
    from pyannote.audio import Pipeline

    print("pyannote: progress 5", file=sys.stderr, flush=True)
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1")
    # Apple-Silicon GPU: 2-4x over CPU for the segmentation/embedding
    # models. Falls back silently — MPS gaps in old torch raise at .to().
    try:
        if torch.backends.mps.is_available():
            pipeline.to(torch.device("mps"))
            print("pyannote: using MPS (Apple GPU)", file=sys.stderr, flush=True)
    except Exception:
        pass
    print("pyannote: progress 15", file=sys.stderr, flush=True)

    data = np.fromfile(args.raw, dtype=np.int16).astype(np.float32) / 32768.0
    waveform = torch.from_numpy(data).unsqueeze(0)

    # Plain callable hook — pyannote's ProgressHook renders rich terminal
    # UI to STDOUT, which buries the JSON result line this script's whole
    # contract depends on. stderr only.
    def hook(step_name, step_artifact, file=None, total=None, completed=None):
        if total:
            pct = 15 + int(80 * (completed or 0) / total)
            print(f"pyannote: progress {pct}", file=sys.stderr, flush=True)

    diarization = pipeline({"waveform": waveform, "sample_rate": 16000}, hook=hook)

    turns = [[round(turn.start, 2), round(turn.end, 2), speaker]
             for turn, _, speaker in diarization.itertracks(yield_label=True)]
    print("pyannote: progress 100", file=sys.stderr, flush=True)
    print(json.dumps({"turns": turns}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
