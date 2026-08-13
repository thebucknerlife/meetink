#!/usr/bin/env python3
"""Split a recorded meeting into two at a time offset.

Two back-to-back meetings on the same app land in one recording (the
per-source watcher can't see a boundary the app never surfaces). This
cuts everything after <seconds> into a NEW meeting folder:

  - transcript lines from the cut onward (fresh header, original's
    Ended footer moves along); the original ends at the cut
  - timing.json split in lockstep, the new half rebased to t=0
  - m4a / mic.wav / sys.wav cut with ffmpeg (stream copy)
  - new meta title "Split from <title> (MM:SS to end)"; the calendar
    event link stays with the ORIGINAL only
  - meta hard_breaks split and re-indexed

Usage: split_meeting.py <transcript.txt> <seconds>
Prints the new transcript path on the last stdout line.
"""
from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

LINE_RE = re.compile(r"^\[(\d{2}):(\d{2}):(\d{2})\] [^:]+: ")


def die(msg: str) -> "None":
    print(f"split: error: {msg}", file=sys.stderr)
    sys.exit(1)


def iso_z(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    if len(sys.argv) != 3:
        die("usage: split_meeting.py <transcript.txt> <seconds>")
    txt = Path(sys.argv[1]).resolve()
    try:
        split_s = float(sys.argv[2])
    except ValueError:
        die(f"not a number: {sys.argv[2]}")
    if not txt.is_file():
        die(f"no such transcript: {txt}")
    if split_s <= 0:
        die("split point must be after the start")

    base = txt.with_suffix("")
    raw = txt.read_text(encoding="utf-8")
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    # Header fields + content line indices.
    started: datetime | None = None
    user_line: str | None = None
    content_idx: list[int] = []
    footer_start: int | None = None
    for i, l in enumerate(lines):
        if l.startswith("Started: "):
            try:
                started = datetime.fromisoformat(
                    l[len("Started: "):].strip().replace("Z", "+00:00"))
            except ValueError:
                pass
        elif l.startswith("# user:"):
            user_line = l
        elif LINE_RE.match(l):
            content_idx.append(i)
        elif l == "---" and content_idx and footer_start is None:
            footer_start = i
    if started is None:
        die("transcript has no 'Started:' header — can't derive the new "
            "meeting's identity")
    if len(content_idx) < 2:
        die("nothing to split (fewer than 2 transcript lines)")

    ended_footer = lines[footer_start:] if footer_start is not None else []

    # The cut: first content line at/after split_s. timing.json is the
    # exact clock when present and aligned; wall stamps are the fallback.
    timing_path = Path(str(base) + ".timing.json")
    timing = None
    if timing_path.is_file():
        try:
            t_obj = json.loads(timing_path.read_text())
            if len(t_obj.get("lines", [])) == len(content_idx):
                timing = t_obj
        except ValueError:
            pass

    def elapsed_of(ci: int) -> float:
        if timing is not None:
            return float(timing["lines"][ci].get("t", 0.0))
        m = LINE_RE.match(lines[content_idx[ci]])
        st_local = started.astimezone()
        stamp_s = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        start_s = st_local.hour * 3600 + st_local.minute * 60 + st_local.second
        d = stamp_s - start_s
        if d < -3600:            # crossed midnight
            d += 86400
        return max(0.0, float(d))

    k = next((ci for ci in range(len(content_idx))
              if elapsed_of(ci) >= split_s), None)
    if k is None or k == 0:
        die("split point leaves one side empty — move the playhead "
            "between the two meetings")

    # New identity: local-time stamp folder, meetink's permanent-ID rule.
    root = txt.parent.parent
    split_dt = started + timedelta(seconds=split_s)
    stamp = split_dt.astimezone().strftime("%Y-%m-%d_%H-%M-%S")
    new_dir = root / stamp
    n = 2
    while new_dir.exists():
        new_dir = root / f"{stamp}_{n}"
        n += 1
    new_dir.mkdir(parents=True)
    new_base = new_dir / new_dir.name

    # --- transcript halves ---
    cut_line = content_idx[k]
    header_new = ["# Meeting Transcript"]
    if user_line:
        header_new.append(user_line)
    header_new.append(f"Started: {iso_z(split_dt)}")
    header_new.append("")
    new_body = lines[cut_line:footer_start] if footer_start is not None \
        else lines[cut_line:]
    Path(str(new_base) + ".txt").write_text(
        "\n".join(header_new + new_body + ended_footer) + "\n",
        encoding="utf-8")

    orig_head = lines[:cut_line]
    orig_out = orig_head + ["---", f"Ended: {iso_z(split_dt)}"]
    txt.write_text("\n".join(orig_out) + "\n", encoding="utf-8")

    # --- timing halves (new half rebased to its own t=0) ---
    if timing is not None:
        t_lines = timing["lines"]
        first, second = t_lines[:k], t_lines[k:]
        for e in second:
            e["t"] = max(0.0, round(float(e.get("t", 0.0)) - split_s, 3))
            for w in e.get("words", []):
                for key in ("s", "e"):
                    if key in w:
                        w[key] = max(0.0, round(float(w[key]) - split_s, 3))
        timing["lines"] = first
        timing_path.write_text(json.dumps(timing))
        new_timing = dict(timing)
        new_timing["lines"] = second
        Path(str(new_base) + ".timing.json").write_text(
            json.dumps(new_timing))

    # --- meta: title for the new half; event link stays behind ---
    meta_path = Path(str(base) + ".meta.json")
    title = txt.parent.name
    hard_breaks: list[int] = []
    if meta_path.is_file():
        try:
            meta = json.loads(meta_path.read_text())
            title = meta.get("title") or title
            hard_breaks = meta.get("hard_breaks") or []
        except ValueError:
            meta = {}
        if hard_breaks:
            meta["hard_breaks"] = [b for b in hard_breaks if b < k]
            meta_path.write_text(json.dumps(meta))
    mm, ss = int(split_s) // 60, int(split_s) % 60
    new_meta: dict = {"title": f"Split from {title} ({mm}:{ss:02d} to end)"}
    moved_breaks = [b - k for b in hard_breaks if b >= k and b - k > 0]
    if moved_breaks:
        new_meta["hard_breaks"] = moved_breaks
    Path(str(new_base) + ".meta.json").write_text(json.dumps(new_meta))

    # --- audio: tail → new folder, original truncated at the cut ---
    def ffmpeg(*args: str) -> bool:
        proc = subprocess.run(["ffmpeg", "-v", "error", "-y", *args],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"split: ffmpeg failed: {proc.stderr.strip()}",
                  file=sys.stderr)
            return False
        return True

    for ext in (".m4a", ".mic.wav", ".sys.wav"):
        src = Path(str(base) + ext)
        if not src.is_file():
            continue
        out = Path(str(new_base) + ext)
        if not ffmpeg("-ss", str(split_s), "-i", str(src), "-c", "copy",
                      str(out)):
            continue
        # The real extension must stay LAST — ffmpeg picks the muxer
        # from it (".m4a.splittmp" fails with "unable to choose format").
        tmp = src.parent / (".splittmp-" + src.name)
        if ffmpeg("-t", str(split_s), "-i", str(src), "-c", "copy",
                  str(tmp)):
            tmp.replace(src)
        else:
            tmp.unlink(missing_ok=True)

    # Route journal applies to the whole session — both halves keep it.
    route = Path(str(base) + ".route.jsonl")
    if route.is_file():
        shutil.copy2(route, Path(str(new_base) + ".route.jsonl"))

    # Derived artifacts (.idx, waveform caches) regenerate on demand; the
    # original's summary is now stale by construction — the user can
    # re-summarize via reprocess if they care.
    idx = Path(str(base) + ".idx")
    if idx.exists():
        try:
            shutil.rmtree(idx) if idx.is_dir() else idx.unlink()
        except OSError:
            pass

    print(str(new_base) + ".txt")
    return 0


if __name__ == "__main__":
    sys.exit(main())
