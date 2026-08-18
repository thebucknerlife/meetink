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
        # Refine can rewrite the header without a Started line (field
        # case: 'Adriana x Greg 1:1'). The folder stamp IS the recording
        # start — that's the permanent-ID rule.
        m = re.match(r"^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})",
                     txt.parent.name)
        if m:
            started = datetime(*map(int, m.groups())).astimezone()
    if started is None:
        die("transcript has no 'Started:' header and the folder isn't a "
            "timestamp — can't derive the new meeting's identity")
    if len(content_idx) < 2:
        die("nothing to split (fewer than 2 transcript lines)")

    # Refined transcripts stamp lines with ELAPSED time ([00:00:01] …),
    # captures with wall clock. Detect by the first stamp: meetings
    # don't start with a 00:0x wall clock outside the midnight minute.
    m0 = LINE_RE.match(lines[content_idx[0]])
    first_stamp_s = (int(m0.group(1)) * 3600 + int(m0.group(2)) * 60
                     + int(m0.group(3)))
    stamps_elapsed = first_stamp_s < 120

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
        stamp_s = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        if stamps_elapsed:
            return float(stamp_s)
        st_local = started.astimezone()
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
    if stamps_elapsed:
        # Elapsed-style stamps must restart at ~00:00:00 in the new half
        # or its clock reads as minutes-in when it's seconds-in.
        def rebase(line: str) -> str:
            m = LINE_RE.match(line)
            if not m:
                return line
            s = max(0, int(m.group(1)) * 3600 + int(m.group(2)) * 60
                    + int(m.group(3)) - int(split_s))
            return f"[{s // 3600:02d}:{(s // 60) % 60:02d}:{s % 60:02d}]" \
                + line[10:]
        new_body = [rebase(l) for l in new_body]
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
            # Atomic — the app polls meta.json; see _meta_set_title.
            tmp = Path(str(meta_path) + ".tmp")
            tmp.write_text(json.dumps(meta))
            tmp.replace(meta_path)
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

    # Experimental tap sidecar (bare session-dir name, not <base>-keyed):
    # cut like the other audio. Its journal is wall-clock-keyed (epoch
    # "t"), so both halves keep a verbatim copy — no rebasing lies.
    # Rate-rolled segments (tap-experiment.2.wav …) stay with the
    # original whole: attributing a mid-call rate change to the right
    # half isn't worth the complexity for a diagnostic artifact.
    tap = txt.parent / "tap-experiment.wav"
    if tap.is_file():
        new_dir = Path(str(new_base)).parent
        if ffmpeg("-ss", str(split_s), "-i", str(tap), "-c", "copy",
                  str(new_dir / tap.name)):
            tmp = tap.parent / (".splittmp-" + tap.name)
            if ffmpeg("-t", str(split_s), "-i", str(tap), "-c", "copy",
                      str(tmp)):
                tmp.replace(tap)
            else:
                tmp.unlink(missing_ok=True)
        tap_journal = Path(str(tap) + ".tap-journal.jsonl")
        if tap_journal.is_file():
            shutil.copy2(tap_journal,
                         new_dir / tap_journal.name)

    # Route journal applies to the whole session — both halves keep it.
    def split_jsonl_sidecar(path: Path, new_path: Path,
                            synthesize_initial: bool) -> None:
        """Time-keyed jsonl sidecars (route/health): events before the
        cut stay with the original, events after move to the new half
        rebased to its t=0. Route journals also get the STATE at the
        cut synthesized as the new half's initial event — the new
        meeting starts already-on-that-device, and an unambiguous
        journal is authoritative for the render (a verbatim copy would
        carry pre-cut device kinds into the new half and break both
        halves' authority)."""
        if not path.is_file():
            return
        events = []
        for line in path.read_text().splitlines():
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if isinstance(o, dict) and "t" in o:
                events.append(o)
        before = [o for o in events if float(o["t"]) < split_s]
        after = [o for o in events if float(o["t"]) >= split_s]
        new_events = []
        if synthesize_initial and before:
            init = dict(before[-1])
            init["t"] = 0.1
            new_events.append(init)
        for o in after:
            o = dict(o)
            o["t"] = round(float(o["t"]) - split_s, 2)
            new_events.append(o)
        path.write_text("".join(json.dumps(o) + "\n" for o in before))
        if new_events:
            new_path.write_text(
                "".join(json.dumps(o) + "\n" for o in new_events))

    split_jsonl_sidecar(Path(str(base) + ".route.jsonl"),
                        Path(str(new_base) + ".route.jsonl"),
                        synthesize_initial=True)
    split_jsonl_sidecar(Path(str(base) + ".health.jsonl"),
                        Path(str(new_base) + ".health.jsonl"),
                        synthesize_initial=False)
    # The render decision manifest describes the PRE-cut m4a — stale for
    # both halves. Reprocess regenerates it.
    Path(str(base) + ".audio.json").unlink(missing_ok=True)

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
